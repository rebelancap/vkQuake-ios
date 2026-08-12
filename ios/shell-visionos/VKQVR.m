// VKQVR.m — the VR compositor loop (docs/VR-CHARTER.md R1: A3/A4/A5/A9).
//
// Loop shape is the shipped 3D panel's (VKQImmersive.m), and none of it is
// negotiable: query frame -> predict timing -> start/end update ->
// cp_time_wait_until(optimal input time) -> start submission -> query drawable ->
// ARKit device anchor at the frame's PRESENTATION time -> cp_drawable_set_device_anchor
// -> per-view passes through the view's texture map (texIdx / slice / logical
// viewport / that view's rasterization rate map) -> cp_drawable_encode_present ->
// commit -> end submission. A frame that misses the pacing wait or the device
// anchor is silently never displayed, and the depth attachment must be written or
// the compositor cannot reproject.
//
// What VR adds on top of the panel loop is the RENDEZVOUS (charter A4). The panel
// lets both sides free-run and samples whatever the engine last produced; in VR
// that reads as the world shaking with head sway, because the pose the engine
// rendered with is not the pose the compositor reprojects against. So each frame:
// compose both eyes from this frame's anchor, publish them with an id, wait
// (bounded) for the engine to render that exact id, then blit and present. A miss
// on either side re-presents the previous pair against the anchor THAT pair was
// rendered with — the compositor reprojects a repeat cleanly; it cannot rescue a
// mismatched anchor.
//
// Non-gameplay frames (menus, console, intermission, demos, loading) do not go to
// the eyes at all: the engine says so (VKQ_VR_GetPresentMode) and this loop draws
// the same world-locked panel quad the 3D mode ships, inside the VR space. That is
// charter A9, and it is why save/load, the console and every menu work in VR on
// day one with no new UI code.

#import "VKQVR.h"
#import "VKQSenseController.h"
#import <Metal/Metal.h>
#import <ARKit/ARKit.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>

// --- engine bridge -----------------------------------------------------------
// Shipped (overlay patch 0010):
extern void *VKQ_Get3DPresentMTLTextureForEye (int eye); // 1=left, 2=right
extern int	 VKQ_Get3DFrames (void);
extern void	 VKQ_Get3DPresentSize (int *w, int *h);
extern void	 VKQ_Set3DRenderSize (int w, int h);
// VR (overlay patch 0018):
extern unsigned long long VKQ_VR_PublishPose (
	const float *efpL, const float *projL, const float *tanL, const float *efpR, const float *projR, const float *tanR);
extern int	 VKQ_VR_WaitRendered (unsigned long long id, int timeout_ms);
extern void	 VKQ_VR_SetActive (int on);
extern int	 VKQ_VR_GetPresentMode (void);
extern void	 VKQ_VR_GetStats (int *met, int *engine_timeouts, int *shell_timeouts);
extern void	 VKQ_VR_SetHeadAngles (float pitch, float yaw);
extern void	 VKQ_VR_SetHeadPos (float x, float y, float z); // R6 B1: holster body frame
extern void	 VKQ_VR_TorsoSnap (void);
extern void	 VKQ_VR_SetBodyYaw (float yaw);
extern float VKQ_VR_GetBodyYaw (void);
extern void	 VKQ_VR_SetHeightOffset (float units);
extern void *VKQ_VR_GetDepthMTLTextureForEye (int eye);
// R1.1 — WHY this frame is on the panel (charter A9 predicate, gl_screen.c).
extern const char *VKQ_VR_PresentReasonString (void);
extern void		   VKQ_VR_PresentDebugString (char *out, int len);
extern int		   VKQ_VR_PresentEvalCount (void);
// R2 (overlay patch 0019) — one per-hand state, published with the head pose.
extern void	 VKQ_VR_PublishHand (
	 int hand, int tracked, int held, const float *xform12, const float *vel3, unsigned buttons, float trigger, float grip, float stick_x, float stick_y);
extern int	 VKQ_VR_HandsTracked (void);
extern void	 VKQ_VR_AimDebugString (char *out, int len);
extern float vkq_vr_movedir_delta;
// R3 / R2.1 (overlay patch 0020).
extern void VKQ_VR_SetWorldScale (float unitsPerMetre);
extern void VKQ_VR_SetStandingEye (float metres);
extern void VKQ_VR_EyeHeightDebugString (char *out, int len);
extern void VKQ_VR_ZoneLayoutString (char *out, int len);
extern void VKQ_VR_HolsterDebugString (char *out, int len);
extern void VKQ_VR_HolsterReset (void);
// R5 (overlay patch 0022) — the two measurements this round exists to make
// possible. Both are pinned once per world-mode entry and repeated in the
// rolling tail, and both have their own settings row.
extern void VKQ_VR_CrosshairDebugString (char *out, int len);
extern void VKQ_VR_HolsterGeomString (char *out, int len);
// Settings store (ios_settings.m).
extern float vkq_setting_f (const char *key, float def);
extern void	 vkq_setting_set_f (const char *key, float val); // R6 C3: the stored height baseline

volatile int vkq_vrStop = 0;
volatile int vkq_vrRunning = 0;
int			 vkq_vrFrameCount = 0;
// R6 part C3: 34 u/m is the shipping world scale — the slider is gone and the
// height derivation is correct at it (see VKQ_VR_UpdateEyeRise). `vkqvrscale`
// still moves it from the console for A/B work.
float		 vkq_vrWorldScale = 34.0f;
float		 vkq_vrHeightOffset = 0.0f; // metres added to the player's eye point
float		 vkq_vrRenderScale = 1.0f;	// eye target = physical drawable texture x this

int	  vkq_vrSynthPose = 0;
float vkq_vrSynthYaw = 0.0f;
float vkq_vrSynthPitch = 0.0f;
float vkq_vrSynthPos[3] = {0.0f, 0.0f, 0.0f};
int	  vkq_vrSynthEyes = 0;
float vkq_vrSynthIPD = 0.063f;

// Tracking-space alignment (charter A3): the LEVELLED head at recenter. The Quake
// player frame is pinned to it, so a head tilted at capture does not tilt the
// world, and head yaw/position are measured against it.
static simd_float4x4	vkq_vrAlign;
static bool				vkq_vrHaveAlign = false;
static volatile int32_t vkq_vrRecenterReq = 1; // 1 = (re)capture on the next tracked frame
static volatile int32_t vkq_vrCalibrateReq = 0;
static bool				vkq_vrBaselineLogged = false; // R6 C3: say the height arithmetic once per space
static bool				vkq_vrIpdLogged = false;
static bool				vkq_vrDepthLogged = false;
static int				vkq_vrHandMaskLogged = -1; // R2: which hands the file last reported

// Compositor depth contract: reverse-Z, near at depthRange.y metres, far infinite.
// Charter A5's documented fallback when the engine's per-eye depth snapshot is not
// available yet (first frames, or across a mid-space vid restart): 0.1 m / 2.0 m.
static const float kVRFallbackDepth = 0.05f;

// ---------------------------------------------------------------------------
// Diagnostics — Documents/vr-diagnostics.log. Charter standing rule: every
// device-round number is readable in-headset through Files. The R0 round lost its
// contract and IPD numbers because they were console-only.
//
// R1.1: the file is TWO sections, because R1's flat front-truncating buffer ate
// its own evidence. A 65 s device session logged 117 contract dumps (one every
// 1-3 frames, chasing eye-tracker jitter in deviceFromEye) and the 200 KB cap
// then discarded the head of the log — the VR entry lines, the first contract
// dump and the whole IPD CHECK block, i.e. exactly the numbers the round existed
// to collect. So:
//
//   PINNED   — appended once each and never truncated: VR entry/exit, the first
//              contract dump, the IPD check, present-mode transitions with the
//              predicate terms that caused them.
//   ROLLING  — everything periodic (pacing, recentres). Capped, and truncates
//              only from its OWN front, so it can never reach the pinned facts.
//
// Writes are throttled to 1 Hz (R1 rewrote the whole file at up to 90 Hz), with
// a forced flush on loop exit and on the explicit `vkqvrdiag` / settings action.
// ---------------------------------------------------------------------------
static NSMutableString *vkq_vrDiagPinned;
static NSMutableString *vkq_vrDiagRoll;
static BOOL				vkq_vrDiagPinnedFull;
static NSString		   *vkq_vrContractPrev; // STRUCTURAL fields only — see below
static NSString		   *vkq_vrStatus[VKQ_VR_STATUS_ROWS];
static dispatch_queue_t vkq_vrDiagQ;
static double			vkq_vrDiagLastWrite;
static BOOL				vkq_vrDiagPendingWrite;

// A pinned section is only "never truncated" if what goes into it is bounded.
// Entry/contract/IPD are; mode transitions are not (a player toggling the menu
// for an hour), so the pinned section has a budget and spills into the rolling
// tail once it is spent — loudly, in the file.
static const NSUInteger kVRPinnedBudget = 96000;
static const NSUInteger kVRRollCap = 120000;

static void vkq_vr_diag_init (void)
{
	static dispatch_once_t once;
	dispatch_once (&once, ^{
		vkq_vrDiagPinned = [NSMutableString string];
		vkq_vrDiagRoll = [NSMutableString string];
		vkq_vrDiagQ = dispatch_queue_create ("vkquake.vr.diag", DISPATCH_QUEUE_SERIAL);
	});
}

static void vkq_vr_diag_append (NSString *line, BOOL pinned)
{
	vkq_vr_diag_init ();
	NSLog (@"[vkquake] vr: %@", line);
	dispatch_async (vkq_vrDiagQ, ^{
		if (pinned && !vkq_vrDiagPinnedFull)
		{
			if (vkq_vrDiagPinned.length > kVRPinnedBudget)
			{
				vkq_vrDiagPinnedFull = YES;
				[vkq_vrDiagPinned appendString:@"--- pinned budget spent; further pinned lines are in the rolling tail below ---\n"];
			}
			else
			{
				[vkq_vrDiagPinned appendFormat:@"%@\n", line];
				return;
			}
		}
		[vkq_vrDiagRoll appendFormat:@"%@\n", line];
		// Truncate the ROLLING tail from its own front only. The pinned section
		// is a separate string and is structurally out of reach.
		if (vkq_vrDiagRoll.length > kVRRollCap)
			[vkq_vrDiagRoll deleteCharactersInRange:NSMakeRange (0, kVRRollCap / 2)];
	});
}

static void vkq_vr_diag (NSString *fmt, ...) NS_FORMAT_FUNCTION (1, 2);
static void vkq_vr_diag (NSString *fmt, ...)
{
	va_list ap;
	va_start (ap, fmt);
	NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
	va_end (ap);
	vkq_vr_diag_append (line, NO);
}

// Pinned: written once, kept forever, never truncated (within the budget above).
static void vkq_vr_diag_pin (NSString *fmt, ...) NS_FORMAT_FUNCTION (1, 2);
static void vkq_vr_diag_pin (NSString *fmt, ...)
{
	va_list ap;
	va_start (ap, fmt);
	NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
	va_end (ap);
	vkq_vr_diag_append (line, YES);
}

