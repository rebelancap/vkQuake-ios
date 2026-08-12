// VKQSenseController.m — PSVR2 Sense controllers on visionOS (charter A10).
//
// Two questions, deliberately kept apart, because conflating them cost the
// sibling project days:
//
//   WHO DRIVES INPUT — a product category question. Spatial-category controllers
//   are ours; every ordinary gamepad stays with SDL and the player's own binds.
//   The SDL filter (patch 0019, in_sdl3.c) asks this file the same question, so
//   the two halves can never disagree about who owns a device.
//
//   WHERE THE HAND IS — an ARKit question, and NOT the same gate. `ar_accessory_
//   load_from_device` takes a GCDevice, not a spatial controller: a device that
//   is "just a gamepad" for input may still be trackable. So the load is
//   attempted for EVERY controller and the result is logged either way.
//
// THE TRAP LEDGER, paid for in sm64coopdx and not paid again here:
//   - Declaration and filter ship together. Without `SpatialGamepad` in the
//     Info.plist the pair enumerates as ONE aggregate MFi gamepad and
//     `ar_accessory_load_from_device` fails with code 1200. With it, two
//     `GCProductCategorySpatialController` devices appear (visionOS 26+).
//   - AUTHORIZATION BEFORE LOAD. A load issued without accessory-tracking
//     authorization fails in exactly the shape of "this hardware cannot be
//     tracked", which is the most misleading result available. Ask first, park
//     devices until the answer lands, then drain the queue.
//   - ELEMENT NAMES ARE NOT GUESSED. The constants below are the verified ones;
//     each also has a by-shape fallback, so a naming surprise degrades one
//     button instead of killing the pad. And the full inventory is logged on
//     every connect, in the headset-readable diagnostics file, because the
//     person who can produce it is wearing a Vision Pro and not sitting at a Mac.
//   - A working path is never removed in the build that introduces its
//     replacement. Nothing here touches the gamepad path.

#import "VKQSenseController.h"

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <ARKit/ARKit.h>
#import <CoreHaptics/CoreHaptics.h>
#import <math.h>
#import <pthread.h>

// Diagnostics sink (VKQVR.m). Pinned lines survive any amount of play.
extern void VKQ_VR_DiagPin (const char *line);
extern void VKQ_VR_DiagRoll (const char *line);

#define VKQ_SENSE_MAX 4

static void vkq_sense_pin (NSString *fmt, ...) NS_FORMAT_FUNCTION (1, 2);
static void vkq_sense_pin (NSString *fmt, ...)
{
	va_list ap;
	va_start (ap, fmt);
	NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
	va_end (ap);
	VKQ_VR_DiagPin (s.UTF8String);
}

// ---------------------------------------------------------------------------
// State. The GameController notifications land on the main queue; the poll runs
// on the compositor thread. One lock covers the accessory table and the hand
// assignment; the poses themselves are only written by the poll.
// ---------------------------------------------------------------------------
static pthread_mutex_t sLock = PTHREAD_MUTEX_INITIALIZER;

static GCController *sHand[2];		 // 0 = left, 1 = right, by ARKit chirality
static NSMutableArray<GCController *> *sSpatial; // spatial-category, chirality pending or not
static NSMutableString				  *sInventory;
static BOOL							   sStarted;

API_AVAILABLE (visionos (26.0))
static ar_accessory_t sAccessory[VKQ_SENSE_MAX];
static GCController	 *sAccessoryDevice[VKQ_SENSE_MAX];
static int			  sAccessoryCount;

API_AVAILABLE (visionos (26.0))
static ar_accessory_tracking_provider_t sProvider;
API_AVAILABLE (visionos (26.0))
static ar_session_t sSession;
static bool			sProviderDirty;

static int			 sAuthState;  // 0 = pending / not asked, 1 = allowed, -1 = denied
static BOOL			 sAuthAsked;
static GCController *sPending[VKQ_SENSE_MAX];
static int			 sPendingCount;

static int sLoadOK, sLoadFail, sLoadFailCode, sLastAnchorCount, sPollCount;
static int sTrackedMask; // which hands the last poll saw

// Synthetic hands (simulator). Stored as a finished tracking-space pose so the
// injection point is byte-identical to a real anchor's.
static int			 sSynthOn[2];
static simd_float4x4 sSynthPose[2];
static unsigned		 sSynthButtons[2];
static float		 sSynthStick[2][2];

// ---------------------------------------------------------------------------
// Element access. Spatial controllers are NOT `extendedGamepad` devices, so
// everything goes through `physicalInputProfile` by alias.
// ---------------------------------------------------------------------------
static GCControllerButtonInput *vkq_btn (GCController *c, NSString *name)
{
	return c ? c.physicalInputProfile.buttons[name] : nil;
}