// Must be called on vkq_vrDiagQ.
static void vkq_vr_diag_write_now (void)
{
	NSString *docs = [NSSearchPathForDirectoriesInDomains (NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
	NSString *path = [docs stringByAppendingPathComponent:@"vr-diagnostics.log"];
	NSString *text = [NSString stringWithFormat:@"vkQuake Vision Pro — VR diagnostics\n"
												 "===================================\n"
												 "Written %@\n"
												 "Read this in the headset: Files -> On My Vision Pro -> vkQuake -> vr-diagnostics.log\n"
												 "Every line below is a measurement, not a guess. Send the whole file back.\n"
												 "\n"
												 "--- PINNED (entry, drawable contract, IPD check, mode transitions — never truncated) ---\n"
												 "%@\n"
												 "--- ROLLING TAIL (pacing and periodic lines; oldest are dropped first) ---\n"
												 "%@",
												[NSDate date], vkq_vrDiagPinned, vkq_vrDiagRoll];
	[text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	vkq_vrDiagLastWrite = CACurrentMediaTime ();
}

// Throttled: at most one file write per second, and a coalesced trailing write so
// the last state always lands. R1 rewrote a 200 KB file at up to 90 Hz.
void VKQ_VR_WriteDiagnostics (void)
{
	vkq_vr_diag_init ();
	dispatch_async (vkq_vrDiagQ, ^{
		const double now = CACurrentMediaTime ();
		const double since = now - vkq_vrDiagLastWrite;
		if (since < 1.0)
		{
			if (!vkq_vrDiagPendingWrite)
			{
				vkq_vrDiagPendingWrite = YES;
				dispatch_after (dispatch_time (DISPATCH_TIME_NOW, (int64_t)((1.0 - since) * NSEC_PER_SEC)), vkq_vrDiagQ, ^{
					vkq_vrDiagPendingWrite = NO;
					vkq_vr_diag_write_now ();
				});
			}
			return;
		}
		vkq_vr_diag_write_now ();
	});
}

// Unthrottled flush: loop exit, and the explicit user actions (`vkqvrdiag`,
// Settings -> Write Diagnostics File) where a stale file would be a lie.
void VKQ_VR_WriteDiagnosticsNow (void)
{
	vkq_vr_diag_init ();
	dispatch_async (vkq_vrDiagQ, ^{ vkq_vr_diag_write_now (); });
}

static void vkq_vr_set_status (int idx, NSString *s)
{
	if (idx >= 0 && idx < VKQ_VR_STATUS_ROWS)
		vkq_vrStatus[idx] = s;
}

// C entry points so VKQSenseController.m — which knows about hardware and
// nothing about this file's buffers — writes into the SAME pinned/rolling
// diagnostics sections. Controller facts are exactly the kind of thing the
// charter's no-console-only rule exists for: the person who can produce them is
// wearing the headset.
void VKQ_VR_DiagPin (const char *line)
{
	if (line)
		vkq_vr_diag_pin (@"%s", line);
}
void VKQ_VR_DiagRoll (const char *line)
{
	if (line)
		vkq_vr_diag (@"%s", line);
}

const char *VKQ_VR_StatusLine (int idx)
{
	if (idx < 0 || idx >= VKQ_VR_STATUS_ROWS || vkq_vrStatus[idx] == nil)
		return "-";
	return vkq_vrStatus[idx].UTF8String;
}

// ---------------------------------------------------------------------------
// Drawable contract. R1 hashed EVERY field into one string and flagged
// *** CHANGED *** on any difference — which on the M5 Vision Pro fired 117 times
// in 65 s, because the eye tracker refines deviceFromEye at the 4th decimal
// every frame. The spam then truncated the log that was supposed to prove
// anything. So the contract is split:
//
//   STRUCTURAL — layout, foveation, formats, maxRenderQuality, view/texture/
//                ratemap counts, texture sizes and types, depth ranges, and each
//                view's texIdx / slice / viewport / physical texture size. These
//                are the facts the render path is BUILT on; a change here is the
//                charter §11 stop-and-consult event.
//   VOLATILE   — deviceFromEye and the projection/tangents. Real per-frame
//                measurements, dumped alongside the structural block so they are
//                on the record, but NEVER diffed. Drift here is the device
//                working correctly.
// ---------------------------------------------------------------------------
static NSString *vkq_vr_contract_structural (cp_layer_renderer_t lr, cp_drawable_t drawable)
{
	NSMutableString					 *s = [NSMutableString string];
	cp_layer_renderer_configuration_t cfg = cp_layer_renderer_get_configuration (lr);
	simd_float2						  defRange = cp_layer_renderer_configuration_get_default_depth_range (cfg);
	simd_float2						  range = cp_drawable_get_depth_range (drawable);
	size_t							  views = cp_drawable_get_view_count (drawable);
	size_t							  texCount = cp_drawable_get_texture_count (drawable);
	size_t							  rmCount = cp_drawable_get_rasterization_rate_map_count (drawable);

	int	  target = -1;
	float maxQuality = -1.0f;
	if (__builtin_available (visionOS 26.0, *))
	{
		target = (int)cp_drawable_get_target (drawable);
		maxQuality = cp_layer_renderer_configuration_get_max_render_quality (cfg);
	}

	[s appendFormat:@"layout=%u foveation=%d colorFmt=%lu depthFmt=%lu maxRenderQuality=%.3f\n", (unsigned)cp_layer_renderer_configuration_get_layout (cfg),
					(int)cp_layer_renderer_configuration_get_foveation_enabled (cfg), (unsigned long)cp_layer_renderer_configuration_get_color_format (cfg),
					(unsigned long)cp_layer_renderer_configuration_get_depth_format (cfg), maxQuality];
	[s appendFormat:@"views=%zu textures=%zu ratemaps=%zu depthRange=[%g,%g] defaultDepthRange=[%g,%g] target=%d\n", views, texCount, rmCount, range.x, range.y,
					defRange.x, defRange.y, target];

	for (size_t t = 0; t < texCount; t++)
	{
		id<MTLTexture> c = cp_drawable_get_color_texture (drawable, t);
		id<MTLTexture> d = cp_drawable_get_depth_texture (drawable, t);
		[s appendFormat:@"tex%zu color=%lux%lu arr=%lu type=%lu fmt=%lu | depth=%lux%lu arr=%lu fmt=%lu\n", t, (unsigned long)c.width, (unsigned long)c.height,
						(unsigned long)c.arrayLength, (unsigned long)c.textureType, (unsigned long)c.pixelFormat, (unsigned long)d.width,
						(unsigned long)d.height, (unsigned long)d.arrayLength, (unsigned long)d.pixelFormat];
	}

	for (size_t v = 0; v < views; v++)
	{
		cp_view_t			  view = cp_drawable_get_view (drawable, v);
		cp_view_texture_map_t tmap = cp_view_get_view_texture_map (view);
		MTLViewport			  vp = cp_view_texture_map_get_viewport (tmap);
		size_t				  texIdx = cp_view_texture_map_get_texture_index (tmap);
		id<MTLTexture>		  ct = cp_drawable_get_color_texture (drawable, texIdx);
		// LOGICAL vs PHYSICAL, permanently on the record. The viewport is the
		// foveation-EXPANDED logical raster area (5087x4081 on device); the
		// texture is what actually exists in memory (2048x1984). R1 sized the
		// engine's eye target from the viewport and asked it for ~21 MP an eye.
		[s appendFormat:@"view%zu texIdx=%zu slice=%zu viewport(LOGICAL)=(%g,%g %gx%g) texture(PHYSICAL)=%lux%lu\n", v, texIdx,
						cp_view_texture_map_get_slice_index (tmap), vp.originX, vp.originY, vp.width, vp.height, (unsigned long)ct.width,
						(unsigned long)ct.height];
	}
	return s;
}

static NSString *vkq_vr_contract_volatile (cp_drawable_t drawable)
{
	NSMutableString *s = [NSMutableString string];
	size_t			 views = cp_drawable_get_view_count (drawable);
	for (size_t v = 0; v < views; v++)
	{
		cp_view_t	  view = cp_drawable_get_view (drawable, v);
		simd_float4x4 dfe = cp_view_get_transform (view); // device-from-eye
		simd_float4x4 proj = matrix_identity_float4x4;
		if (__builtin_available (visionOS 2.0, *))
			proj = cp_drawable_compute_projection (drawable, cp_axis_direction_convention_right_up_back, v);
		// Charter A3 tangent recovery (never a hand-rolled FOV).
		float m00 = proj.columns[0].x, m02 = proj.columns[2].x;
		float m11 = proj.columns[1].y, m12 = proj.columns[2].y;
		float tR = (m02 + 1.0f) / m00, tL = (m02 - 1.0f) / m00;
		float tU = (m12 + 1.0f) / m11, tD = (m12 - 1.0f) / m11;
		[s appendFormat:@"view%zu tangents L=%.5f R=%.5f U=%.5f D=%.5f  (hFOV=%.2fdeg vFOV=%.2fdeg)\n", v, tL, tR, tU, tD,
						(atanf (tR) - atanf (tL)) * 180.0f / (float)M_PI, (atanf (tU) - atanf (tD)) * 180.0f / (float)M_PI];
		[s appendFormat:@"view%zu proj(RUB) m00=%.6f m02=%.6f m11=%.6f m12=%.6f m22=%.6f m23=%.6f m32=%.6f\n", v, m00, m02, m11, m12, proj.columns[2].z,
						proj.columns[3].z, proj.columns[2].w];
		[s appendFormat:@"view%zu deviceFromEye t=(%.5f,%.5f,%.5f)\n", v, dfe.columns[3].x, dfe.columns[3].y, dfe.columns[3].z];
	}
	return s;
}

static void vkq_vr_dump_contract (cp_layer_renderer_t lr, cp_drawable_t drawable)
{
	NSString *now = vkq_vr_contract_structural (lr, drawable);
	if (vkq_vrContractPrev && [vkq_vrContractPrev isEqualToString:now])
		return; // structurally identical — volatile drift is NOT a contract change
	BOOL changed = (vkq_vrContractPrev != nil);
	vkq_vrContractPrev = now;
	vkq_vr_diag_pin (@"CONTRACT (frame %d)%@", vkq_vrFrameCount, changed ? @"  *** STRUCTURE CHANGED — charter §11 stop-and-consult ***" : @"");
	for (NSString *line in [now componentsSeparatedByString:@"\n"])
		if (line.length)
			vkq_vr_diag_pin (@"  %@", line);
	vkq_vr_diag_pin (@"  --- volatile (measured, never diffed: the eye tracker refines these every frame) ---");
	for (NSString *line in [vkq_vr_contract_volatile (drawable) componentsSeparatedByString:@"\n"])
		if (line.length)
			vkq_vr_diag_pin (@"  %@", line);

	size_t				  views = cp_drawable_get_view_count (drawable);
	cp_view_texture_map_t tmap0 = cp_view_get_view_texture_map (cp_drawable_get_view (drawable, 0));
	MTLViewport			  vp0 = cp_view_texture_map_get_viewport (tmap0);
	id<MTLTexture>		  ct0 = cp_drawable_get_color_texture (drawable, cp_view_texture_map_get_texture_index (tmap0));
	vkq_vr_set_status (
		0, [NSString stringWithFormat:@"%zu view%s, %lu×%lu/eye (logical %.0f×%.0f)", views, views == 1 ? "" : "s", (unsigned long)ct0.width,
									  (unsigned long)ct0.height, vp0.width, vp0.height]);
	VKQ_VR_WriteDiagnostics ();
}

// ---------------------------------------------------------------------------
// Charter A3 matrix composition.
// ---------------------------------------------------------------------------

// Level-ise a tracking-space head pose: keep the position, keep the yaw, drop
// pitch and roll.
static simd_float4x4 vkq_vr_level (simd_float4x4 m)
{
	simd_float3 pos = m.columns[3].xyz;
	simd_float3 back = m.columns[2].xyz; // +Z of an ARKit pose points BACK (right-up-back)
	back.y = 0.0f;
	float len = simd_length (back);
	back = (len < 1e-4f) ? simd_make_float3 (0, 0, 1) : back / len;
	simd_float3	  up = simd_make_float3 (0, 1, 0);
	simd_float3	  right = simd_normalize (simd_cross (up, back));
	simd_float4x4 o;
	o.columns[0] = simd_make_float4 (right, 0.0f);
	o.columns[1] = simd_make_float4 (up, 0.0f);
	o.columns[2] = simd_make_float4 (back, 0.0f);
	o.columns[3] = simd_make_float4 (pos, 1.0f);
	return o;
}

// Synthetic head pose in ARKit convention: T(pos) . Ry(yaw) . Rx(pitch).
static simd_float4x4 vkq_vr_synth_head (void)
{
	float		  y = vkq_vrSynthYaw * (float)M_PI / 180.0f;
	float		  p = vkq_vrSynthPitch * (float)M_PI / 180.0f;
	float		  cy = cosf (y), sy = sinf (y), cp = cosf (p), sp = sinf (p);
	simd_float4x4 ry = matrix_identity_float4x4, rx = matrix_identity_float4x4;
	ry.columns[0] = simd_make_float4 (cy, 0, -sy, 0);
	ry.columns[2] = simd_make_float4 (sy, 0, cy, 0);
	rx.columns[1] = simd_make_float4 (0, cp, sp, 0);
	rx.columns[2] = simd_make_float4 (0, -sp, cp, 0);
	simd_float4x4 m = simd_mul (ry, rx);
	m.columns[3] = simd_make_float4 (vkq_vrSynthPos[0], vkq_vrSynthPos[1], vkq_vrSynthPos[2], 1.0f);
	return m;
}

// Rebuild the compositor's asymmetric frustum in the ENGINE's own convention:
// infinite-far reverse-Z (GL_FrustumMatrix with f -> inf gives m22=0, m23=n),
// column-major float[16] indexed [col*4+row], and vkQuake's Vulkan Y-flip.
//
// depth = n / -z is dimensionless, so with n = 0.1 m * worldscale the engine's
// depth values are NUMERICALLY IDENTICAL to what the compositor expects — which
// is what makes charter A5's per-pixel depth handoff a plumbing job rather than a
// conversion (R0 verified this against the drawable's own contract).
static void vkq_vr_engine_projection (float out[16], float tangents[4], simd_float4x4 cpProj, float nearUnits)
{
	float m00 = cpProj.columns[0].x, m02 = cpProj.columns[2].x;
	float m11 = cpProj.columns[1].y, m12 = cpProj.columns[2].y;
	float tR = (m02 + 1.0f) / m00, tL = (m02 - 1.0f) / m00;
	float tU = (m12 + 1.0f) / m11, tD = (m12 - 1.0f) / m11;

	tangents[0] = tL, tangents[1] = tR, tangents[2] = tU, tangents[3] = tD;

	memset (out, 0, 16 * sizeof (float));
	out[0 * 4 + 0] = 2.0f / (tR - tL);
	out[2 * 4 + 0] = (tR + tL) / (tR - tL);
	out[1 * 4 + 1] = -(2.0f / (tU - tD)); // engine Y-flip
	out[2 * 4 + 1] = -((tU + tD) / (tU - tD));
	out[2 * 4 + 2] = 0.0f;	  // infinite far
	out[3 * 4 + 2] = nearUnits; // z_clip = n
	out[2 * 4 + 3] = -1.0f;	  // w_clip = -z
}

// eyeFromPlayer: Quake player frame (UNITS, right-up-back, origin at the body's
// eye point, looking down -Z) -> this eye's space.
//
//   eyeFromPlayer = S(ws) . inverse(originFromEye) . align . S(1/ws)
//
// i.e. the rigid metric transform inverse(originFromEye) . align with its
// translation column scaled metres -> units. The engine multiplies this onto its
// OWN yaw-only base view matrix (patch 0018), so the Quake<->ARKit axis bridge is
// the engine's proven Rx(-90).Rz(90) and is never written by hand (R0 finding 3).
static simd_float4x4 vkq_vr_eye_from_player (simd_float4x4 originFromEye, simd_float4x4 align, float worldScale)
{
	simd_float4x4 m = simd_mul (simd_inverse (originFromEye), align);
	m.columns[3].x *= worldScale;
	m.columns[3].y *= worldScale;
	m.columns[3].z *= worldScale;
	return m;
}

// R2 — the SAME chain, read the other way: tracking space -> the Quake player
// frame. `playerFromTracking = S(ws) . inverse(align)`, i.e. the rigid transform
// inverse(align) with its translation scaled metres -> units.
//
// This is the ONLY place a hand becomes a Quake quantity. The engine takes the
// result as a player-frame pose and turns it into world space with the body yaw
// its own render base already uses, so a recenter, a world-scale drag or a snap
// turn moves the eyes, the aim, the weapon and the laser together by
// construction — there is no second derivation to keep in step (R3's holsters
// are built on this, which is why it is worth saying twice).
static simd_float4x4 vkq_vr_player_from_tracking (simd_float4x4 originFromThing, simd_float4x4 align, float worldScale)
{
	simd_float4x4 m = simd_mul (simd_inverse (align), originFromThing);
	m.columns[3].x *= worldScale;
	m.columns[3].y *= worldScale;
	m.columns[3].z *= worldScale;
	return m;
}

void VKQ_VR_Recenter (void) { vkq_vrRecenterReq = 1; }
void VKQ_VR_CalibrateHeight (void) { vkq_vrCalibrateReq = 1; }

// ---------------------------------------------------------------------------
// R6 part C3 — THE STANDING-HEIGHT BASELINE, MEASURED ONCE AND REMEMBERED.
//
// Before this round the standing eye height was whatever the alignment happened
// to hold, and the alignment is re-derived on every recentre — so a player who
// recentred while sitting became permanently short until they thought to press
// Calibrate Height, and "Height +9 in" was the only visible way to fix it.
//
// Now the FIRST entry into VR with a valid alignment measures the player and
// stores the number; Height is a trim on top of it and therefore reads 0.0 for
// a calibrated player, which is what makes 0.0 a meaningful default. Re-calibrate
// clears the baseline and re-measures (and zeroes the trim, see ios_settings.m).
// ---------------------------------------------------------------------------
#define VKQ_VR_BASELINE_KEY "vrHeightBase"

void VKQ_VR_ClearHeightBaseline (void)
{
	vkq_setting_set_f (VKQ_VR_BASELINE_KEY, 0.0f);
	vkq_vrBaselineLogged = false;
}

// A plausible standing/seated eye height, in metres above the tracking floor.
// Outside this the number is not a person and must not become one.
static bool vkq_vr_baseline_sane (float m) { return m > 0.6f && m < 2.6f; }

// ---------------------------------------------------------------------------
// Present pipelines. Two of them, deliberately:
//   BLIT  — charter A5's fullscreen per-view blit for the VR world, writing REAL
//           per-pixel depth from the engine's per-eye snapshot (constant-depth
//           variant for the frames where the snapshot is not up yet).
//   QUAD  — the shipped 3D panel's world-locked screen, reused verbatim as VR's
//           menu/console surface (charter A9).
// ---------------------------------------------------------------------------
static id<MTLRenderPipelineState> vkq_vrBlitDepthPipe, vkq_vrBlitConstPipe, vkq_vrQuadPipe, vkq_vrHudPipe;
static id<MTLDepthStencilState>	  vkq_vrDepthState;
static id<MTLTexture>			  vkq_vrHudTex;

typedef struct
{
	float srgbDecode;
	float constDepth;
	float sharpen; // R4 part F: contrast-adaptive sharpening strength, 0 = off
	float pad;
} vkq_vr_blit_params_t;

static NSString *const kVKQVRShader =
	@"#include <metal_stdlib>\n"
	 "using namespace metal;\n"
	 "struct VOut { float4 pos [[position]]; float2 uv; };\n"
	 "struct FOut { float4 color [[color(0)]]; float depth [[depth(any)]]; };\n"
	 "struct Params { float srgbDecode; float constDepth; float sharpen; float pad; };\n"
	 // fullscreen triangle; the engine image's row 0 is its top -> flip V
	 "vertex VOut vkqvr_vs(uint vid [[vertex_id]]) {\n"
	 "  const float2 p[3] = { float2(-1,-3), float2(3,1), float2(-1,1) };\n"
	 "  VOut o; o.pos = float4(p[vid], 0.5, 1.0);\n"
	 "  o.uv = float2((p[vid].x+1.0)*0.5, (1.0-p[vid].y)*0.5);\n"
	 "  return o;\n"
	 "}\n"
	 "static inline float3 vkqvr_decode(float3 c, float d) { return d > 0.5 ? pow(c, float3(2.2)) : c; }\n"
	 // R4 part F -- contrast-adaptive sharpening, AMD FidelityFX CAS in its
	 // cheapest form: one 3x3 tap set, a local min/max that decides how much
	 // sharpening the neighbourhood can take, and a clamped final blend. It runs
	 // in the WORLD blit only, where the engine's 2048x1984 eye image is being
	 // upscaled 2.5x into the compositor's logical viewport -- that upscale is the
	 // entire cause of the softness (R3 section 5.3 proved it is not mip bias),
	 // and this is what lets 1.25-1.5x approach 2.0x's crispness while still
	 // presenting at 120 Hz. The adaptive weight is what keeps it from ringing:
	 // in a flat region mn/mx are close, the weight collapses, and nothing
	 // happens. The panel path never calls it.
	 "static inline float3 vkqvr_cas(texture2d<float> tex, sampler s, float2 uv, float amount) {\n"
	 "  float2 ts = float2(1.0/float(tex.get_width()), 1.0/float(tex.get_height()));\n"
	 "  float3 a = tex.sample(s, uv + float2(-ts.x, -ts.y)).rgb;\n"
	 "  float3 b = tex.sample(s, uv + float2( 0.0,  -ts.y)).rgb;\n"
	 "  float3 c = tex.sample(s, uv + float2( ts.x, -ts.y)).rgb;\n"
	 "  float3 d = tex.sample(s, uv + float2(-ts.x,  0.0 )).rgb;\n"
	 "  float3 e = tex.sample(s, uv).rgb;\n"
	 "  float3 f = tex.sample(s, uv + float2( ts.x,  0.0 )).rgb;\n"
	 "  float3 g = tex.sample(s, uv + float2(-ts.x,  ts.y)).rgb;\n"
	 "  float3 h = tex.sample(s, uv + float2( 0.0,   ts.y)).rgb;\n"
	 "  float3 i = tex.sample(s, uv + float2( ts.x,  ts.y)).rgb;\n"
	 "  float3 mn = min(min(min(d,e),min(f,b)),h);\n"
	 "  float3 mx = max(max(max(d,e),max(f,b)),h);\n"
	 "  mn += min(min(a,c),min(g,i)); mx += max(max(a,c),max(g,i));\n"
	 "  float3 rcp = 1.0 / max(mx, float3(1.0/1024.0));\n"
	 "  float3 amp = clamp(min(mn, 2.0 - mx) * rcp, 0.0, 1.0);\n"
	 "  amp = sqrt(amp);\n"
	 // R5 item 6, CORRECTED. `amount` is the user's 0-100% Sharpen slider, and
	 // the first R5 build simply widened CAS's constant to mix(8,2,amount) so
	 // that 50% would land on R4's fixed 5.0. That is outside the filter's
	 // stable range and the simulator caught it immediately: edge energy went
	 // 0%=3.36, 50%=7.74, 100%=3.99 — sharper in the middle and then WORSE.
	 //
	 // The reason is in the last line. CAS reconstructs as sum/(1+4w) with
	 // w = -amp/k, so the denominator is 1 - 4*amp/k and stays positive only
	 // while k > 4*amp. At k=2 it goes to zero and then NEGATIVE, which inverts
	 // the neighbourhood instead of sharpening it — AMD ships k in [8,5] for
	 // exactly this reason, not as a taste choice.
	 //
	 // So the slider drives two things that are each individually safe:
	 //   0 -> 50%   k walks 8 -> 5, i.e. none of CAS's range to all of it, and
	 //              50% is therefore EXACTLY the strength R4 shipped;
	 //   50 -> 100% the reconstructed pixel is EXTRAPOLATED away from the
	 //              original by up to 1.8x, which is a plain linear blend on
	 //              the output and cannot destabilise the filter.
	 "  float amt = clamp(amount, 0.0, 1.0);\n"
	 "  float k = mix(8.0, 5.0, min(1.0, amt * 2.0));\n"
	 "  float3 w = amp * (-1.0 / k);\n"
	 "  float3 sum = (b + d + f + h) * w + e;\n"
	 "  float3 cas = clamp(sum / (1.0 + 4.0 * w), 0.0, 1.0);\n"
	 "  float over = 1.0 + max(0.0, amt - 0.5) * 2.0 * 0.8;\n"
	 "  return clamp(mix(e, cas, over), 0.0, 1.0);\n"
	 "}\n"
	 // Real per-pixel depth: the engine's reverse-Z values ARE the compositor's
	 // (same near plane, infinite far, dimensionless n/-z) so they pass through
	 // untouched — no remap exists here to get wrong.
	 "fragment FOut vkqvr_fs_depth(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
	 "                             depth2d<float> dep [[texture(1)]], constant Params& p [[buffer(0)]]) {\n"
	 "  constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
	 "  constexpr sampler ds(filter::nearest, address::clamp_to_edge);\n"
	 "  float3 src = p.sharpen > 0.001 ? vkqvr_cas(tex, s, in.uv, p.sharpen) : tex.sample(s, in.uv).rgb;\n"
	 "  FOut o; o.color = float4(vkqvr_decode(src, p.srgbDecode), 1.0);\n"
	 "  o.depth = dep.sample(ds, in.uv);\n"
	 "  return o;\n"
	 "}\n"
	 "fragment FOut vkqvr_fs_const(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
	 "                             constant Params& p [[buffer(0)]]) {\n"
	 "  constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
	 "  float3 src = p.sharpen > 0.001 ? vkqvr_cas(tex, s, in.uv, p.sharpen) : tex.sample(s, in.uv).rgb;\n"
	 "  FOut o; o.color = float4(vkqvr_decode(src, p.srgbDecode), 1.0);\n"
	 "  o.depth = p.constDepth;\n"
	 "  return o;\n"
	 "}\n"
	 // world-locked panel (menus/console inside the VR space)
	 "struct QOut { float4 pos [[position]]; float2 uv; };\n"
	 "vertex QOut vkqvr_quad_vs(uint vid [[vertex_id]], constant float4x4& mvp [[buffer(0)]]) {\n"
	 "  const float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
	 "  QOut o; o.pos = mvp * float4(p[vid], 0.0, 1.0);\n"
	 "  o.uv = float2((p[vid].x+1.0)*0.5, 1.0-(p[vid].y+1.0)*0.5);\n"
	 "  return o;\n"
	 "}\n"
	 "fragment float4 vkqvr_quad_fs(QOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
	 "                              constant float& srgbDecode [[buffer(0)]]) {\n"
	 "  constexpr sampler s(filter::linear, mip_filter::linear, max_anisotropy(16));\n"
	 "  return float4(vkqvr_decode(tex.sample(s, in.uv).rgb, srgbDecode), 1.0);\n"
	 "}\n"
	 // R4 part D -- the head-locked HUD. Straight RGBA with premultiplied-source
	 // blending; no sRGB games, because the shell rasterises this texture itself
	 // and knows exactly what is in it.
	 "fragment float4 vkqvr_hud_fs(QOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {\n"
	 "  constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
	 "  return tex.sample(s, in.uv);\n"
	 "}\n";

static void vkq_vr_build_pipelines (id<MTLDevice> dev, MTLPixelFormat colorFmt, MTLPixelFormat depthFmt)
{
	NSError		  *err = nil;
	id<MTLLibrary> lib = [dev newLibraryWithSource:kVKQVRShader options:nil error:&err];
	if (!lib)
	{
		vkq_vr_diag (@"FATAL shader compile failed: %@", err.localizedDescription);
		return;
	}
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [lib newFunctionWithName:@"vkqvr_vs"];
	pd.fragmentFunction = [lib newFunctionWithName:@"vkqvr_fs_depth"];
	pd.colorAttachments[0].pixelFormat = colorFmt;
	pd.depthAttachmentPixelFormat = depthFmt;
	vkq_vrBlitDepthPipe = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
	if (!vkq_vrBlitDepthPipe)
		vkq_vr_diag (@"blit(depth) pipeline FAILED: %@", err.localizedDescription);

	pd.fragmentFunction = [lib newFunctionWithName:@"vkqvr_fs_const"];
	vkq_vrBlitConstPipe = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
	if (!vkq_vrBlitConstPipe)
		vkq_vr_diag (@"blit(const) pipeline FAILED: %@", err.localizedDescription);

	MTLRenderPipelineDescriptor *qd = [MTLRenderPipelineDescriptor new];
	qd.vertexFunction = [lib newFunctionWithName:@"vkqvr_quad_vs"];
	qd.fragmentFunction = [lib newFunctionWithName:@"vkqvr_quad_fs"];
	qd.colorAttachments[0].pixelFormat = colorFmt;
	qd.depthAttachmentPixelFormat = depthFmt;
	vkq_vrQuadPipe = [dev newRenderPipelineStateWithDescriptor:qd error:&err];
	if (!vkq_vrQuadPipe)
		vkq_vr_diag (@"panel pipeline FAILED: %@", err.localizedDescription);

	// R4 part D: same quad vertex stage, alpha-blended, so the HUD floats over
	// the world instead of punching a rectangle through it.
	qd.fragmentFunction = [lib newFunctionWithName:@"vkqvr_hud_fs"];
	qd.colorAttachments[0].blendingEnabled = YES;
	qd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
	qd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
	qd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
	qd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
	qd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	qd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	vkq_vrHudPipe = [dev newRenderPipelineStateWithDescriptor:qd error:&err];
	if (!vkq_vrHudPipe)
		vkq_vr_diag (@"HUD pipeline FAILED: %@", err.localizedDescription);

	MTLDepthStencilDescriptor *ds = [MTLDepthStencilDescriptor new];
	ds.depthCompareFunction = MTLCompareFunctionAlways;
	ds.depthWriteEnabled = YES; // the compositor rejects frames it cannot reproject
	vkq_vrDepthState = [dev newDepthStencilStateWithDescriptor:ds];
	vkq_vr_diag (@"pipelines built (colorFmt=%lu depthFmt=%lu)", (unsigned long)colorFmt, (unsigned long)depthFmt);
}

// ---------------------------------------------------------------------------
// R4 part D — the head-locked HUD.
//
// Drawn HERE rather than in the engine, and that is the whole design. VR world
// mode suppresses the engine's 2D composite (charter A9) because a flat layer
// lands at the near plane in BOTH eyes: identical pixels at a depth that
// contradicts everything behind them, which is the depth-rivalry fight that
// kept the weapon wheel out of R3. A quad the shell places 1.75 m in front of
// the head has one honest depth, both eyes converge on it, and the compositor
// reprojects it correctly because the quad writes real depth.
//
// The glyphs are rasterised here too — a 3x5 bitmap font is forty lines and
// costs nothing, where plumbing the engine's conchars through Vulkan into a
// shader-readable Metal texture is a whole subsystem for two numbers.
// ---------------------------------------------------------------------------
// R5 item 5: taller and wider, because the icons are Quake's own sbar art rather
// than a 3x5 glyph, and the user asked for a readout he does not have to decode.
//
// The width is set by the WORST case, which is Immersive dual wield: four
// groups (health, armour, and an ammo box per hand), each an icon plus up to
// three digits. At the scales below that is 706 px, and a texture narrower than
// that would silently clip the off hand's ammo — the blits are bounds-checked,
// so the failure would be a missing number rather than a crash, which is worse.
// The quad's angular size is scaled to match, so a digit keeps the apparent
// height R4 shipped (~1.7 deg) instead of shrinking to fit the extra content.
#define VKQ_HUD_W 720
#define VKQ_HUD_H 96
#define VKQ_HUD_ICON_MAX 48 // biggest sbar lump we accept (face* and sb_* are 24x24)

// 3x5, column-major bits (bit 0 = top). DIGITS ONLY now — the "heart-ish" and
// "box" marks are gone, because Quake's own icons replaced them.
static const unsigned char kVKQHudFont[11][3] = {
	{0x1F, 0x11, 0x1F}, // 0
	{0x00, 0x1F, 0x00}, // 1
	{0x1D, 0x15, 0x17}, // 2
	{0x15, 0x15, 0x1F}, // 3
	{0x07, 0x04, 0x1F}, // 4
	{0x17, 0x15, 0x1D}, // 5
	{0x1F, 0x15, 0x1D}, // 6
	{0x01, 0x01, 0x1F}, // 7
	{0x1F, 0x15, 0x1F}, // 8
	{0x17, 0x15, 0x1F}, // 9
	{0x00, 0x00, 0x00}, // 10 space
};

static void vkq_hud_blit (unsigned char *px, int gx, int gy, int glyph, int px_scale, unsigned rgba)
{
	int col, row, sx, sy;
	if (glyph < 0 || glyph > 10)
		return;
	for (col = 0; col < 3; col++)
		for (row = 0; row < 5; row++)
		{
			if (!(kVKQHudFont[glyph][col] & (1u << row)))
				continue;
			for (sy = 0; sy < px_scale; sy++)
				for (sx = 0; sx < px_scale; sx++)
				{
					const int x = gx + col * px_scale + sx, y = gy + row * px_scale + sy;
					if (x < 0 || y < 0 || x >= VKQ_HUD_W || y >= VKQ_HUD_H)
						continue;
					((unsigned *)px)[y * VKQ_HUD_W + x] = rgba;
				}
		}
}

static int vkq_hud_digits (int value)
{
	int n = 1;
	if (value < 0)
		return 0;
	while (value >= 10 && n < 8)
	{
		value /= 10;
		n++;
	}
	return n;
}

static int vkq_hud_number (unsigned char *px, int x, int y, int value, int scale, unsigned rgba)
{
	int	 digits[8], n = 0, i;
	if (value < 0)
		return x;
	do
	{
		digits[n++] = value % 10;
		value /= 10;
	} while (value && n < 8);
	for (i = n - 1; i >= 0; i--)
	{
		vkq_hud_blit (px, x, y, digits[i], scale, rgba);
		x += (3 + 1) * scale;
	}
	return x;
}

/*
 * R5 item 5 — QUAKE'S OWN ICONOGRAPHY.
 *
 * the user on the R4 readout: the glyphs are unclear. He is right — a diamond and
 * a small box are two shapes nobody has ever seen in Quake. The shapes a Quake
 * player reads without thinking are already in gfx.wad: the face that gets more
 * hurt as health drops, the armour plate for the armour actually being worn, and
 * the four ammo boxes. The engine hands them over as RGBA (VKQ_VR_HudIcon) and
 * they are nearest-neighbour scaled here, which keeps 24x24 art crisp and
 * pixel-honest at panel distance instead of blurring it into mush.
 *
 * A mod that ships its own sbar art therefore gets its own art in the VR HUD,
 * free and with no per-mod code — which is the whole reason to use the engine's
 * pics rather than authoring icons in the shell.
 *
 * Returns the x cursor after the icon, or the input x unchanged when the lump is
 * missing, so the caller can fall back and the number is never orphaned.
 */
static int vkq_hud_icon (unsigned char *px, int x, int ycentre, const char *name, int scale)
{
	extern int		VKQ_VR_HudIcon (const char *name, unsigned *out, int maxw, int maxh, int *ow, int *oh);
	static unsigned buf[VKQ_HUD_ICON_MAX * VKQ_HUD_ICON_MAX];
	int				w = 0, h = 0, sx, sy, dx, dy;
	if (!name || !name[0])
		return x;
	if (!VKQ_VR_HudIcon (name, buf, VKQ_HUD_ICON_MAX, VKQ_HUD_ICON_MAX, &w, &h))
		return x;
	for (sy = 0; sy < h; sy++)
		for (sx = 0; sx < w; sx++)
		{
			const unsigned c = buf[sy * VKQ_HUD_ICON_MAX + sx];
			if ((c >> 24) == 0u)
				continue;
			for (dy = 0; dy < scale; dy++)
				for (dx = 0; dx < scale; dx++)
				{
					const int ox = x + sx * scale + dx, oy = ycentre - (h * scale) / 2 + sy * scale + dy;
					if (ox < 0 || oy < 0 || ox >= VKQ_HUD_W || oy >= VKQ_HUD_H)
						continue;
					((unsigned *)px)[oy * VKQ_HUD_W + ox] = c;
				}
		}
	return x + w * scale;
}

// Fallback block, reached only when a data set has no such lump at all. It keeps
// the ammo-type colour, so the readout degrades to R4's behaviour rather than to
// a number with nothing beside it.
static int vkq_hud_block (unsigned char *px, int x, int ycentre, int scale, unsigned rgba)
{
	int sx, sy;
	for (sy = -3 * scale; sy < 3 * scale; sy++)
		for (sx = 0; sx < 5 * scale; sx++)
		{
			const int ox = x + sx, oy = ycentre + sy;
			if (ox < 0 || oy < 0 || ox >= VKQ_HUD_W || oy >= VKQ_HUD_H)
				continue;
			((unsigned *)px)[oy * VKQ_HUD_W + ox] = rgba;
		}
	return x + 5 * scale;
}

// Returns false when the HUD should not be drawn at all.
static bool vkq_hud_build (id<MTLDevice> dev)
{
	extern int	VKQ_VR_HudValues (int *health, int *armour, int *ammo0, int *type0, int *ammo1, int *type1);
	extern void VKQ_VR_HudIcons (char *health, char *armour, char *ammo0, char *ammo1, int len);
	static unsigned char px[VKQ_HUD_W * VKQ_HUD_H * 4];
	static int			 lastKey = -1;
	char				 nHealth[32] = {0}, nArmour[32] = {0}, nAmmo0[32] = {0}, nAmmo1[32] = {0};
	int					 health = 0, armour = 0, a0 = -1, a1 = -1, t0 = -1, t1 = -1, key, x, bx, wide;
	// Icon 24x24 at 2x and digits at 8x reproduce Quake's own status-bar
	// proportions (the ammo box and the number are close to the same height
	// there) and keep the digit's apparent size at R4's.
	const int			 y = VKQ_HUD_H / 2, scale = 8, icon = 2;
	const int			 grpGap = 22, digitAdv = (3 + 1) * scale;
	// Ammo colours track the ammo TYPE on the NUMERALS, so a glance says which
	// gun is nearly dry in dual wield without reading the number. The sbar icons
	// keep their own art colours, which are already the ones a Quake player
	// associates with each box.
	static const unsigned kAmmoColour[4] = {0xFF4FC8FFu, 0xFF6FE86Fu, 0xFF5C5CFFu, 0xFFFFC46Fu}; // shells nails rockets cells
	const unsigned		  kHealth = 0xFFE8E8F0u, kArmour = 0xFFC8D8FFu;

	if (!VKQ_VR_HudValues (&health, &armour, &a0, &t0, &a1, &t1))
		return false;
	VKQ_VR_HudIcons (nHealth, nArmour, nAmmo0, nAmmo1, 32);
	// Say ONCE, pinned, which sbar lumps this data set actually resolved. A HUD
	// that silently fell back to coloured blocks because a mod renamed its pics
	// would look like a design choice; this makes it a fact in the file.
	{
		static BOOL logged = NO;
		if (!logged && nHealth[0])
		{
			unsigned probe[VKQ_HUD_ICON_MAX * VKQ_HUD_ICON_MAX];
			int		 hw = 0, hh = 0, aw = 0, ah = 0;
			extern int VKQ_VR_HudIcon (const char *name, unsigned *out, int maxw, int maxh, int *ow, int *oh);
			logged = YES;
			VKQ_VR_HudIcon (nHealth, probe, VKQ_HUD_ICON_MAX, VKQ_HUD_ICON_MAX, &hw, &hh);
			VKQ_VR_HudIcon (nAmmo0[0] ? nAmmo0 : "sb_shells", probe, VKQ_HUD_ICON_MAX, VKQ_HUD_ICON_MAX, &aw, &ah);
			vkq_vr_diag_pin (@"HUD ICONS from the engine's own gfx.wad: health '%s' %dx%d, ammo '%s' %dx%d (0x0 = lump missing, coloured block instead)",
							 nHealth, hw, hh, nAmmo0[0] ? nAmmo0 : "sb_shells", aw, ah);
			VKQ_VR_WriteDiagnostics ();
		}
	}
	// The face is chosen by the health band, and the armour plate by which armour
	// is worn, so both are already covered by the health/armour terms below.
	key = health * 1000003 + armour * 10007 + (a0 + 2) * 101 + (a1 + 2) * 7 + (t0 + 2) * 3 + (t1 + 2);
	if (vkq_vrHudTex && key == lastKey)
		return true;
	lastKey = key;

	memset (px, 0, sizeof (px));
	// CENTRED. The readout is one group shorter in Convenience than in dual
	// wield and loses the armour group whenever the player has none, so a
	// left-aligned layout would slide sideways under the player as they play.
	// Width first, then a start x — the digit count is known before anything is
	// drawn, so this costs one arithmetic pass and nothing at all at draw time.
	{
		const int hg = 24 * icon + 10 + vkq_hud_digits (health < 0 ? 0 : health) * digitAdv;
		wide = hg;
		if (armour > 0)
			wide += grpGap + 24 * icon + 10 + vkq_hud_digits (armour) * digitAdv;
		if (t0 >= 0 && t0 < 4)
			wide += grpGap + 24 * icon + 10 + vkq_hud_digits (a0 < 0 ? 0 : a0) * digitAdv;
		if (t1 >= 0 && t1 < 4)
			wide += grpGap + 24 * icon + 10 + vkq_hud_digits (a1 < 0 ? 0 : a1) * digitAdv;
		x = (VKQ_HUD_W - wide) / 2;
		if (x < 4)
			x = 4;
	}
	x = vkq_hud_icon (px, x, y, nHealth, icon);
	x += 10;
	x = vkq_hud_number (px, x, y - 2 * scale, health < 0 ? 0 : health, scale, kHealth);
	if (armour > 0)
	{
		x += grpGap;
		x = vkq_hud_icon (px, x, y, nArmour, icon);
		x += 10;
		x = vkq_hud_number (px, x, y - 2 * scale, armour, scale, kArmour);
	}
	if (t0 >= 0 && t0 < 4)
	{
		x += grpGap;
		bx = x;
		x = vkq_hud_icon (px, x, y, nAmmo0, icon);
		if (x == bx)
			x = vkq_hud_block (px, x, y, scale, kAmmoColour[t0]);
		x += 10;
		x = vkq_hud_number (px, x, y - 2 * scale, a0 < 0 ? 0 : a0, scale, kAmmoColour[t0]);
	}
	if (t1 >= 0 && t1 < 4)
	{
		x += grpGap;
		bx = x;
		x = vkq_hud_icon (px, x, y, nAmmo1, icon);
		if (x == bx)
			x = vkq_hud_block (px, x, y, scale, kAmmoColour[t1]);
		x += 10;
		x = vkq_hud_number (px, x, y - 2 * scale, a1 < 0 ? 0 : a1, scale, kAmmoColour[t1]);
	}

	if (!vkq_vrHudTex)
	{
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
																					 width:VKQ_HUD_W
																					height:VKQ_HUD_H
																				 mipmapped:NO];
		td.usage = MTLTextureUsageShaderRead;
		td.storageMode = MTLStorageModeShared;
		vkq_vrHudTex = [dev newTextureWithDescriptor:td];
		if (!vkq_vrHudTex)
			return false;
	}
	[vkq_vrHudTex replaceRegion:MTLRegionMake2D (0, 0, VKQ_HUD_W, VKQ_HUD_H) mipmapLevel:0 withBytes:px bytesPerRow:VKQ_HUD_W * 4];
	return true;
}

// Head-locked: the FULL device transform, pitch and roll included, so it stays
// exactly where it is on your face. 1.75 m is the convergence distance; the
// quad's size is chosen at that distance, so the HUD is constant angular size
// whatever else changes.
//
// R5 item 5 — SPACING, in the user's own terms: UP a little higher than the
// current UP, DOWN a little lower than the current DOWN. R4 shipped +0.32 and
// -0.50 m at 1.75 m (about +10.4 and -16.0 degrees); these are +0.46 and -0.66
// (+14.7 and -20.7), which moves each further from the centre of vision without
// leaving the comfortable field. The quad is wider to match the wider texture,
// so each glyph keeps its angular size rather than shrinking to fit.
static simd_float4x4 vkq_vr_hud_anchor (simd_float4x4 originFromDevice, int position)
{
	const float	  dist = 1.75f;
	const float	  yOff = (position == 1) ? -0.66f : 0.46f; // Low : High
	simd_float4x4 t = matrix_identity_float4x4;
	simd_float4x4 sc = matrix_identity_float4x4;
	t.columns[3] = simd_make_float4 (0.0f, yOff, -dist, 1.0f);
	// Half-width chosen so the texture's pixels-per-degree match what R4 shipped
	// (320 px across 19.4 deg): 720 px across ~30 deg is the same density, so a
	// digit is the same apparent size and the extra width is extra CONTENT, not
	// smaller content.
	sc.columns[0].x = 0.47f; // half-width, metres -> ~30 deg wide at 1.75 m
	sc.columns[1].y = 0.47f * ((float)VKQ_HUD_H / (float)VKQ_HUD_W);
	return simd_mul (originFromDevice, simd_mul (t, sc));
}

// ---------------------------------------------------------------------------
// R6.1 item 2 — THE MESSAGE PANEL: what the game says to you, where you can read
// it.
//
// the user, on 1.0.7.9: "when you get a message from the game (like if you try to
// open a door, and it'll say this is opened elsewhere) - hear the message sound,
// but can't read it. can you show that in VR?"
//
// The cause was charter A9 doing its job. A VR world frame suppresses the ENTIRE
// engine 2D composite (SCR_DrawGUI's vkq_vr_suppress_2d early return), because a
// flat layer lands at the near plane in both eyes — the depth rivalry that kept
// the weapon wheel out of R3 and that the head-locked HUD exists to avoid. Every
// text overlay went with it: centerprints AND the console notify lines. The sound
// is a server event, so it survived, which is exactly why the symptom read as
// "there is a message I cannot see" rather than "nothing happened".
//
// THE CLASS, NOT THE SYMPTOM. Two engine feeds, one panel:
//   - centerprints (VKQ_VR_CenterPrintText, gl_screen.c) — locked doors, secrets,
//     trigger messages. the user's example.
//   - console notify (VKQ_VR_NotifyText, console.c) — "You got the Rocket
//     Launcher", key pickups, death messages. Statistically the ones a player
//     reads most, and invisible for the same reason.
// They cannot collide: Con_LogCenterPrint calls Con_ClearNotify after echoing a
// centerprint, so the notify window is empty for exactly the text the other feed
// is already showing.
//
// The mechanism is R4's HUD quad, reused whole: a shell-rasterised RGBA texture on
// a head-locked quad at 1.75 m, one honest depth, both eyes converging on it, real
// depth written so the compositor reprojects it. What is new is the FONT — the
// HUD's 3x5 digits cannot spell — so the engine hands over its own conchars atlas
// (VKQ_VR_Conchars), which means a mod with replacement conchars supplies the
// glyph shapes here too, exactly as R5's sbar icons do for the HUD.
// ---------------------------------------------------------------------------
// R6.2 item 1 — COARSER INK, and why the numbers moved.
//
// the user on 1.0.7.10: the message text is "SLIGHTLY duplicated with one layer
// being slightly offset". The HUD, drawn through the SAME quad, the same
// pipeline, the same head-locked anchor at the same 1.75 m, is crisp — and the
// simulator renders this panel perfectly. What differs is the width of a stroke:
// the HUD's digits are a 3x5 font at x8, so 8 texture pixels per stroke, while
// these glyphs were an 8x8 conchars cell at x4, so FOUR. On the device those
// four pixels are then resampled through a rasterization rate map (foveation)
// that the simulator does not have and that varies across the panel, and thin
// high-contrast strokes are exactly what that resamples badly.
//
// So the glyph cell goes to x5 and the column count down to 24, which doubles
// the angular size of a stroke without making the panel physically larger, and
// the texture gains mipmaps so no sampling regime can alias it. See
// docs/VR-R6-NOTES.md R6.2 for what this does and does not claim: the artifact
// does not reproduce off-device, so this is the leading hypothesis acted on,
// not a confirmed reproduction.
#define VKQ_MSG_W		 1024
#define VKQ_MSG_H		 448
#define VKQ_MSG_GLYPH	 5					   // conchars are 8x8; x5 = 40 px, strokes 5 px
#define VKQ_MSG_ADV		 (8 * VKQ_MSG_GLYPH)   // 40 px per column
#define VKQ_MSG_COLS	 24					   // 24 x 40 = 960 px, inside 1024 with a margin
#define VKQ_MSG_LINEADV	 52					   // 40 px of glyph + 12 px of air
#define VKQ_MSG_MAXLINES 8					   // 8 x 52 = 416 px, inside 448
#define VKQ_MSG_PADX	 14
#define VKQ_MSG_PADY	 10

// Memory order R,G,B,A — the same convention d_8to24table uses and the same one
// MTLPixelFormatRGBA8Unorm expects from replaceRegion, so no swizzle anywhere.
#define VKQ_RGBA(r, g, b, a) ((unsigned)((r) | ((g) << 8) | ((b) << 16) | ((unsigned)(a) << 24)))

static id<MTLTexture> vkq_vrMsgTex;
static unsigned		  vkq_msgAtlas[128 * 128];
static int			  vkq_msgAtlasState; // 0 untried, 1 loaded, -1 unavailable
static char			  vkq_msgLast[2048];
static int			  vkq_msgLines, vkq_msgCols, vkq_msgGlyphs;

// Re-read per VR session: the game directory can change between sessions (a mod
// with its own conchars), and a cached atlas from the previous game would be that
// mod's font problem forever.
static void vkq_msg_reset (void)
{
	vkq_msgAtlasState = 0;
	vkq_msgLast[0] = 0;
	vkq_msgLines = vkq_msgCols = vkq_msgGlyphs = 0;
}

static const unsigned *vkq_msg_font (void)
{
	extern int VKQ_VR_Conchars (unsigned *out, int maxw, int maxh, int *ow, int *oh);
	if (vkq_msgAtlasState == 0)
	{
		int w = 0, h = 0;
		vkq_msgAtlasState = VKQ_VR_Conchars (vkq_msgAtlas, 128, 128, &w, &h) ? 1 : -1;
		// Pinned, once: a message panel that silently draws nothing because the
		// WAD had no conchars would look identical to a message panel that is
		// never asked to draw. Say which it is, in the file the headset can read.
		vkq_vr_diag_pin (@"MSG FONT conchars %s (%dx%d) — the engine's own font, so a mod's replacement conchars draws the VR messages too",
						 vkq_msgAtlasState == 1 ? "loaded" : "MISSING: messages cannot be drawn", w, h);
	}
	return vkq_msgAtlasState == 1 ? vkq_msgAtlas : NULL;
}

// One glyph, nearest-neighbour, using the atlas purely as a COVERAGE MASK and the
// caller's colour for the ink.
//
// Deliberate, and it is a trade worth naming: taking the atlas's own colours would
// preserve a mod's coloured font, but it would also let a data set decide how
// legible its messages are against a dark plate in a headset. One known
// high-contrast ink — white for the game's own centerprints, gold for the notify
// feed, the two colours Quake itself uses for them — is the readable choice, and
// the glyph SHAPES still come from whatever conchars the game shipped.
static void vkq_msg_glyph (unsigned char *px, int gx, int gy, unsigned char ch, const unsigned *atlas, unsigned rgba)
{
	const int sx0 = (ch & 15) * 8, sy0 = (ch >> 4) * 8;
	int		  sx, sy, dx, dy;
	for (sy = 0; sy < 8; sy++)
		for (sx = 0; sx < 8; sx++)
		{
			if ((atlas[(sy0 + sy) * 128 + sx0 + sx] >> 24) == 0u)
				continue; // conchars index 0 -> alpha 0 (gl_texmgr.c:600)
			for (dy = 0; dy < VKQ_MSG_GLYPH; dy++)
				for (dx = 0; dx < VKQ_MSG_GLYPH; dx++)
				{
					const int x = gx + sx * VKQ_MSG_GLYPH + dx, y = gy + sy * VKQ_MSG_GLYPH + dy;
					if (x < 0 || y < 0 || x >= VKQ_MSG_W || y >= VKQ_MSG_H)
						continue;
					((unsigned *)px)[y * VKQ_MSG_W + x] = rgba;
				}
		}
}

typedef struct
{
	char	 text[VKQ_MSG_COLS + 1];
	int		 len;
	unsigned rgba;
} vkq_msg_line_t;

// Word wrap at VKQ_MSG_COLS, honouring the source's own newlines. A word longer
// than a line is hard-split rather than dropped — Quake's own centerprints are
// written for a 40-column canvas and a few of them run long here.
static int vkq_msg_wrap (const char *src, unsigned rgba, vkq_msg_line_t *out, int have, int max)
{
	int n = have;
	while (*src && n < max)
	{
		const char *lineEnd = src;
		const char *brk = NULL;
		int			c = 0;
		while (*lineEnd && *lineEnd != '\n' && c < VKQ_MSG_COLS)
		{
			if ((*lineEnd & 0x7F) == ' ')
				brk = lineEnd;
			lineEnd++;
			c++;
		}
		// Only break on a space when the line actually overflowed; a line that
		// ended naturally must not lose its last word to the wrap.
		if (*lineEnd && *lineEnd != '\n' && (*lineEnd & 0x7F) != ' ' && brk && brk > src)
			lineEnd = brk;
		{
			int len = (int)(lineEnd - src);
			if (len > VKQ_MSG_COLS)
				len = VKQ_MSG_COLS;
			memcpy (out[n].text, src, (size_t)len);
			out[n].text[len] = 0;
			out[n].len = len;
			out[n].rgba = rgba;
			if (len > 0 || *src == '\n')
				n++;
		}
		src = lineEnd;
		while ((*src & 0x7F) == ' ' && *src)
			src++;
		if (*src == '\n')
			src++;
	}
	return n;
}

// Returns false when there is nothing to show, which is the common case and must
// cost nothing: no texture upload, no rasterisation, no draw call.
static bool vkq_msg_build (id<MTLDevice> dev)
{
	extern int			 VKQ_VR_CenterPrintText (char *out, int len);
	extern int			 VKQ_VR_NotifyText (char *out, int len);
	static unsigned char px[VKQ_MSG_W * VKQ_MSG_H * 4];
	vkq_msg_line_t		 lines[VKQ_MSG_MAXLINES];
	char				 centre[1024], notify[1024], key[2048];
	const unsigned		 kInk = VKQ_RGBA (255, 255, 255, 255); // centerprints: Quake's own white
	const unsigned		 kNotifyInk = VKQ_RGBA (255, 202, 96, 255); // the notify feed, warm, clearly a second voice
	const unsigned		 kPlate = VKQ_RGBA (6, 6, 10, 168);
	const unsigned		 kEdge = VKQ_RGBA (120, 120, 132, 190);
	const unsigned	   *atlas = vkq_msg_font ();
	int					 n = 0, i, widest = 0, blockH, y0, glyphs = 0;

	if (!atlas)
		return false;
	if (!VKQ_VR_CenterPrintText (centre, sizeof (centre)))
		centre[0] = 0;
	if (!VKQ_VR_NotifyText (notify, sizeof (notify)))
		notify[0] = 0;
	if (!centre[0] && !notify[0])
	{
		vkq_msgLines = vkq_msgCols = vkq_msgGlyphs = 0;
		vkq_msgLast[0] = 0;
		return false;
	}
	if (centre[0])
		n = vkq_msg_wrap (centre, kInk, lines, n, VKQ_MSG_MAXLINES);
	if (notify[0])
		n = vkq_msg_wrap (notify, kNotifyInk, lines, n, VKQ_MSG_MAXLINES);
	if (n <= 0)
		return false;

	// Rebuild only when the text changes. Quake repeats a centerprint every frame
	// for its whole lifetime, and rasterising 1 MB of RGBA at 90 Hz to produce the
	// identical picture is the kind of cost that never shows up as a bug, only as
	// a frame-time percentile.
	snprintf (key, sizeof (key), "%s\x1f%s", centre, notify);
	if (vkq_vrMsgTex && !strcmp (key, vkq_msgLast))
		return true;
	snprintf (vkq_msgLast, sizeof (vkq_msgLast), "%s", key);

	memset (px, 0, sizeof (px));
	for (i = 0; i < n; i++)
		if (lines[i].len > widest)
			widest = lines[i].len;
	blockH = n * VKQ_MSG_LINEADV - (VKQ_MSG_LINEADV - 8 * VKQ_MSG_GLYPH);
	// Vertically centred in the texture, so the panel's apparent position is the
	// same whether the game said one line or six — a readout that jumps up the
	// field of view as it gets longer reads as two different UIs.
	y0 = (VKQ_MSG_H - blockH) / 2;

	// The plate. It is not decoration: white text over e1m1's bright slime or a
	// lava room is unreadable, and this is a message you get one chance to read.
	{
		const int pw = widest * VKQ_MSG_ADV + 2 * VKQ_MSG_PADX;
		const int ph = blockH + 2 * VKQ_MSG_PADY;
		const int pxx = (VKQ_MSG_W - pw) / 2, pyy = y0 - VKQ_MSG_PADY;
		int		  x, y;
		for (y = pyy; y < pyy + ph; y++)
			for (x = pxx; x < pxx + pw; x++)
			{
				if (x < 0 || y < 0 || x >= VKQ_MSG_W || y >= VKQ_MSG_H)
					continue;
				((unsigned *)px)[y * VKQ_MSG_W + x] =
					(y == pyy || y == pyy + ph - 1 || x == pxx || x == pxx + pw - 1) ? kEdge : kPlate;
			}
	}

	for (i = 0; i < n; i++)
	{
		const int lx = (VKQ_MSG_W - lines[i].len * VKQ_MSG_ADV) / 2;
		int		  j;
		for (j = 0; j < lines[i].len; j++)
		{
			const unsigned char ch = (unsigned char)lines[i].text[j];
			if ((ch & 0x7F) == ' ')
				continue;
			vkq_msg_glyph (px, lx + j * VKQ_MSG_ADV, y0 + i * VKQ_MSG_LINEADV, ch, atlas, lines[i].rgba);
			glyphs++;
		}
	}
	vkq_msgLines = n;
	vkq_msgCols = widest;
	vkq_msgGlyphs = glyphs;
	// R6.2 item 1 — the numbers the "thin strokes resample badly" hypothesis
	// rests on, in the file, once. A device round that still sees doubling can
	// then be compared against a build whose stroke is a known angular size
	// instead of against a memory of one.
	{
		static BOOL geomLogged = NO;
		if (!geomLogged)
		{
			const float halfW = 0.55f, dist = 1.75f;
			const float degWide = 2.0f * atanf (halfW / dist) * 180.0f / (float)M_PI;
			geomLogged = YES;
			vkq_vr_diag_pin (@"MSGGEOM tex=%dx%d glyph=%dpx stroke=%dpx cols=%d | quad %.1f deg wide -> %.1f tex-px/deg, "
							  @"glyph %.2f deg, stroke %.3f deg (HUD digit stroke is 8 px at 24.0 tex-px/deg = 0.333 deg)",
							 VKQ_MSG_W, VKQ_MSG_H, VKQ_MSG_ADV, VKQ_MSG_GLYPH, VKQ_MSG_COLS, degWide, VKQ_MSG_W / degWide,
							 VKQ_MSG_ADV / (VKQ_MSG_W / degWide), VKQ_MSG_GLYPH / (VKQ_MSG_W / degWide));
		}
	}
	// One line per distinct message, in the file the user can read in the headset.
	// It is also the harness's non-pixel assertion: "the panel was asked to draw
	// N glyphs" and "N glyphs are on the display" are different claims and this
	// round ships both, because R5 proved the first one alone can be true while
	// the player sees nothing.
	{
		char l[512], c1[128], n1[128];
		int	 k;
		// NEWLINES OUT. Both feeds are multi-line by nature and the diagnostics
		// file is line-oriented: the first probe run wrote a MSGNOW carrying raw
		// '\n', and the harness's `grep -E '^MOVENOW '` then matched a
		// CONTINUATION of that entry and read a stale value as a fresh one. That
		// is precisely the class of failure zone_assert's freshness rule exists to
		// catch, reintroduced one level below it.
		snprintf (c1, sizeof (c1), "%s", centre);
		snprintf (n1, sizeof (n1), "%s", notify);
		for (k = 0; c1[k]; k++)
			if (c1[k] == '\n' || c1[k] == '\r')
				c1[k] = '|';
		for (k = 0; n1[k]; k++)
			if (n1[k] == '\n' || n1[k] == '\r')
				n1[k] = '|';
		snprintf (l, sizeof (l), "MSGNOW lines=%d cols=%d glyphs=%d centre='%s' notify='%s'", n, widest, glyphs, c1, n1);
		VKQ_VR_DiagRoll (l);
	}

	if (!vkq_vrMsgTex)
	{
		// NOT mipmapped, and that is a decision rather than an omission. A mip
		// chain is the textbook answer to the resampling this round is chasing,
		// but declaring one obliges us to FILL it, and the only place to do that
		// is a blit encoder — which cannot be opened while this frame's render
		// encoder is live, because the panel is built inside the per-view pass.
		// A declared-but-unfilled chain samples garbage at the very distances it
		// was added to protect. Coarser strokes fix the same problem with no
		// synchronisation at all; if a device round shows this is still not
		// enough, the correct next step is to move the build above the encoder
		// and generate the chain properly, not to bolt one on here.
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
																					  width:VKQ_MSG_W
																					 height:VKQ_MSG_H
																				  mipmapped:NO];
		td.usage = MTLTextureUsageShaderRead;
		td.storageMode = MTLStorageModeShared;
		vkq_vrMsgTex = [dev newTextureWithDescriptor:td];
		if (!vkq_vrMsgTex)
			return false;
	}
	[vkq_vrMsgTex replaceRegion:MTLRegionMake2D (0, 0, VKQ_MSG_W, VKQ_MSG_H) mipmapLevel:0 withBytes:px bytesPerRow:VKQ_MSG_W * 4];
	return true;
}

// Head-locked at the SAME 1.75 m as the HUD, so the two surfaces share one
// convergence distance and the eyes never have to re-focus between them.
//
// +0.18 m up (about +5.9 deg) reproduces where Quake puts a centerprint on a flat
// screen (y = 0.35 x 200 of a 320x200 canvas — above centre, clear of the
// crosshair). The half-width is 0.55 m, which at 1.75 m is 34.5 deg across 1024
// px: a 32 px glyph subtends ~1.08 deg, comfortably above the ~0.8 deg where VR
// text starts costing you. The panel's top edge lands at +0.386 m and the HIGH
// HUD's bottom edge at +0.397 m, so the two never overlap in either HUD position.
static simd_float4x4 vkq_vr_msg_anchor (simd_float4x4 originFromDevice)
{
	const float	  dist = 1.75f;
	simd_float4x4 t = matrix_identity_float4x4;
	simd_float4x4 sc = matrix_identity_float4x4;
	t.columns[3] = simd_make_float4 (0.0f, 0.18f, -dist, 1.0f);
	sc.columns[0].x = 0.55f;
	sc.columns[1].y = 0.55f * ((float)VKQ_MSG_H / (float)VKQ_MSG_W);
	return simd_mul (originFromDevice, simd_mul (t, sc));
}

// Panel placement, identical in spirit to VKQImmersive's: a world-locked plane in
// front of the head, facing it, no roll.
static simd_float4x4 vkq_vr_panel_anchor (simd_float4x4 originFromDevice, float dist, float height)
{
	simd_float3 headPos = originFromDevice.columns[3].xyz;
	simd_float3 fwd = -originFromDevice.columns[2].xyz;
	fwd.y = 0.0f;
	float len = simd_length (fwd);
	fwd = (len < 1e-4f) ? simd_make_float3 (0, 0, -1) : fwd / len;
	simd_float3 pos = headPos + fwd * dist;
	pos.y += height;
	simd_float3	  normal = simd_normalize (headPos - pos);
	simd_float3	  up = simd_make_float3 (0, 1, 0);
	simd_float3	  right = simd_normalize (simd_cross (up, normal));
	up = simd_cross (normal, right);
	simd_float4x4 m;
	m.columns[0] = simd_make_float4 (right, 0.0f);
	m.columns[1] = simd_make_float4 (up, 0.0f);
	m.columns[2] = simd_make_float4 (normal, 0.0f);
	m.columns[3] = simd_make_float4 (pos, 1.0f);
	return m;
}

static simd_float4x4 vkq_vr_scale3 (float x, float y, float z)
{
	simd_float4x4 m = matrix_identity_float4x4;
	m.columns[0].x = x, m.columns[1].y = y, m.columns[2].z = z;
	return m;
}

// ---------------------------------------------------------------------------

void VKQ_VR_Run (cp_layer_renderer_t layer_renderer)
{
	vkq_vrStop = 0;
	vkq_vrRunning = 1;
	vkq_vrFrameCount = 0;
	vkq_vrContractPrev = nil;
	vkq_vrHaveAlign = false;
	vkq_vrRecenterReq = 1;
	vkq_vrIpdLogged = false;
	vkq_vrDepthLogged = false;
	vkq_vrHandMaskLogged = -1;
	int notifyEnded = 0;
	// Idempotent; usually already running (the SDL filter reaches it at engine
	// boot). Called again here so a VR session always has the observers up even
	// if no controller has ever connected.
	VKQ_Sense_Start ();

	VKQ_VR_HolsterReset (); // R3: no grip or stow state ever survives a session
	vkq_msg_reset ();		// R6.1: re-read conchars — the game dir may have changed
	VKQ_VR_SetWorldScale (vkq_vrWorldScale);

	id<MTLCommandQueue> queue = nil;
	id<MTLTexture>		eyeCopy[2] = {nil, nil};
	bool				resizeRequested = false;
	// R2.1 fix 7 — the render-quality slider is LIVE now. R2 latched
	// `resizeRequested` on the first frame and never cleared it, so dragging the
	// slider changed a float nothing ever read again: the user's device log has
	// exactly ONE `EYE TARGET` line, at x1.00, for a whole session. The scale the
	// eye target was last built for is tracked here, and a change re-runs the
	// same sizing path — debounced, because a drag produces sixty of them a
	// second and each one is a render-target restart.
	float  appliedScale = 0.0f;
	double scaleChangedAt = 0.0;
	float  pendingScale = 0.0f;
	bool				panelAnchored = false;
	int					pendingGeomPin = 0; // R5: pin XHAIR/HOLGEOM this many frames into world mode
	int					lastPresentMode = -1;
	int					loggedPresentMode = -1; // R1.1: what the diagnostics file last reported
	simd_float4x4		panelHead = matrix_identity_float4x4;
	// The anchor the CURRENTLY BLITTED image pair was rendered with. On a
	// rendezvous miss we present THIS one rather than the fresh anchor: the
	// compositor reprojects a matched (pose, image) pair cleanly, and cannot
	// rescue a mismatched one. This is the whole point of charter A4.
	ar_device_anchor_t lastGoodAnchor = nil;
	int				   statFrames = 0, statWorld = 0, statMisses = 0;
	double			   statT0 = CACurrentMediaTime ();
	// R5 item 6 note: the peak head angular rate over each pacing window, and the
	// state needed to measure it. Measured and reported; deliberately NOT acted on
	// this round (docs/VR-R5-NOTES.md explains what acting on it would look like).
	float			   statHeadPeak = 0.0f;
	simd_float3		   headPrevFwd = simd_make_float3 (0.0f, 0.0f, -1.0f);
	double			   headPrevT = 0.0;
	// R4.1: frames the compositor refused to give us (a NULL timing or a NULL
	// drawable). Both INVALIDATE the frame, both are normal, and both used to be
	// fatal — see the comment at the query below. Counted so a device round can
	// see how often it happens instead of guessing.
	int statDropped = 0, totalDropped = 0;

	ar_world_tracking_configuration_t wtc = ar_world_tracking_configuration_create ();
	ar_world_tracking_provider_t	  wtp = ar_world_tracking_provider_create (wtc);
	ar_session_t					  arSession = ar_session_create ();
	ar_data_providers_t				  providers = ar_data_providers_create_with_data_providers (wtp, NULL);
	ar_session_run (arSession, providers);

	// Arm the engine's VR branch only now that this loop exists to publish poses:
	// armed earlier, every engine frame would wait out the full rendezvous timeout
	// for a pose nobody was producing.
	VKQ_VR_SetActive (1);
	vkq_vr_diag_pin (@"VR loop started (worldscale=%.2f units/m, height offset=%.2f m, render scale %.2fx, hands %s)", vkq_vrWorldScale,
					 vkq_vrHeightOffset, vkq_vrRenderScale, vkq_setting_f ("vrHands", 0.0f) > 0.5f ? "visible" : "hidden");

	int running = 1;
	while (running)
	{
		if (vkq_vrStop)
		{
			vkq_vr_diag_pin (@"stop requested, exiting cleanly (frames=%d)", vkq_vrFrameCount);
			running = 0;
			continue;
		}
		switch (cp_layer_renderer_get_state (layer_renderer))
		{
		case cp_layer_renderer_state_paused:
			/*
			 * R6.4 item 4 — THE CROWN, and why this branch is the suspect.
			 *
			 * cp_layer_renderer_wait_until_running blocks until the layer runs
			 * again OR is invalidated. If a Digital Crown press parks the layer in
			 * `paused` and the invalidation never arrives — or arrives only once
			 * something else nudges the compositor — this thread sits here forever.
			 * The loop never exits, VKQ_VR_Ended never runs, and the engine stays in
			 * VR present mode with the window parked behind a curtain: exactly the
			 * "confused, stuck state" the user had to force-quit out of.
			 *
			 * The wait is bounded now. A pause that outlives the grace period is
			 * treated as a dismissal nobody told us about, which is the safe
			 * reading: returning from a real pause costs one re-entry, while not
			 * returning at all costs the app.
			 */
			{
				const double pausedAt = CACurrentMediaTime ();
				cp_layer_renderer_wait_until_running (layer_renderer);
				if (cp_layer_renderer_get_state (layer_renderer) != cp_layer_renderer_state_running && !vkq_vrStop &&
					CACurrentMediaTime () - pausedAt > 2.0)
				{
					vkq_vr_diag_pin (@"LAYER paused for >2 s and did not resume — treating it as a system dismissal "
									  @"(Crown, a system alert, or a space we were not told closed) and running the normal exit");
					notifyEnded = 1;
					running = 0;
				}
			}
			continue;
		case cp_layer_renderer_state_invalidated:
			vkq_vr_diag_pin (@"layer invalidated, exiting loop (frames=%d)", vkq_vrFrameCount);
			notifyEnded = 1;
			running = 0;
			continue;
		case cp_layer_renderer_state_running:
		default:
			break;
		}

		@autoreleasepool
		{
			cp_frame_t frame = cp_layer_renderer_query_next_frame (layer_renderer);
			if (frame == NULL)
				continue;

			// R4.1 — THE CRASH THIS ROUND FIXED. cp_frame_predict_timing() and
			// cp_frame_query_drawable() can both fail, and a failure does not just
			// mean "no picture this frame": it INVALIDATES the frame object. Every
			// later call on that frame is then API misuse, and CompositorServices
			// answers misuse with __BUG_IN_CLIENT__ — an abort, not an error code.
			//
			// The old code called cp_frame_end_submission() on the NULL-drawable
			// path, "balancing" the start_submission above it. That balance is the
			// bug: the frame is already dead, so the tidy-looking cleanup call is
			// exactly the misuse the framework kills the app for, with
			//
			//   cp_frame_end_submission() failed because the frame is not valid.
			//   Are failures from calls to cp_frame_query_drawables() or
			//   cp_frame_predict_timing() properly handled?
			//
			// which is the framework naming this very mistake. It cost the R4
			// simulator round its second half (SIGABRT at VKQVR.m:945, in the crash
			// report by source line), and on a headset it is a hard crash on any
			// dropped frame — a system alert, an immersive-space transition, memory
			// pressure. A failed frame is simply ABANDONED: no end_submission, no
			// cleanup call of any kind, just the next iteration — the only handling
			// that does not touch a dead object. The next query_next_frame gives us
			// a live one; there is nothing to release.
			cp_frame_timing_t timing = cp_frame_predict_timing (frame);
			if (timing == NULL)
			{
				statDropped++, totalDropped++;
				continue;
			}
			cp_frame_start_update (frame);
			cp_frame_end_update (frame);
			cp_time_wait_until (cp_frame_timing_get_optimal_input_time (timing));
			cp_frame_start_submission (frame);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
			cp_drawable_t drawable = cp_frame_query_drawable (frame);
#pragma clang diagnostic pop
			if (drawable == NULL)
			{
				statDropped++, totalDropped++;
				// Say it ONCE per session, loudly. A device round that sees a hitch
				// has to be able to tell "the compositor withheld frames" from "the
				// engine stalled", and before this line the file could not.
				if (totalDropped == 1)
					vkq_vr_diag_pin (@"COMPOSITOR withheld a drawable at frame %d — frame abandoned (NOT ended: ending an invalidated frame is "
									  "the __BUG_IN_CLIENT__ abort R4.1 fixed). Counted in PACING from here on.",
									 vkq_vrFrameCount);
				continue;
			}

			if (queue == nil)
			{
				id<MTLTexture> t0 = cp_drawable_get_color_texture (drawable, 0);
				queue = [t0.device newCommandQueue];
				vkq_vr_build_pipelines (t0.device, t0.pixelFormat, cp_drawable_get_depth_texture (drawable, 0).pixelFormat);
			}

			vkq_vr_dump_contract (layer_renderer, drawable);

			// Device anchor at the frame's PRESENTATION time. frame_timing.h is
			// explicit: trackable-anchor time is for TRACKABLE anchors (hands and
			// accessories — R3's Sense controllers); "for predicting ARKit device
			// anchor use presentation time" (R0 finding 1).
			CFTimeInterval presTime =
				cp_time_to_cf_time_interval (cp_frame_timing_get_presentation_time (cp_drawable_get_frame_timing (drawable)));
			ar_device_anchor_t				anchor = ar_device_anchor_create ();
			ar_device_anchor_query_status_t anchorStatus = ar_world_tracking_provider_query_device_anchor_at_timestamp (wtp, presTime, anchor);
			const bool						tracked = (anchorStatus == ar_device_anchor_query_status_success) || vkq_vrSynthPose;

			size_t views = cp_drawable_get_view_count (drawable);

			// Size the engine's render target from the DRAWABLE — never hardcoded,
			// and (R1.1) from the view's PHYSICAL COLOR TEXTURE, not its viewport.
			//
			// With foveation the two are wildly different: the M5 Vision Pro vends
			// a 2048x1984 texture per eye behind a 5087x4081 LOGICAL viewport (the
			// rate map compresses one into the other). R1 sized the engine from the
			// viewport and so asked Quake for ~21 MP an eye at 90 Hz — 10x the
			// pixels that exist. The compositor blit still rasterizes in the
			// logical viewport with the rate map attached (that is the foveation
			// contract and it does not change); only what the ENGINE renders, and
			// the eye copy, shrink to the memory that is actually there.
			cp_view_texture_map_t tmap0 = cp_view_get_view_texture_map (cp_drawable_get_view (drawable, 0));
			MTLViewport			  vp0 = cp_view_texture_map_get_viewport (tmap0);
			id<MTLTexture>		  ct0 = cp_drawable_get_color_texture (drawable, cp_view_texture_map_get_texture_index (tmap0));
			{
				const float wantScale = (vkq_vrRenderScale >= 1.0f && vkq_vrRenderScale <= 2.0f) ? vkq_vrRenderScale : 1.0f;
				const double nowT = CACurrentMediaTime ();
				// Debounce: note the request, act 0.4 s after the slider stops.
				// A render-target resize tears down and rebuilds the present
				// images, and doing that mid-drag is the two-phase-entry trap
				// sixty times a second.
				if (fabsf (wantScale - pendingScale) > 0.005f)
				{
					pendingScale = wantScale;
					scaleChangedAt = nowT;
				}
				const bool settled = (scaleChangedAt > 0.0) && (nowT - scaleChangedAt > 0.4);
				if (ct0.width > 0 && ct0.height > 0 && (!resizeRequested || (settled && fabsf (pendingScale - appliedScale) > 0.005f)))
				{
					const float rs = pendingScale > 0.0f ? pendingScale : wantScale;
					int			tw = (int)lround (ct0.width * rs), th = (int)lround (ct0.height * rs), cw = 0, ch = 0;
					VKQ_Get3DPresentSize (&cw, &ch);
					resizeRequested = true;
					appliedScale = rs;
					scaleChangedAt = 0.0;
					vkq_vr_diag_pin (@"EYE TARGET %dx%d -> %dx%d (%.2f MP/eye) — the view's PHYSICAL texture %lux%lu x%.2f render scale. "
									  "Its LOGICAL viewport is %.0fx%.0f (%.1f MP): sizing from THAT is what cost R1 its frame rate.",
									 cw, ch, tw, th, tw * (double)th / 1.0e6, (unsigned long)ct0.width, (unsigned long)ct0.height, rs, vp0.width, vp0.height,
									 vp0.width * vp0.height / 1.0e6);
					vkq_vr_set_status (5, [NSString stringWithFormat:@"%dx%d/eye (physical %lux%lu, %.2fx)", tw, th, (unsigned long)ct0.width,
																	 (unsigned long)ct0.height, rs]);
					if (abs (tw - cw) > 16 || abs (th - ch) > 16)
						dispatch_async (dispatch_get_main_queue (), ^{ VKQ_Set3DRenderSize (tw, th); });
				}
			}

			// --- pose -> engine (charter A3/A4) ---------------------------------
			unsigned long long poseId = 0;
			simd_float4x4	   headNow = matrix_identity_float4x4;
			if (tracked && vkq_vrFrameCount > 30 && views > 0)
			{
				simd_float4x4 dReal = ar_device_anchor_get_origin_from_anchor_transform (anchor);
				headNow = vkq_vrSynthPose ? vkq_vr_synth_head () : dReal;

				// R5 item 6 note — head angular rate, from the SAME anchors the
				// frames are rendered against, so "how fast was he turning" is a
				// number rather than an adjective. Peak over the pacing window.
				{
					const simd_float3 fwdNow = -headNow.columns[2].xyz;
					const double	  tNow = CACurrentMediaTime ();
					if (headPrevT > 0.0 && tNow > headPrevT)
					{
						const float dot = simd_clamp (simd_dot (fwdNow, headPrevFwd), -1.0f, 1.0f);
						const float rate = acosf (dot) * (180.0f / (float)M_PI) / (float)(tNow - headPrevT);
						if (rate > statHeadPeak && rate < 2000.0f)
							statHeadPeak = rate;
					}
					headPrevFwd = fwdNow;
					headPrevT = tNow;
				}

				// "Calibrate Height": pin the game's eye point to the player's
				// CURRENT eye height without disturbing where they are standing or
				// facing — i.e. move only the alignment's vertical component. A full
				// recenter would also do this, but it moves the world too, and the
				// two are separate actions in the settings for exactly that reason.
				if (vkq_vrCalibrateReq && vkq_vrHaveAlign)
				{
					vkq_vrCalibrateReq = 0;
					vkq_vrAlign.columns[3].y = headNow.columns[3].y;
					// R6 part C3: an explicit calibration is also the new BASELINE.
					if (vkq_vr_baseline_sane (headNow.columns[3].y))
						vkq_setting_set_f (VKQ_VR_BASELINE_KEY, headNow.columns[3].y);
					vkq_vr_diag_pin (@"height calibrated: eye height pinned at %.3f m (stored as the baseline)", vkq_vrAlign.columns[3].y);
					vkq_vr_set_status (3, [NSString stringWithFormat:@"eye height %.2f m", vkq_vrAlign.columns[3].y]);
					VKQ_VR_WriteDiagnostics ();
				}
				if (vkq_vrRecenterReq || !vkq_vrHaveAlign)
				{
					// Carry the head's current yaw into the BODY yaw so recentring
					// never swings the view (charter A6).
					if (vkq_vrHaveAlign)
					{
						simd_float4x4 rel = simd_mul (simd_inverse (vkq_vrAlign), headNow);
						simd_float3	  f = -rel.columns[2].xyz;
						float		  headYaw = atan2f (-f.x, -f.z) * 180.0f / (float)M_PI;
						VKQ_VR_SetBodyYaw (VKQ_VR_GetBodyYaw () + headYaw);
					}
					vkq_vrAlign = vkq_vr_level (headNow);
					vkq_vrHaveAlign = true;
					vkq_vrRecenterReq = 0;
					VKQ_VR_TorsoSnap (); // R6 B1: the player frame just moved under the torso estimate
					vkq_vr_diag_pin (@"recentred: alignment at (%.2f,%.2f,%.2f) m, body yaw %.1f deg", vkq_vrAlign.columns[3].x, vkq_vrAlign.columns[3].y,
								 vkq_vrAlign.columns[3].z, VKQ_VR_GetBodyYaw ());
				}

				// Head angles relative to the alignment, in QUAKE degrees: ARKit
				// +yaw is left and Quake +yaw is left, so yaw passes straight
				// through; ARKit +pitch is UP and Quake +pitch is DOWN, so pitch
				// is negated. These are the SENT view angles (A6) — the render
				// never uses them, it uses the pose itself.
				simd_float4x4 rel = simd_mul (simd_inverse (vkq_vrAlign), headNow);
				simd_float3	  f = -rel.columns[2].xyz;
				float		  headYaw = atan2f (-f.x, -f.z) * 180.0f / (float)M_PI;
				float		  headPitch = -asinf (fmaxf (-1.0f, fminf (1.0f, f.y))) * 180.0f / (float)M_PI;
				VKQ_VR_SetHeadAngles (headPitch, headYaw);
				// R6 part B1 — the head's position in the PLAYER frame, in units,
				// through the same chain a hand goes through (there is deliberately
				// no second derivation). The holster body frame is anchored to this,
				// so a physical step takes the belt with it.
				{
					simd_float4x4 hp = vkq_vr_player_from_tracking (headNow, vkq_vrAlign, vkq_vrWorldScale);
					VKQ_VR_SetHeadPos (hp.columns[3].x, hp.columns[3].y, hp.columns[3].z);
				}
				VKQ_VR_SetHeightOffset (vkq_vrHeightOffset * vkq_vrWorldScale);
				// R2.1 fix 1 — the engine derives the standing eye height from
				// these two numbers rather than from a constant. The alignment's
				// Y IS the player's real eye height above the tracking floor
				// (1.679 m in the user's device log), and the world scale says what
				// that is worth in Quake units. See VKQ_VR_UpdateEyeRise.
				VKQ_VR_SetWorldScale (vkq_vrWorldScale);
				// R6 part C3 — AUTO-CALIBRATION. With a valid alignment and no stored
				// baseline, this is the player's first VR entry (or the first after a
				// reset): measure them once and keep it. Everything downstream then
				// reads the STORED number rather than the live alignment, so a later
				// recentre — which a player does constantly, often while seated —
				// cannot silently change how tall they are.
				{
					float base = vkq_setting_f (VKQ_VR_BASELINE_KEY, 0.0f);
					if (!vkq_vr_baseline_sane (base) && vkq_vr_baseline_sane (vkq_vrAlign.columns[3].y))
					{
						base = vkq_vrAlign.columns[3].y;
						vkq_setting_set_f (VKQ_VR_BASELINE_KEY, base);
						vkq_vr_diag_pin (@"HEIGHT auto-calibrated on first VR entry: standing eye %.3f m stored as the baseline "
										  "(Height trim reads 0.0 from here)",
										 base);
					}
					if (!vkq_vrBaselineLogged)
					{
						vkq_vrBaselineLogged = true;
						vkq_vr_diag_pin (@"HEIGHT baseline %.3f m, trim %+.3f m (%+.1f in), world scale %.2f u/m", base, vkq_vrHeightOffset,
										 vkq_vrHeightOffset * 39.3701f, vkq_vrWorldScale);
					}
					VKQ_VR_SetStandingEye (vkq_vr_baseline_sane (base) ? base : vkq_vrAlign.columns[3].y);
				}

				const float ws = vkq_vrWorldScale;
				const float nearUnits = 0.1f * ws; // charter A3: 0.1 m near -> ~3.94 units

				float		  efp[2][16], proj[2][16], tang[2][4];
				simd_float4x4 efpM[2];
				simd_float4x4 eyeInPlayer[2];
				simd_float3	  eyeOrigin[2];
				for (int e = 0; e < 2; e++)
				{
					// A mono drawable (the simulator) vends ONE view: both engine
					// eyes then take view 0's transform, so the sim renders a
					// correct mono image and the IPD check reads ~0 unless the
					// synthetic pair is on.
					size_t		  v = (views > 1) ? (size_t)e : 0;
					cp_view_t	  view = cp_drawable_get_view (drawable, v);
					simd_float4x4 deviceFromEye = cp_view_get_transform (view);
					if (vkq_vrSynthEyes && views < 2)
					{
						deviceFromEye = matrix_identity_float4x4;
						deviceFromEye.columns[3].x = (e == 1 ? 0.5f : -0.5f) * vkq_vrSynthIPD;
					}
					simd_float4x4 originFromEye = simd_mul (headNow, deviceFromEye);
					simd_float4x4 m = vkq_vr_eye_from_player (originFromEye, vkq_vrAlign, ws);
					efpM[e] = m;
					memcpy (efp[e], &m, sizeof (efp[e]));
					eyeInPlayer[e] = simd_inverse (m);
					eyeOrigin[e] = originFromEye.columns[3].xyz;

					simd_float4x4 cpProj = matrix_identity_float4x4;
					if (__builtin_available (visionOS 2.0, *))
						cpProj = cp_drawable_compute_projection (drawable, cp_axis_direction_convention_right_up_back, v);
					vkq_vr_engine_projection (proj[e], tang[e], cpProj, nearUnits);
				}

				// Charter A3's non-negotiable check, ONCE, in EYE space. Comparing
				// in the player frame is frame-dependent: with the head yawed 90°
				// a perfectly correct pair reads as a Z offset and cries wolf
				// (R0 finding 2b). Logged to the diagnostics FILE, not just the
				// console — that omission is what cost the R0 headset round.
				if (!vkq_vrIpdLogged)
				{
					vkq_vrIpdLogged = true;
					simd_float3 dM = eyeOrigin[1] - eyeOrigin[0];
					simd_float4 rInL = simd_mul (efpM[0], simd_make_float4 (eyeInPlayer[1].columns[3].xyz, 1.0f));
					const float expect = ((vkq_vrSynthEyes && views < 2) ? vkq_vrSynthIPD : 0.063f) * ws;
					BOOL		mono = (views < 2 && !vkq_vrSynthEyes);
					BOOL		pass = (rInL.x > 0.6f * expect && rInL.x < 1.6f * expect && fabsf (rInL.y) < 0.25f * expect && fabsf (rInL.z) < 0.25f * expect);
					vkq_vr_diag_pin (@"IPD CHECK views=%zu | tracking-space eye delta = (%.5f, %.5f, %.5f) m, |d| = %.5f m", views, dM.x, dM.y, dM.z,
									 simd_length (dM));
					vkq_vr_diag_pin (@"IPD CHECK right eye in LEFT-EYE space = (%.4f, %.4f, %.4f) units (expect ~%.2f, 0, 0)", rInL.x, rInL.y, rInL.z, expect);
					vkq_vr_diag_pin (@"IPD CHECK %@%@", (vkq_vrSynthEyes && views < 2) ? @"SYNTHETIC EYES: " : @"",
								 mono ? @"SIM/MONO — one view, delta is 0 by construction; the device answers this"
									  : (pass ? @"PASS — right eye is +X of left, in-plane"
											  : @"*** OUT OF RANGE — matrix/pose convention slip; CONSULT, do not sign-flip (charter §11) ***"));
					vkq_vr_diag_pin (@"PROJ L m00=%.6f m02=%.6f m11=%.6f m12=%.6f m22=%.6f m23(n)=%.6f m32=%.6f", proj[0][0], proj[0][8], proj[0][5],
									 proj[0][9], proj[0][10], proj[0][14], proj[0][11]);
					vkq_vr_diag_pin (@"WORLD SCALE %.2f units/m -> near plane %.3f units (vkQuake NEARCLIP is 4)", ws, nearUnits);
					vkq_vr_set_status (1, mono ? @"mono sim — device answers this" : (pass ? @"PASS (eye-space)" : @"OUT OF RANGE — consult"));
					// R2.1 fix 1 + R3, pinned once: the standing-height
					// derivation and the holster layout. the user's punch list
					// starts with height, and the device round must be able to
					// check the arithmetic from the file rather than by feel.
					{
						char eye[320], zones[512];
						VKQ_VR_EyeHeightDebugString (eye, (int)sizeof (eye));
						vkq_vr_diag_pin (@"EYE HEIGHT %s", eye);
						vkq_vr_set_status (3, @(eye));
						VKQ_VR_ZoneLayoutString (zones, (int)sizeof (zones));
						vkq_vr_diag_pin (@"ZONES (player frame, x right / y up / z back, from the eye) %s", zones);
					}
					VKQ_VR_WriteDiagnostics ();
				}

				// --- hands (charter A6/A10) --------------------------------
				// Polled HERE, between the head anchor and the publish, so hand
				// and head belong to one instant. The engine latches both with
				// the same frame id, which is what lets the weapon be drawn at
				// the pose the compositor reprojects this frame's eyes against.
				{
					VKQSenseHand hands[2];
					VKQ_Sense_Poll (hands);
					for (int hnd = 0; hnd < 2; hnd++)
					{
						simd_float4x4 hp = vkq_vr_player_from_tracking (hands[hnd].originFromHand, vkq_vrAlign, ws);
						simd_float3	  v = simd_mul (simd_inverse (vkq_vrAlign), simd_make_float4 (hands[hnd].velocity, 0.0f)).xyz * ws;
						float		  xf[12] = {hp.columns[0].x, hp.columns[0].y, hp.columns[0].z, hp.columns[1].x, hp.columns[1].y, hp.columns[1].z,
											hp.columns[2].x, hp.columns[2].y, hp.columns[2].z, hp.columns[3].x, hp.columns[3].y, hp.columns[3].z};
						float		  vel[3] = {v.x, v.y, v.z};
						VKQ_VR_PublishHand (hnd, hands[hnd].posed, hands[hnd].held, xf, vel, hands[hnd].buttons, hands[hnd].trigger, hands[hnd].grip,
											hands[hnd].stickX, hands[hnd].stickY);
					}
					// Say ONCE, in the pinned section, that hands actually
					// arrived — "did the SpatialGamepad declaration work" has to
					// be answerable from the file alone, and a positive is as
					// worth recording as a failure.
					const int mask = (hands[0].posed ? 1 : 0) | (hands[1].posed ? 2 : 0);
					if (mask != vkq_vrHandMaskLogged)
					{
						vkq_vrHandMaskLogged = mask;
						vkq_vr_diag_pin (@"HANDS tracked: %s%s (%s) at frame %d", (mask & 1) ? "L" : "-", (mask & 2) ? "R" : "-",
										 VKQ_Sense_StatusTracking (), vkq_vrFrameCount);
						VKQ_VR_WriteDiagnostics ();
					}
				}

				poseId = VKQ_VR_PublishPose (efp[0], proj[0], tang[0], efp[1], proj[1], tang[1]);
			}

			// --- rendezvous (charter A4) ---------------------------------------
			const int worldMode = VKQ_VR_GetPresentMode ();
			bool	  fresh = false;
			statFrames++;
			if (worldMode && poseId)
			{
				// One compositor period is the budget; the engine renders BOTH eyes
				// inside it. Missing simply re-presents the previous pair.
				fresh = VKQ_VR_WaitRendered (poseId, 14) != 0;
				statWorld++;
				if (!fresh)
					statMisses++;
			}
			if (fresh || !lastGoodAnchor || !worldMode)
			{
				cp_drawable_set_device_anchor (drawable, anchor);
				if (fresh)
					lastGoodAnchor = anchor;
			}
			else
			{
				cp_drawable_set_device_anchor (drawable, lastGoodAnchor);
			}

			// Re-anchor the panel whenever we come BACK to a non-gameplay frame, so
			// the menu opens in front of wherever the player is looking.
			if (worldMode != lastPresentMode)
			{
				if (!worldMode)
					panelAnchored = false;
				lastPresentMode = worldMode;
			}

			// R1.1 — say WHY, once per transition, in the pinned section. R1's
			// device file recorded 65 s of `mode=panel` and nothing about the
			// cause, so "the predicate is wrong" and "the predicate was never
			// true" were indistinguishable. One line now settles it either way.
			if (worldMode != loggedPresentMode && VKQ_VR_PresentEvalCount () > 0)
			{
				char dbg[256];
				VKQ_VR_PresentDebugString (dbg, (int)sizeof (dbg));
				vkq_vr_diag_pin (@"MODE %s -> %s (%s) at frame %d | %s", loggedPresentMode < 0 ? "(VR entry)" : (loggedPresentMode ? "world" : "panel"),
								 worldMode ? "world" : "panel", VKQ_VR_PresentReasonString (), vkq_vrFrameCount, dbg);
				loggedPresentMode = worldMode;
				vkq_vr_set_status (
					4, worldMode ? @"world — the game surrounds you"
								 : [NSString stringWithFormat:@"panel — menu screen (%s)", VKQ_VR_PresentReasonString ()]);
				VKQ_VR_WriteDiagnostics ();
				// R5 items 3+4 (brief: "one pinned line per mode entry"). Deferred
				// by ~20 frames because both measurements are produced BY a world
				// pass — asking on the transition frame itself would pin the state
				// from before the first one, which is precisely the class of
				// stale-read mistake R4.1 spent a round on.
				if (worldMode)
					pendingGeomPin = vkq_vrFrameCount + 20;
			}
			if (pendingGeomPin && vkq_vrFrameCount >= pendingGeomPin)
			{
				char xh[448], hg[448];
				pendingGeomPin = 0;
				VKQ_VR_CrosshairDebugString (xh, (int)sizeof (xh));
				VKQ_VR_HolsterGeomString (hg, (int)sizeof (hg));
				vkq_vr_diag_pin (@"XHAIR (world entry, frame %d) %s", vkq_vrFrameCount, xh);
				vkq_vr_diag_pin (@"HOLGEOM (world entry, frame %d) %s", vkq_vrFrameCount, hg);
				vkq_vr_set_status (11, @(xh));
				vkq_vr_set_status (12, @(hg));
				VKQ_VR_WriteDiagnostics ();
			}
			if (!worldMode && !panelAnchored && tracked)
			{
				panelHead = ar_device_anchor_get_origin_from_anchor_transform (anchor);
				panelAnchored = true;
			}

			id<MTLCommandBuffer> cb = [queue commandBuffer];

			// Copy each eye's present image onto THIS queue so the sample below is
			// coherent with the engine's writes (the panel loop's rule).
			id<MTLTexture> monoTex = nil;
			float		   srgbDecode = 0.0f;
			for (int e = 0; e < 2; e++)
			{
				id<MTLTexture> src = (__bridge id<MTLTexture>)VKQ_Get3DPresentMTLTextureForEye (e + 1);
				if (!src)
					continue;
				monoTex = src;
				if (eyeCopy[e] == nil || eyeCopy[e].width != src.width || eyeCopy[e].height != src.height || eyeCopy[e].pixelFormat != src.pixelFormat)
				{
					// Mipmapped: the panel path downsamples this onto its footprint,
					// so a mip chain kills minification shimmer. The VR blit is 1:1
					// and samples mip 0 regardless.
					MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
																								   width:src.width
																								  height:src.height
																							   mipmapped:YES];
					td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
					td.storageMode = MTLStorageModePrivate;
					eyeCopy[e] = [src.device newTextureWithDescriptor:td];
				}
				id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
				[blit copyFromTexture:src toTexture:eyeCopy[e]];
				if (!worldMode && eyeCopy[e].mipmapLevelCount > 1)
					[blit generateMipmapsForTexture:eyeCopy[e]];
				[blit endEncoding];
			}
			if (monoTex)
			{
				MTLPixelFormat sf = monoTex.pixelFormat, df = cp_drawable_get_color_texture (drawable, 0).pixelFormat;
				BOOL		   srcEncoded = (sf == MTLPixelFormatBGRA8Unorm || sf == MTLPixelFormatRGBA8Unorm);
				BOOL		   dstLinear = (df == MTLPixelFormatBGRA8Unorm_sRGB || df == MTLPixelFormatRGBA8Unorm_sRGB || df == MTLPixelFormatRGBA16Float);
				srgbDecode = (srcEncoded && dstLinear) ? 1.0f : 0.0f;
			}

			// Panel geometry (A9): distance/height are the user's 3D-panel
			// settings; the SHAPE comes from the eye texture's own aspect, because
			// in VR the render target is eye-sized (~1:1), not the 16:9-ish panel.
			simd_float4x4 panelModel = matrix_identity_float4x4;
			if (!worldMode)
			{
				float dist = vkq_setting_f ("vp3dDist", 3.6f);
				float halfW = vkq_setting_f ("vp3dHalfW", 2.75f);
				float aspect = (monoTex && monoTex.height > 0) ? ((float)monoTex.width / (float)monoTex.height) : (16.0f / 9.0f);
				float halfH = halfW / (aspect > 0.05f ? aspect : 1.0f);
				simd_float4x4 place = panelAnchored ? vkq_vr_panel_anchor (panelHead, dist, vkq_setting_f ("vp3dHeight", 0.0f))
													: vkq_vr_panel_anchor (matrix_identity_float4x4, dist, 0.0f);
				panelModel = simd_mul (place, vkq_vr_scale3 (halfW, halfH, 1.0f));
			}
			simd_float4x4 originFromDevice = ar_device_anchor_get_origin_from_anchor_transform (anchor);

			for (size_t v = 0; v < views; v++)
			{
				// Layout-agnostic targeting through the view's texture map, with
				// THIS view's own rate map (attaching the wrong eye's map is the
				// right-eye-fisheye trap). Never hardcode texture 0 / slice v.
				cp_view_t			  view = cp_drawable_get_view (drawable, v);
				cp_view_texture_map_t tmap = cp_view_get_view_texture_map (view);
				size_t				  texIdx = cp_view_texture_map_get_texture_index (tmap);
				size_t				  slice = cp_view_texture_map_get_slice_index (tmap);
				MTLViewport			  vp = cp_view_texture_map_get_viewport (tmap);

				MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
				pass.colorAttachments[0].texture = cp_drawable_get_color_texture (drawable, texIdx);
				pass.colorAttachments[0].slice = slice;
				pass.colorAttachments[0].loadAction = MTLLoadActionClear;
				pass.colorAttachments[0].storeAction = MTLStoreActionStore;
				pass.colorAttachments[0].clearColor = MTLClearColorMake (0.0, 0.0, 0.0, 0.0);
				size_t rmCount = cp_drawable_get_rasterization_rate_map_count (drawable);
				if (rmCount > 0)
					pass.rasterizationRateMap = cp_drawable_get_rasterization_rate_map (drawable, texIdx < rmCount ? texIdx : 0);
				id<MTLTexture> depthTex = cp_drawable_get_depth_texture (drawable, texIdx);
				if (depthTex)
				{
					pass.depthAttachment.texture = depthTex;
					pass.depthAttachment.slice = slice;
					pass.depthAttachment.loadAction = MTLLoadActionClear;
					pass.depthAttachment.storeAction = MTLStoreActionStore;
					pass.depthAttachment.clearDepth = 0.0; // reverse-Z: 0 = infinitely far
				}

				id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
				// Foveation contract: rasterize in the view's LOGICAL viewport.
				[enc setViewport:vp];

				id<MTLTexture> tex = (v < 2 && eyeCopy[v]) ? eyeCopy[v] : (eyeCopy[0] ? eyeCopy[0] : monoTex);
				if (worldMode)
				{
					// Charter A5: fullscreen per-view blit with REAL depth.
					id<MTLTexture> depthSrc = (__bridge id<MTLTexture>)VKQ_VR_GetDepthMTLTextureForEye ((v < 2 ? (int)v : 0) + 1);
					if (!vkq_vrDepthLogged && vkq_vrFrameCount > 90)
					{
						vkq_vrDepthLogged = true;
						if (depthSrc)
							vkq_vr_diag_pin (@"DEPTH real per-pixel — engine snapshot %lux%lu fmt=%lu sampled into the drawable "
											  "(reverse-Z, near 0.1 m, no conversion)",
											 (unsigned long)depthSrc.width, (unsigned long)depthSrc.height, (unsigned long)depthSrc.pixelFormat);
						else
							vkq_vr_diag_pin (@"DEPTH constant fallback at 2 m — the engine's per-eye snapshot is not available "
											  "(charter A5 fallback; reprojection quality is reduced, correctness is not)");
						vkq_vr_set_status (6, depthSrc ? @"real per-pixel" : @"constant 2 m (fallback)");
						VKQ_VR_WriteDiagnostics ();
					}
					// R4 part F: Sharpen is a setting, and it is deliberately a
					// WORLD-only one — the panel path already samples a 4K
					// composite 1:1 and would only get ringing out of it.
					// R5 item 6 — Sharpen is a STRENGTH now, 0-100%. Zero skips the CAS
					// tap set entirely (the shader branches on > 0.001), so "off" costs
					// nothing rather than running a no-op pass.
					const float sharpen = fminf (1.0f, fmaxf (0.0f, vkq_setting_f ("vrSharpen", 0.5f)));
					vkq_vr_blit_params_t params = {srgbDecode, kVRFallbackDepth, sharpen, 0.0f};
					id<MTLRenderPipelineState> pipe = (depthSrc && vkq_vrBlitDepthPipe) ? vkq_vrBlitDepthPipe : vkq_vrBlitConstPipe;
					if (tex && pipe)
					{
						[enc setRenderPipelineState:pipe];
						[enc setDepthStencilState:vkq_vrDepthState];
						[enc setFragmentBytes:&params length:sizeof (params) atIndex:0];
						[enc setFragmentTexture:tex atIndex:0];
						if (depthSrc && pipe == vkq_vrBlitDepthPipe)
							[enc setFragmentTexture:depthSrc atIndex:1];
						[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
					}
					// R4 part D — the head-locked HUD, over the world, at 1.75 m.
					// World frames only: menus and panel mode already show the
					// full status bar, so a second one would be noise.
					{
						const int hudPos = (int)lroundf (vkq_setting_f ("vrHud", 1.0f)); // R6 C4: Low
						if (hudPos != 2 && vkq_vrHudPipe && vkq_hud_build (tex.device) && vkq_vrHudTex)
						{
							simd_float4x4 deviceFromEye = cp_view_get_transform (view);
							simd_float4x4 eyeFromOrigin = simd_inverse (simd_mul (originFromDevice, deviceFromEye));
							simd_float4x4 proj = matrix_identity_float4x4;
							if (__builtin_available (visionOS 2.0, *))
								proj = cp_drawable_compute_projection (drawable, cp_axis_direction_convention_right_up_back, v);
							simd_float4x4 mvp = simd_mul (proj, simd_mul (eyeFromOrigin, vkq_vr_hud_anchor (originFromDevice, hudPos)));
							[enc setRenderPipelineState:vkq_vrHudPipe];
							[enc setDepthStencilState:vkq_vrDepthState];
							[enc setVertexBytes:&mvp length:sizeof (mvp) atIndex:0];
							[enc setFragmentTexture:vkq_vrHudTex atIndex:0];
							[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
						}
					}
					// R6.1 item 2 — the message panel, over everything, world
					// frames only. Deliberately NOT gated on the HUD Position
					// setting: "Off" means "I do not want a permanent readout
					// following me", and a transient sentence the game only says
					// once is not that. It is also the only place these messages
					// exist in VR, where the flat build has three.
					{
						if (vkq_vrHudPipe && vkq_msg_build (tex.device) && vkq_vrMsgTex)
						{
							simd_float4x4 deviceFromEye = cp_view_get_transform (view);
							simd_float4x4 eyeFromOrigin = simd_inverse (simd_mul (originFromDevice, deviceFromEye));
							simd_float4x4 proj = matrix_identity_float4x4;
							if (__builtin_available (visionOS 2.0, *))
								proj = cp_drawable_compute_projection (drawable, cp_axis_direction_convention_right_up_back, v);
							simd_float4x4 mvp = simd_mul (proj, simd_mul (eyeFromOrigin, vkq_vr_msg_anchor (originFromDevice)));
							[enc setRenderPipelineState:vkq_vrHudPipe]; // same alpha-blended quad pipeline
							[enc setDepthStencilState:vkq_vrDepthState];
							[enc setVertexBytes:&mvp length:sizeof (mvp) atIndex:0];
							[enc setFragmentTexture:vkq_vrMsgTex atIndex:0];
							[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
						}
					}
				}
				else
				{
					// Charter A9: the flat composite on the world-locked panel. No
					// surroundings dimming here — VR is FULL immersion (the user,
					// 2026-08-10), so there is no passthrough room left to dim; the
					// space behind the panel is already black.
					if (tex && vkq_vrQuadPipe)
					{
						simd_float4x4 deviceFromEye = cp_view_get_transform (view);
						simd_float4x4 eyeFromOrigin = simd_inverse (simd_mul (originFromDevice, deviceFromEye));
						simd_float4x4 proj = matrix_identity_float4x4;
						if (__builtin_available (visionOS 2.0, *))
							proj = cp_drawable_compute_projection (drawable, cp_axis_direction_convention_right_up_back, v);
						simd_float4x4 mvp = simd_mul (proj, simd_mul (eyeFromOrigin, panelModel));
						[enc setRenderPipelineState:vkq_vrQuadPipe];
						[enc setDepthStencilState:vkq_vrDepthState];
						[enc setVertexBytes:&mvp length:sizeof (mvp) atIndex:0];
						[enc setFragmentBytes:&srgbDecode length:sizeof (srgbDecode) atIndex:0];
						[enc setFragmentTexture:tex atIndex:0];
						[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
					}
				}
				[enc endEncoding];
			}

			cp_drawable_encode_present (drawable, cb);
			[cb commit];

			vkq_vrFrameCount++;
			// Pacing + rendezvous health, every ~5 s, straight into the file.
			double now = CACurrentMediaTime ();
			if (now - statT0 >= 5.0)
			{
				int met = 0, eto = 0, sto = 0;
				VKQ_VR_GetStats (&met, &eto, &sto);
				double	  fps = statFrames > 0 ? (double)statFrames / (now - statT0) : 0.0;
				NSString *line = [NSString stringWithFormat:@"%.1f Hz presented, %d/%d rendezvous missed (%.1f%%)", fps, statMisses, statWorld,
															statWorld ? 100.0 * statMisses / statWorld : 0.0];
				vkq_vr_diag (@"PACING %@ | engine timeouts %d, shell timeouts %d, dropped frames %d (%d total), mode=%s (%s), engine frames %d", line, eto,
							 sto, statDropped, totalDropped, worldMode ? "world" : "panel", VKQ_VR_PresentReasonString (), VKQ_Get3DFrames ());
				vkq_vr_set_status (2, line);
				vkq_vr_set_status (
					4, worldMode ? @"world — the game surrounds you" : [NSString stringWithFormat:@"panel — menu screen (%s)", VKQ_VR_PresentReasonString ()]);
				// R2 rows: what enumerated, whether it is trackable, and what the
				// aim is actually doing right now.
				{
					char aim[320], eye[320], hol[320];
					VKQ_VR_AimDebugString (aim, (int)sizeof (aim));
					vkq_vr_diag (@"AIM %s", aim);
					vkq_vr_set_status (7, @(VKQ_Sense_StatusControllers ()));
					vkq_vr_set_status (8, @(VKQ_Sense_StatusTracking ()));
					vkq_vr_set_status (9, [NSString stringWithFormat:@"%@ aim, %d hand(s), movedir %+0.0f deg", VKQ_VR_HandsTracked () ? @"HAND" : @"head",
																	VKQ_VR_HandsTracked (), (double)vkq_vr_movedir_delta]);
					// R2.1 fix 1 / R3: the two things the device round has to be
					// able to read back without a console.
					VKQ_VR_EyeHeightDebugString (eye, (int)sizeof (eye));
					vkq_vr_diag (@"EYE %s", eye);
					vkq_vr_set_status (3, @(eye));
					VKQ_VR_HolsterDebugString (hol, (int)sizeof (hol));
					vkq_vr_diag (@"HOLSTER %s", hol);
					vkq_vr_set_status (10, @(hol));
				}
				// R5 items 3 and 4: the two things this round was dispatched to
				// fix, reported as numbers on every pacing tick rather than
				// inferred from a photograph.
				{
					char xh[448], hg[448];
					VKQ_VR_CrosshairDebugString (xh, (int)sizeof (xh));
					vkq_vr_diag (@"XHAIR %s", xh);
					vkq_vr_set_status (11, @(xh));
					VKQ_VR_HolsterGeomString (hg, (int)sizeof (hg));
					vkq_vr_diag (@"HOLGEOM %s", hg);
					vkq_vr_set_status (12, @(hg));
				}
				// R5 item 6 (documented, not shipped as a behaviour): head angular
				// rate, so the "drop Sharpen during fast head rotation" idea can be
				// argued from a measurement next round instead of from feel. The
				// number is the peak over the last window, in degrees/second, taken
				// from the SAME device anchors the frames were rendered against.
				vkq_vr_diag (@"HEADRATE peak %.0f deg/s over the last %.1fs (R5 note: sharpen-on-motion would gate below this)", statHeadPeak,
							 now - statT0);
				statHeadPeak = 0.0f;
				VKQ_VR_WriteDiagnostics ();
				statFrames = statWorld = statMisses = statDropped = 0;
				statT0 = now;
			}

			cp_frame_end_submission (frame);
		} // @autoreleasepool
	}

	VKQ_VR_SetActive (0);
	eyeCopy[0] = eyeCopy[1] = nil;
	lastGoodAnchor = nil;
	vkq_vr_diag_pin (@"VR loop ended after %d frames", vkq_vrFrameCount);
	VKQ_VR_WriteDiagnosticsNow (); // final, unthrottled — nothing after this writes the file
	if (notifyEnded)
		VKQ_VR_Ended ();
	vkq_vrRunning = 0; // signal the shell LAST, after cleanup
}