// By-shape fallback: find a button whose alias merely CONTAINS the needle. The
// verified constant is always tried first; this only catches a rename.
static GCControllerButtonInput *vkq_btn_like (GCController *c, NSString *needle)
{
	if (c == nil)
		return nil;
	for (NSString *k in c.physicalInputProfile.buttons.allKeys)
		if ([k rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound)
			return c.physicalInputProfile.buttons[k];
	return nil;
}

static bool vkq_down (GCController *c, NSString *name, NSString *needle)
{
	GCControllerButtonInput *b = vkq_btn (c, name);
	if (b == nil && needle)
		b = vkq_btn_like (c, needle);
	return b ? b.isPressed : false;
}

// Analog value. On a Sense the trigger's analog travel rides on the BUTTON
// element (`pressedInput.value`), not on an axis — reading `axes` for it is the
// mistake that produced a digital-feeling trigger elsewhere.
static float vkq_analog (GCController *c, NSString *name, NSString *needle)
{
	GCControllerButtonInput *b = vkq_btn (c, name);
	if (b == nil && needle)
		b = vkq_btn_like (c, needle);
	return b ? b.value : 0.0f;
}

// The thumbstick is a DIRECTION PAD, which is why it lives under `dpads`.
static GCControllerDirectionPad *vkq_stick (GCController *c)
{
	if (c == nil)
		return nil;
	GCPhysicalInputProfile	 *p = c.physicalInputProfile;
	GCControllerDirectionPad *d = p.dpads[GCInputThumbstick];
	if (d != nil)
		return d;
	for (NSString *k in p.dpads.allKeys)
		return p.dpads[k]; // first of any: better one stick than none
	return nil;
}

static bool vkq_is_spatial (GCController *c)
{
	if (@available (visionOS 26.0, *))
		return [c.productCategory isEqualToString:GCProductCategorySpatialController];
	return false;
}

// SDL's own naming rule, reproduced exactly (SDL_mfijoystick.m): vendorName,
// falling back to productCategory, falling back to "MFi Gamepad". Matching on
// anything else would compare two different strings and quietly never fire.
static NSString *vkq_sdl_name (GCController *c)
{
	if (c.vendorName.length)
		return c.vendorName;
	if (@available (visionOS 26.0, *))
		if (c.productCategory.length)
			return c.productCategory;
	return @"MFi Gamepad";
}

// ---------------------------------------------------------------------------
// Inventory — the deliverable of the first device round.
// ---------------------------------------------------------------------------
static void vkq_sense_log_inventory (GCController *c)
{
	NSString *cat = @"(unknown)";
	if (@available (visionOS 26.0, *))
		cat = c.productCategory ?: @"(nil)";
	vkq_sense_pin (@"SENSE controller '%@' category='%@' spatial=%d sdlName='%@'", c.vendorName ?: @"(nil)", cat, vkq_is_spatial (c) ? 1 : 0, vkq_sdl_name (c));
	vkq_sense_pin (@"SENSE   buttons: %@", [c.physicalInputProfile.buttons.allKeys componentsJoinedByString:@", "]);
	vkq_sense_pin (@"SENSE   axes:    %@", [c.physicalInputProfile.axes.allKeys componentsJoinedByString:@", "]);
	vkq_sense_pin (@"SENSE   dpads:   %@", [c.physicalInputProfile.dpads.allKeys componentsJoinedByString:@", "]);
	vkq_sense_pin (@"SENSE   haptics: %@", c.haptics ? @"yes" : @"no");
	// Did the declaration survive plist processing into the BUILT product? One
	// line closes that question permanently, and it is the first thing the device
	// round has to answer.
	vkq_sense_pin (@"SENSE   bundle GCSupportedGameControllers = %@", [NSBundle.mainBundle objectForInfoDictionaryKey:@"GCSupportedGameControllers"]);
	if (sInventory == nil)
		sInventory = [NSMutableString string];
	[sInventory appendFormat:@"%@ [%@] %lub/%lud%@\n", c.vendorName ?: @"?", cat, (unsigned long)c.physicalInputProfile.buttons.allKeys.count,
							 (unsigned long)c.physicalInputProfile.dpads.allKeys.count, c.haptics ? @" haptics" : @""];
}

// ---------------------------------------------------------------------------
// Accessory tracking (poses)
// ---------------------------------------------------------------------------
API_AVAILABLE (visionos (26.0))
static void vkq_sense_load_retry (GCController *c, int attempt);
static void vkq_sense_provider_needs_rebuild (void);

API_AVAILABLE (visionos (26.0))
static void vkq_sense_load (GCController *c) { vkq_sense_load_retry (c, 0); }

API_AVAILABLE (visionos (26.0))
static void vkq_sense_load_retry (GCController *c, int attempt)
{
	if (c == nil)
		return;
	pthread_mutex_lock (&sLock);
	for (int i = 0; i < sAccessoryCount; i++)
		if (sAccessoryDevice[i] == c)
		{
			pthread_mutex_unlock (&sLock);
			return; // already loaded — a device can arrive twice (queue + reconnect)
		}
	pthread_mutex_unlock (&sLock);

	ar_accessory_load_from_device (c, ^(id<GCDevice> device, bool successful, ar_error_t error, ar_accessory_t accessory) {
		(void)device;
		if (!successful || accessory == NULL)
		{
			long		code = -1;
			CFStringRef desc = NULL;
			if (error != NULL)
			{
				code = (long)ar_error_get_error_code (error);
				CFErrorRef cfe = ar_error_copy_cf_error (error);
				if (cfe != NULL)
				{
					desc = CFErrorCopyDescription (cfe);
					CFRelease (cfe);
				}
			}
			sLoadFail++;
			sLoadFailCode = (int)code;
			// 1200 is ar_accessory_tracking_error_code_accessory_loading_failed —
			// on this system that means the SpatialGamepad declaration did not
			// take effect and the pair is still one aggregate MFi device.
			vkq_sense_pin (@"SENSE accessory load FAILED for '%@' code=%ld attempt=%d%@ desc=%@", c.vendorName ?: @"(nil)", code, attempt,
						   code == 1200 ? @"  (1200 = aggregate MFi: the SpatialGamepad declaration is missing or ineffective)" : @"",
						   desc ? (__bridge NSString *)desc : @"(none)");
			if (desc != NULL)
				CFRelease (desc);
			// ONE retry, 2 s later: accessory tracking is gated on the app being
			// focused, and a load issued during entry or a focus change can fail
			// for that alone. Both results are logged, so a retry cannot hide the
			// first answer.
			if (attempt == 0)
				dispatch_after (dispatch_time (DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue (), ^{
					if (@available (visionOS 26.0, *))
						vkq_sense_load_retry (c, 1);
				});
			return;
		}
		pthread_mutex_lock (&sLock);
		if (sAccessoryCount >= VKQ_SENSE_MAX)
		{
			pthread_mutex_unlock (&sLock);
			vkq_sense_pin (@"SENSE accessory table full — ignoring '%s'", ar_accessory_get_name (accessory));
			return;
		}
		ar_accessory_chirality_t ch = ar_accessory_get_inherent_chirality (accessory);
		sAccessory[sAccessoryCount] = accessory;
		sAccessoryDevice[sAccessoryCount] = c;
		sAccessoryCount++;
		sLoadOK++;
		sProviderDirty = true;
		// GameController has NO handedness API — the ARKit accessory's inherent
		// chirality is the documented pairing, and it is why input assignment has
		// to wait for an asynchronous answer instead of guessing from a name.
		if (ch == ar_accessory_chirality_left)
			sHand[0] = c;
		else if (ch == ar_accessory_chirality_right)
			sHand[1] = c;
		pthread_mutex_unlock (&sLock);
		vkq_sense_provider_needs_rebuild ();
		vkq_sense_pin (@"SENSE accessory LOADED '%s' chirality=%s from '%@' — %d known", ar_accessory_get_name (accessory),
					   ch == ar_accessory_chirality_left ? "LEFT" : ch == ar_accessory_chirality_right ? "RIGHT" : "unspecified", c.vendorName ?: @"(nil)",
					   sAccessoryCount);
	});
}

API_AVAILABLE (visionos (26.0))
static void vkq_sense_request_auth (void)
{
	if (sAuthAsked)
		return;
	sAuthAsked = YES;
	if (sSession == NULL)
		sSession = ar_session_create ();
	vkq_sense_pin (@"SENSE requesting accessory-tracking authorization");
	ar_session_request_authorization (sSession, ar_authorization_type_accessory_tracking, ^(ar_authorization_results_t results, ar_error_t error) {
		__block int state = -1;
		if (results != NULL)
			ar_authorization_results_enumerate_results (results, ^bool (ar_authorization_result_t r) {
				if (ar_authorization_result_get_authorization_type (r) == ar_authorization_type_accessory_tracking)
					state = (ar_authorization_result_get_status (r) == ar_authorization_status_allowed) ? 1 : -1;
				return true;
			});
		sAuthState = state;
		vkq_sense_pin (@"SENSE accessory-tracking authorization: %s%s", state == 1 ? "ALLOWED" : "DENIED", error ? " (with error)" : "");
		if (state != 1)
			return;
		for (int i = 0; i < sPendingCount; i++)
			vkq_sense_load (sPending[i]);
		sPendingCount = 0;
	});
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------
static void vkq_sense_adopt (GCController *c)
{
	if (c == nil)
		return;
	vkq_sense_log_inventory (c);
	if (vkq_is_spatial (c))
	{
		pthread_mutex_lock (&sLock);
		if (sSpatial == nil)
			sSpatial = [NSMutableArray array];
		if (![sSpatial containsObject:c])
			[sSpatial addObject:c];
		pthread_mutex_unlock (&sLock);
	}
	// Poses are asked for on EVERY controller, spatial or not — see the header.
	if (@available (visionOS 26.0, *))
	{
		vkq_sense_request_auth ();
		if (sAuthState == 1)
			vkq_sense_load (c);
		else if (sAuthState == 0 && sPendingCount < VKQ_SENSE_MAX)
			sPending[sPendingCount++] = c; // parked until the grant lands
	}
}

static void vkq_sense_forget (GCController *c)
{
	pthread_mutex_lock (&sLock);
	for (int i = 0; i < 2; i++)
		if (sHand[i] == c)
			sHand[i] = nil;
	[sSpatial removeObject:c];
	for (int i = 0; i < sPendingCount; i++)
		if (sPending[i] == c)
		{
			for (int j = i; j < sPendingCount - 1; j++)
				sPending[j] = sPending[j + 1];
			sPending[--sPendingCount] = nil;
			break;
		}
	for (int i = 0; i < sAccessoryCount; i++)
		if (sAccessoryDevice[i] == c)
		{
			for (int j = i; j < sAccessoryCount - 1; j++)
			{
				sAccessory[j] = sAccessory[j + 1];
				sAccessoryDevice[j] = sAccessoryDevice[j + 1];
			}
			sAccessoryCount--;
			sAccessory[sAccessoryCount] = NULL;
			sAccessoryDevice[sAccessoryCount] = nil;
			sProviderDirty = true;
			break;
		}
	pthread_mutex_unlock (&sLock);
	vkq_sense_provider_needs_rebuild ();
	// The engine releases everything for an untracked hand on the next publish,
	// so a controller that dies mid-fire cannot leave +attack latched.
	vkq_sense_pin (@"SENSE controller disconnected ('%@')", c.vendorName ?: @"(nil)");
}

void VKQ_Sense_Start (void)
{
	if (sStarted)
		return;
	sStarted = YES;
	for (GCController *c in GCController.controllers)
		vkq_sense_adopt (c);
	[NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification
													object:nil
													 queue:NSOperationQueue.mainQueue
												usingBlock:^(NSNotification *n) { vkq_sense_adopt ((GCController *)n.object); }];
	[NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidDisconnectNotification
													object:nil
													 queue:NSOperationQueue.mainQueue
												usingBlock:^(NSNotification *n) { vkq_sense_forget ((GCController *)n.object); }];
	// Logged at START, not only on a connect: the simulator has no controllers at
	// all, so "did the SpatialGamepad declaration survive plist processing into
	// the built product" would otherwise be unanswerable there — and that is the
	// one Stage-1 claim the sim CAN prove.
	vkq_sense_pin (@"SENSE backend ready (%lu controller(s) present) — bundle GCSupportedGameControllers = %@", (unsigned long)GCController.controllers.count,
				   [NSBundle.mainBundle objectForInfoDictionaryKey:@"GCSupportedGameControllers"] ?: @"(ABSENT)");
	vkq_sense_pin (@"SENSE bundle NSAccessoryTrackingUsageDescription = %@",
				   [NSBundle.mainBundle objectForInfoDictionaryKey:@"NSAccessoryTrackingUsageDescription"] ?: @"(ABSENT)");
}

// ---------------------------------------------------------------------------
// The SDL filter's predicate. Conservative by construction: it fires only when
// a SPATIAL controller carries this name AND no non-spatial one does, so an
// ordinary gamepad can never be taken away from SDL by a name collision.
// ---------------------------------------------------------------------------
int VKQ_Sense_ShouldIgnoreSDLGamepad (const char *name)
{
	if (name == NULL)
		return 0;
	VKQ_Sense_Start (); // the engine can reach this before anything else has run
	@autoreleasepool
	{
		NSString *want = [NSString stringWithUTF8String:name];
		BOOL	  spatial = NO, ordinary = NO;
		for (GCController *c in GCController.controllers)
		{
			if (![vkq_sdl_name (c) isEqualToString:want])
				continue;
			if (vkq_is_spatial (c))
				spatial = YES;
			else
				ordinary = YES;
		}
		static NSMutableSet *logged;
		if (logged == nil)
			logged = [NSMutableSet set];
		if (![logged containsObject:want])
		{
			[logged addObject:want];
			vkq_sense_pin (@"SENSE SDL filter: '%@' spatial=%d ordinary=%d -> %@", want, spatial, ordinary,
						   (spatial && !ordinary) ? @"IGNORED by SDL (native backend owns it)" : @"kept by SDL");
		}
		return (spatial && !ordinary) ? 1 : 0;
	}
}

// ---------------------------------------------------------------------------
// Provider lifecycle
// ---------------------------------------------------------------------------
// NEVER called from the compositor thread. `ar_session_run` is a synchronous
// ARKit call of unbounded duration, and an earlier draft did it from inside the
// per-frame poll with the state lock held — which would have stalled a
// compositor frame AND blocked the main thread's connect/disconnect handling
// behind it, for as long as ARKit felt like taking. The set of accessories only
// changes on a connect, a disconnect or a load completing, all of which are main
// -queue events, so this belongs there and the poll just reads whatever provider
// is currently published.
API_AVAILABLE (visionos (26.0))
static void vkq_sense_rebuild_provider (void)
{
	ar_accessories_t					  set = NULL;
	ar_accessory_tracking_configuration_t cfg = NULL;
	int									  n = 0;

	pthread_mutex_lock (&sLock);
	sProviderDirty = false;
	n = sAccessoryCount;
	if (n > 0)
	{
		set = ar_accessories_create ();
		for (int i = 0; i < n; i++)
			if (sAccessory[i] != NULL)
				ar_accessories_add_accessory (set, sAccessory[i]);
	}
	pthread_mutex_unlock (&sLock);

	if (n == 0)
	{
		pthread_mutex_lock (&sLock);
		sProvider = NULL;
		pthread_mutex_unlock (&sLock);
		return;
	}
	cfg = ar_accessory_tracking_configuration_create ();
	ar_accessory_tracking_configuration_set_accessories (cfg, set);
	// The SAME session the authorization was granted on — a fresh one would be
	// unauthorized again. And a SEPARATE session from the VR loop's world
	// tracking, deliberately: accessories load asynchronously and controllers
	// come and go, while the world provider is created once at loop start. If
	// this session never runs, the world is exactly as it was and only the hands
	// are missing.
	if (sSession == NULL)
		sSession = ar_session_create ();
	{
		ar_accessory_tracking_provider_t p = ar_accessory_tracking_provider_create (cfg);
		ar_data_providers_t				providers = ar_data_providers_create_with_data_providers (p, NULL);
		ar_session_run (sSession, providers);
		pthread_mutex_lock (&sLock);
		sProvider = p;
		pthread_mutex_unlock (&sLock);
	}
	vkq_sense_pin (@"SENSE accessory tracking running with %d accessory(s)", n);
}

// Schedule a rebuild on the main queue. Coalesced by the dirty flag, so a burst
// of connects costs one session run.
static void vkq_sense_provider_needs_rebuild (void)
{
	dispatch_async (dispatch_get_main_queue (), ^{
		if (@available (visionOS 26.0, *))
		{
			bool want;
			pthread_mutex_lock (&sLock);
			want = sProviderDirty;
			pthread_mutex_unlock (&sLock);
			if (want)
				vkq_sense_rebuild_provider ();
		}
	});
}

// ---------------------------------------------------------------------------
// Per-frame poll
// ---------------------------------------------------------------------------
static simd_float4x4 vkq_synth_matrix (float yawDeg, float pitchDeg, float rollDeg, float x, float y, float z)
{
	const float	  d2r = (float)M_PI / 180.0f;
	float		  cy = cosf (yawDeg * d2r), sy = sinf (yawDeg * d2r);
	float		  cp = cosf (pitchDeg * d2r), sp = sinf (pitchDeg * d2r);
	float		  cr = cosf (rollDeg * d2r), sr = sinf (rollDeg * d2r);
	simd_float4x4 ry = matrix_identity_float4x4, rx = matrix_identity_float4x4, rz = matrix_identity_float4x4, m;
	ry.columns[0] = simd_make_float4 (cy, 0, -sy, 0);
	ry.columns[2] = simd_make_float4 (sy, 0, cy, 0);
	rx.columns[1] = simd_make_float4 (0, cp, sp, 0);
	rx.columns[2] = simd_make_float4 (0, -sp, cp, 0);
	rz.columns[0] = simd_make_float4 (cr, sr, 0, 0);
	rz.columns[1] = simd_make_float4 (-sr, cr, 0, 0);
	m = simd_mul (ry, simd_mul (rx, rz));
	m.columns[3] = simd_make_float4 (x, y, z, 1.0f);
	return m;
}

static unsigned vkq_sense_buttons (GCController *c)
{
	unsigned b = 0;
	if (vkq_down (c, GCInputTrigger, @"Trigger"))
		b |= VKQ_SENSE_TRIGGER;
	if (vkq_down (c, GCInputGripButton, @"Grip"))
		b |= VKQ_SENSE_GRIP;
	if (vkq_down (c, GCInputButtonA, nil))
		b |= VKQ_SENSE_A;
	if (vkq_down (c, GCInputButtonB, nil))
		b |= VKQ_SENSE_B;
	if (vkq_down (c, GCInputThumbstickButton, @"Thumbstick Button"))
		b |= VKQ_SENSE_STICK;
	if (vkq_down (c, GCInputButtonMenu, @"Menu"))
		b |= VKQ_SENSE_MENU;
	return b;
}

void VKQ_Sense_Poll (VKQSenseHand out[2])
{
	memset (out, 0, 2 * sizeof (VKQSenseHand));
	out[0].originFromHand = out[1].originFromHand = matrix_identity_float4x4;

	// --- buttons ------------------------------------------------------------
	GCController *hands[2];
	pthread_mutex_lock (&sLock);
	hands[0] = sHand[0];
	hands[1] = sHand[1];
	pthread_mutex_unlock (&sLock);
	for (int h = 0; h < 2; h++)
	{
		GCController *c = hands[h];
		if (c == nil)
			continue;
		out[h].present = 1;
		out[h].buttons = vkq_sense_buttons (c);
		out[h].trigger = vkq_analog (c, GCInputTrigger, @"Trigger");
		out[h].grip = vkq_analog (c, GCInputGripButton, @"Grip");
		GCControllerDirectionPad *d = vkq_stick (c);
		if (d)
		{
			out[h].stickX = d.xAxis.value;
			out[h].stickY = d.yAxis.value;
		}
	}

	// --- poses --------------------------------------------------------------
	if (@available (visionOS 26.0, *))
	{
		ar_accessory_tracking_provider_t provider;
		bool							dirty;
		pthread_mutex_lock (&sLock);
		provider = sProvider;
		dirty = sProviderDirty;
		pthread_mutex_unlock (&sLock);
		// The rebuild happens on the MAIN queue, never here — see the note on
		// vkq_sense_rebuild_provider. This frame simply uses whatever provider
		// exists right now, which is the correct behaviour anyway: a hand that
		// arrives mid-frame appears on the next one.
		if (dirty)
			vkq_sense_provider_needs_rebuild ();

		if (provider != NULL)
		{
			ar_accessory_anchors_t anchors = ar_accessory_tracking_provider_get_latest_anchors (provider);
			if (anchors != NULL)
			{
				sLastAnchorCount = (int)ar_accessory_anchors_get_count (anchors);
				__block VKQSenseHand *o = out;
				ar_accessory_anchors_enumerate_anchors (anchors, ^bool (ar_accessory_anchor_t anchor) {
					if (!ar_accessory_anchor_is_tracked (anchor))
						return true;
					// Chirality can be unspecified (a controller on a table is in
					// nobody's hand). Fall back to the accessory's INHERENT
					// chirality, which a left/right pair always has, rather than
					// guessing from position.
					ar_accessory_chirality_t ch = ar_accessory_anchor_get_held_chirality (anchor);
					int						 hand = -1;
					if (ch == ar_accessory_chirality_left)
						hand = 0;
					else if (ch == ar_accessory_chirality_right)
						hand = 1;
					else
					{
						ar_accessory_t acc = ar_accessory_anchor_get_accessory (anchor);
						if (acc != NULL)
						{
							ar_accessory_chirality_t inh = ar_accessory_get_inherent_chirality (acc);
							if (inh == ar_accessory_chirality_left)
								hand = 0;
							else if (inh == ar_accessory_chirality_right)
								hand = 1;
						}
					}
					if (hand < 0)
						return true;
					o[hand].posed = 1;
					o[hand].present = 1;
					o[hand].held = ar_accessory_anchor_is_held (anchor) ? 1 : 0;
					o[hand].originFromHand = ar_accessory_anchor_get_origin_from_anchor_transform (anchor);
					// Velocity from the anchor, never hand-differenced: ARKit
					// already has it and our own delta would carry our poll jitter.
					o[hand].velocity = ar_accessory_anchor_get_velocity (anchor);
					return true;
				});
			}
		}
	}

	// --- synthetic override (simulator) -------------------------------------
	for (int h = 0; h < 2; h++)
	{
		if (!sSynthOn[h])
			continue;
		out[h].posed = 1;
		out[h].present = 1;
		out[h].held = 1;
		out[h].originFromHand = sSynthPose[h];
		out[h].velocity = simd_make_float3 (0, 0, 0);
		out[h].buttons |= sSynthButtons[h];
		out[h].trigger = (sSynthButtons[h] & VKQ_SENSE_TRIGGER) ? 1.0f : 0.0f;
		out[h].grip = (sSynthButtons[h] & VKQ_SENSE_GRIP) ? 1.0f : 0.0f;
		out[h].stickX = sSynthStick[h][0];
		out[h].stickY = sSynthStick[h][1];
	}

	sTrackedMask = (out[0].posed ? 1 : 0) | (out[1].posed ? 2 : 0);
	sPollCount++;
}

/*
 * VKQ_Sense_UISample -- VR R5 item 1.
 *
 * Buttons and sticks ONLY, and deliberately without ARKit: the engine's UI pump
 * (VKQ_VR_UIInputPump, called from IN_Commands) needs the Sense pair to work in
 * the 2D window, on the 3D panel and inside SCR_ModalMessage's blocking loop —
 * none of which have a compositor frame, an alignment or a pose to speak of. A
 * menu does not care where your hand is, and asking the accessory-tracking
 * provider once per host frame from the game thread would be paying for an
 * answer nobody reads.
 *
 * Returns the number of hands that answered (0 = nothing connected and nothing
 * injected), so the caller can drop its edge state rather than latch a phantom.
 */
int VKQ_Sense_UISample (unsigned *btn, float *stick)
{
	@autoreleasepool
	{
		GCController *hands[2];
		int			  n = 0;
		if (!btn || !stick)
			return 0;
		btn[0] = btn[1] = 0u;
		stick[0] = stick[1] = stick[2] = stick[3] = 0.0f;
		pthread_mutex_lock (&sLock);
		hands[0] = sHand[0];
		hands[1] = sHand[1];
		pthread_mutex_unlock (&sLock);
		for (int h = 0; h < 2; h++)
		{
			GCController *c = hands[h];
			if (c != nil)
			{
				GCControllerDirectionPad *d;
				n++;
				btn[h] = vkq_sense_buttons (c);
				d = vkq_stick (c);
				if (d)
				{
					stick[h * 2 + 0] = d.xAxis.value;
					stick[h * 2 + 1] = d.yAxis.value;
				}
			}
			// Injected hands answer here too, or the simulator could never test
			// the one path this exists for (the modal).
			if (sSynthOn[h])
			{
				if (c == nil)
					n++;
				btn[h] |= sSynthButtons[h];
				stick[h * 2 + 0] = sSynthStick[h][0];
				stick[h * 2 + 1] = sSynthStick[h][1];
			}
		}
		return n;
	}
}

// ---------------------------------------------------------------------------
// Haptics — per hand, short bursts (charter A10). Built on demand and kept, so a
// shot does not pay for engine creation every time.
// ---------------------------------------------------------------------------
static CHHapticEngine *sHapticEngine[2];
static int			   sHapticStarting[2];

// Called from the GAME LOOP, on a trigger press. Everything expensive is kept
// off that thread: creating and starting a CHHapticEngine is synchronous and
// can take milliseconds, and paying that inside the frame that fires the shot
// would show up as a hitch at exactly the worst moment. So the engine is built
// once, asynchronously, and the first shot that finds it missing simply goes
// unfelt rather than stalling the frame.
// R6 part B2 — WHY A PULSE DID OR DID NOT ARRIVE, from the log alone.
//
// the user reported the holster proximity tick missing on device. Nothing in this
// function reports anything, so "the call site never ran", "it ran and the
// engine was not up yet", "it ran and there is no controller for that hand" and
// "it ran, it played, and it was too weak to feel" were four hypotheses with one
// symptom between them. Every pulse now names itself, its hand and its outcome;
// the line is throttled so a held trigger cannot flood the file, and the reason
// is carried through from the engine so a device log reads as a grammar.
static int	  sHapticSeq;
static double sHapticLastLog;
static void	  vkq_haptic_log (int hand, float strength, float duration, const char *why, const char *outcome)
{
	extern double Sys_DoubleTime (void);
	const double  now = Sys_DoubleTime ();
	sHapticSeq++;
	if (now - sHapticLastLog < 0.25 && strcmp (outcome, "played") == 0)
		return; // throttle the ordinary case only; every failure is logged
	sHapticLastLog = now;
	char line[256];
	snprintf (line, sizeof (line), "HAPTIC #%d %s hand=%s str=%.2f dur=%.3fs -> %s", sHapticSeq, why ? why : "-", hand ? "right" : "left", strength,
			  duration, outcome);
	VKQ_VR_DiagRoll (line);
}

void VKQ_Sense_Haptic (int hand, float strength, float duration, const char *why)
{
	if (hand < 0 || hand > 1 || strength <= 0.0f)
		return;
	GCController *c;
	pthread_mutex_lock (&sLock);
	c = sHand[hand];
	pthread_mutex_unlock (&sLock);
	if (c == nil)
	{
		vkq_haptic_log (hand, strength, duration, why, "NO CONTROLLER for that hand");
		return;
	}

	CHHapticEngine *eng = sHapticEngine[hand];
	if (eng == nil)
	{
		if (!sHapticStarting[hand])
		{
			sHapticStarting[hand] = 1;
			dispatch_async (dispatch_get_main_queue (), ^{
				GCDeviceHaptics *h = c.haptics;
				CHHapticEngine	*e = h ? [h createEngineWithLocality:GCHapticsLocalityDefault] : nil;
				NSError			*err = nil;
				if (e == nil)
					return;
				[e startAndReturnError:&err];
				if (err)
					return;
				e.autoShutdownEnabled = YES;
				sHapticEngine[hand] = e;
			});
		}
		vkq_haptic_log (hand, strength, duration, why, "engine not up yet (built asynchronously; this pulse is skipped)");
		return;
	}

	NSError				   *err = nil;
	CHHapticEventParameter *i = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:strength];
	CHHapticEventParameter *s = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.7f];
	// R6 part B2 — a TICK is a transient, not a 20 ms continuous buzz. The
	// proximity pulse was the shortest and weakest event in the grammar and it
	// was built the same way as the long ones; on these actuators that is close
	// to nothing. Anything at or under ~40 ms is now a transient, which is the
	// event type designed for exactly this ("you touched something") and reads as
	// a crisp tap rather than a faint hum.
	const BOOL	   tick = (duration <= 0.04f);
	CHHapticEvent *ev = tick ? [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient parameters:@[ i, s ] relativeTime:0]
							 : [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
															 parameters:@[ i, s ]
														   relativeTime:0
															   duration:duration];
	CHHapticPattern *pat = [[CHHapticPattern alloc] initWithEvents:@[ ev ] parameters:@[] error:&err];
	if (err || pat == nil)
	{
		vkq_haptic_log (hand, strength, duration, why, "pattern build FAILED");
		return;
	}
	id<CHHapticPatternPlayer> player = [eng createPlayerWithPattern:pat error:&err];
	if (err || player == nil)
	{
		vkq_haptic_log (hand, strength, duration, why, "player create FAILED");
		return;
	}
	[player startAtTime:0 error:&err];
	vkq_haptic_log (hand, strength, duration, why, err ? "start FAILED" : "played");
}

// The engine's name for the same thing (patch 0019 calls this from the input
// path). Kept as a thin forwarder so the engine never learns about GameController.
void VKQ_VR_Haptic (int hand, float strength, float duration, const char *why)
{
	extern float vkq_setting_f (const char *key, float def);
	if (vkq_setting_f ("vrHaptics", 1.0f) < 0.5f)
	{
		vkq_haptic_log (hand, strength, duration, why, "SUPPRESSED — Controller Haptics is off in settings");
		return;
	}
	VKQ_Sense_Haptic (hand, strength, duration, why);
}

// ---------------------------------------------------------------------------
// Status rows. The device round has to answer "did the declaration work" from
// the settings sheet and the file alone.
// ---------------------------------------------------------------------------
static char sStatusA[192], sStatusB[192];

const char *VKQ_Sense_StatusControllers (void)
{
	@autoreleasepool
	{
		NSArray<GCController *> *cs = GCController.controllers;
		if (cs.count == 0)
		{
			snprintf (sStatusA, sizeof (sStatusA), "none connected");
			return sStatusA;
		}
		NSMutableString *s = [NSMutableString string];
		int				 nSpatial = 0;
		for (GCController *c in cs)
		{
			NSString *cat = @"?";
			if (@available (visionOS 26.0, *))
				cat = c.productCategory ?: @"?";
			if (vkq_is_spatial (c))
				nSpatial++;
			[s appendFormat:@"%@[%@ %lub/%lud] ", s.length ? @"" : @"", cat, (unsigned long)c.physicalInputProfile.buttons.allKeys.count,
							(unsigned long)c.physicalInputProfile.dpads.allKeys.count];
		}
		snprintf (sStatusA, sizeof (sStatusA), "%lu pad(s), %d spatial: %s", (unsigned long)cs.count, nSpatial, s.UTF8String);
		return sStatusA;
	}
}

const char *VKQ_Sense_StatusTracking (void)
{
	if (sAuthState == -1)
		snprintf (sStatusB, sizeof (sStatusB), "accessory permission DENIED");
	else if (sAuthState == 0)
		snprintf (sStatusB, sizeof (sStatusB), "awaiting permission%s", sAuthAsked ? "" : " (not asked)");
	else if (sLoadOK == 0 && sLoadFail == 0)
		snprintf (sStatusB, sizeof (sStatusB), "allowed, no controller seen");
	else if (sLoadOK == 0)
		snprintf (sStatusB, sizeof (sStatusB), "allowed, %d load fail (err %d)%s", sLoadFail, sLoadFailCode,
				  sLoadFailCode == 1200 ? " — aggregate MFi" : "");
	else
		snprintf (sStatusB, sizeof (sStatusB), "%d loaded, %d anchor(s), %s%s%s", sLoadOK, sLastAnchorCount, (sTrackedMask & 1) ? "L" : "-",
				  (sTrackedMask & 2) ? "R" : "-", VKQ_Sense_SynthActive () ? " (synthetic)" : "");
	return sStatusB;
}

const char *VKQ_Sense_InventoryText (void) { return sInventory.length ? sInventory.UTF8String : "(no controller has connected)"; }

// ---------------------------------------------------------------------------
// Synthetic injection
// ---------------------------------------------------------------------------
void VKQ_Sense_SetSynthHand (int hand, int on, float yaw, float pitch, float roll, float x, float y, float z)
{
	if (hand < 0 || hand > 1)
		return;
	sSynthOn[hand] = on ? 1 : 0;
	if (on)
		sSynthPose[hand] = vkq_synth_matrix (yaw, pitch, roll, x, y, z);
	else
	{
		sSynthButtons[hand] = 0;
		sSynthStick[hand][0] = sSynthStick[hand][1] = 0.0f;
	}
}

void VKQ_Sense_SetSynthButtons (int hand, unsigned buttons)
{
	if (hand >= 0 && hand <= 1)
		sSynthButtons[hand] = buttons;
}

void VKQ_Sense_SetSynthStick (int hand, float x, float y)
{
	if (hand < 0 || hand > 1)
		return;
	sSynthStick[hand][0] = x;
	sSynthStick[hand][1] = y;
}

int VKQ_Sense_SynthActive (void) { return sSynthOn[0] || sSynthOn[1]; }
