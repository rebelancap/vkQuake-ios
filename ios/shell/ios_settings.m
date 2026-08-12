/*
 * ios_settings.m — NSUserDefaults-backed settings + a native panel.
 * The touch overlay reads values live via vkq_setting_f(); engine-backed
 * settings (menu size, always-run) are pushed through the Cbuf bridge.
 */
#import "ios_settings.h"
#import "ios_audio.h"
#import <objc/runtime.h>

extern void VKQ_TouchCommand (const char *text);
extern void VKQ_TouchSetRun (int on);
extern void VKQ_iOS_SetRefresh (void);
// R6 part C6 — cheats read the local server's own state (host_cmd.c). Available
// on every platform: the Gameplay section is shared, and so are these.
extern int		   VKQ_iOS_CheatsAvailable (void);
extern int		   VKQ_iOS_GodModeActive (void);
extern void		   VKQ_iOS_SetGodMode (int on);
extern const char *VKQ_iOS_LevelName (void);

#define KEYPREFIX @"vkq."

float vkq_setting_f (const char *key, float def)
{
	NSString	   *k = [KEYPREFIX stringByAppendingString:@(key)];
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	if ([d objectForKey:k] == nil)
		return def;
	return [d floatForKey:k];
}

void vkq_setting_set_f (const char *key, float val)
{
	NSString *k = [KEYPREFIX stringByAppendingString:@(key)];
	[NSUserDefaults.standardUserDefaults setFloat:val forKey:k];
}

#ifdef VKQ_VISIONOS
// ---------------------------------------------------------------------------
// R6 part C4 — DEFAULTS, IN ONE PLACE, AND THE MIGRATION THAT MOVES PEOPLE ONTO
// THEM.
//
// Six VR defaults change this round. A default is only a default until somebody
// has a stored value, and every 1.0.7.x install has stored values for all of
// them — so shipping new defaults alone would change nothing for the one person
// who has been testing this. The rule (the user's) is:
//
//   stored value == the OLD default  ->  the user never touched it, move them on
//   stored value == anything else    ->  that is a preference, leave it alone
//
// with one exception: World Scale is FORCE-SET, because its row is gone. A stale
// stored 39.37 would be invisible and unfixable from the sheet, and the whole
// point of C3 is that the height derivation is now correct at 34.
//
// The stamp makes this once-per-install; without it, a user who deliberately
// set Holster Size back to 0.80 would be "migrated" off it on the next launch.
// ---------------------------------------------------------------------------
#define VKQ_VR_DEF_SCALE	  34.0f	  // C3: hardcoded, no row (was 39.37)
#define VKQ_VR_DEF_RENDER	  1.25f	  // C4 (was 1.50)
#define VKQ_VR_DEF_SHARPEN	  0.5f	  // C4: unchanged, asserted
#define VKQ_VR_DEF_HUD		  1.0f	  // C4: Low (was High)
#define VKQ_VR_DEF_STYLE	  1.0f	  // C4: Immersive (was Convenience)
#define VKQ_VR_DEF_HOLSIZE	  0.70f	  // C4 (was 0.80)
#define VKQ_VR_DEF_HOLFWD	  0.0381f // C4: +1.5 inches (was 0)
#define VKQ_VR_DEF_HEIGHT	  0.0f
// R6.1 item 3 — Snap Turn's segment index. 0 = Smooth, 1/2/3 = 30/45/60 deg.
// the user: "smooth turning should be default, not snap." The engine cvar
// vkqvr_snapturn's own default moves with it (overlay 0024).
#define VKQ_VR_DEF_SNAPTURN	  0.0f // was 2 (= 45 deg)
#define VKQ_VR_OLD_SNAPTURN	  2.0f
#define VKQ_VR_MIGRATION_STAMP "vrMig6"
// R6.1 gets its OWN stamp. vrMig6 is already burned on every 1.0.7.9 install —
// including the only one that matters — so re-using it would make this round's
// migration a no-op for exactly the person who asked for it. One stamp per
// round of default changes is the rule from here on.
#define VKQ_VR_MIGRATION_STAMP_61 "vrMig7"

static BOOL vkq_near (float a, float b) { return fabsf (a - b) <= 0.0005f * (1.0f + fabsf (b)); }

// Move one key from its old default to its new one, but only if it is still
// sitting on the old default. Returns what it did, for the log.
static const char *vkq_migrate_default (const char *key, float oldDef, float newDef)
{
	NSString *k = [KEYPREFIX stringByAppendingString:@(key)];
	if ([NSUserDefaults.standardUserDefaults objectForKey:k] == nil)
		return "unset (takes the new default)";
	if (!vkq_near (vkq_setting_f (key, oldDef), oldDef))
		return "user value kept";
	vkq_setting_set_f (key, newDef);
	return "migrated to the new default";
}

void VKQ_iOS_MigrateSettings (void)
{
	static BOOL done = NO;
	if (done)
		return;
	done = YES;

	// R6.1 item 3 — Snap Turn -> Smooth, under its own stamp so it runs on an
	// install that already took the R6 migration. Same rule as every other row:
	// a stored 45 deg is the old DEFAULT and moves; a stored 30 or 60 is a
	// preference and stays.
	if (vkq_setting_f (VKQ_VR_MIGRATION_STAMP_61, 0.0f) <= 0.5f)
	{
		NSLog (@"[vkquake] R6.1 settings migration: vrSnapTurn %s (old default %.0f -> new default %.0f)",
			   vkq_migrate_default ("vrSnapTurn", VKQ_VR_OLD_SNAPTURN, VKQ_VR_DEF_SNAPTURN), VKQ_VR_OLD_SNAPTURN, VKQ_VR_DEF_SNAPTURN);
		vkq_setting_set_f (VKQ_VR_MIGRATION_STAMP_61, 1.0f);
	}

	if (vkq_setting_f (VKQ_VR_MIGRATION_STAMP, 0.0f) > 0.5f)
		return;

	// The forced one. See above: the row is gone, so a stale value is unreachable.
	vkq_setting_set_f ("vrScale", VKQ_VR_DEF_SCALE);
	// Holster zones are part of Immersive now, not an option (C4) — force the
	// stored value on so an install that switched them off in R3 is not left
	// with a mode whose whole gesture set does nothing.
	vkq_setting_set_f ("vrZones", 1.0f);
	// The crosshair DEBUG row is gone (C4). Left on, it would draw a huge magenta
	// plus with no way to turn it off from the sheet.
	vkq_setting_set_f ("vrXhairDebug", 0.0f);

	NSLog (@"[vkquake] R6 settings migration: vrScale forced to %.2f u/m; vrRenderScale %s; vrHud %s; vrStyle %s; vrHolSize %s; vrHolFwd %s",
		   VKQ_VR_DEF_SCALE, vkq_migrate_default ("vrRenderScale", 1.5f, VKQ_VR_DEF_RENDER), vkq_migrate_default ("vrHud", 0.0f, VKQ_VR_DEF_HUD),
		   vkq_migrate_default ("vrStyle", 0.0f, VKQ_VR_DEF_STYLE), vkq_migrate_default ("vrHolSize", 0.80f, VKQ_VR_DEF_HOLSIZE),
		   vkq_migrate_default ("vrHolFwd", 0.0f, VKQ_VR_DEF_HOLFWD));
	vkq_setting_set_f (VKQ_VR_MIGRATION_STAMP, 1.0f);
}
#endif

#ifdef VKQ_VISIONOS
// R6 part C1: the sheet is built against the app's authoritative tri-state mode,
// so it needs the same VKQ_MODE_* the ornament and the curtain label use.
#import "VKQVR.h"
// shell-visionos externs (panel/stereo live-tuning)
extern void VKQ_iOS_Apply3DSettings (void);
extern void VKQ_Recenter3D (void);
extern int	vkq3d_immersive_on; // ios_touch.m — 1 while the 3D panel is up
// VR mode (VKQVR.m / VKQHostViewController.m)
extern float	   vkq_vrWorldScale;
extern float	   vkq_vrHeightOffset;
extern void		   VKQ_VR_Recenter (void);
extern void		   VKQ_VR_CalibrateHeight (void);
extern float	   vkq_vrRenderScale;
extern void		   VKQ_VR_SetShowHands (bool show);
extern void		   VKQ_VR_WriteDiagnosticsNow (void);
// R6 part C3 — forget the stored standing-height baseline, so the next VR entry
// (or the Re-calibrate button) measures the player again.
extern void VKQ_VR_ClearHeightBaseline (void);
extern int		   VKQ_GetMode (void);
extern void		   VKQ_EnterMode (int mode);
// R2 — Sense controllers and the grip calibration (VKQHostViewController.m)
extern void VKQ_iOS_ApplyVRSettings (void);
#endif

/*
 * R6 part C6 — re-assert God Mode across a level change, once.
 *
 * A fresh spawn clears FL_GODMODE, so a switch the player left ON would silently
 * become a lie the moment they took a lift to the next map. This runs from the
 * frame driver, does nothing at all unless the LEVEL NAME has changed, and even
 * then checks the flag first — so loading a save that already has god on does
 * not toggle it back off, and a deliberate console `god` mid-level is never
 * argued with.
 */
void VKQ_iOS_CheatsTick (void)
{
	static char last[64];
	const char *lvl = VKQ_iOS_LevelName ();
	if (!lvl || !*lvl)
		return;
	if (!strncmp (lvl, last, sizeof (last) - 1))
		return; // same level: the player owns the state from here
	snprintf (last, sizeof (last), "%s", lvl);
	if (vkq_setting_f ("cheatGod", 0.0f) > 0.5f && VKQ_iOS_CheatsAvailable () && !VKQ_iOS_GodModeActive ())
	{
		VKQ_iOS_SetGodMode (1);
		NSLog (@"[vkquake] cheats: God Mode re-asserted for '%s' (a fresh spawn clears it)", lvl);
	}
}

void VKQ_iOS_ApplySettingsToEngine (void)
{
#ifdef VKQ_VISIONOS
	// R6 part C4: before anything reads a VR preference. Idempotent and stamped,
	// so this costs one NSUserDefaults read after the first launch.
	VKQ_iOS_MigrateSettings ();
#endif
	// scr_menuscale/sbarscale/etc are auto-computed & read-only in vkQuake's relative-
	// scale mode; the writable knobs are scr_rel*scale (default 1). Set those.
	float m = vkq_setting_f ("menuSize", 1.3f);
	char  buf[192];
	snprintf (buf, sizeof (buf), "scr_relmenuscale %.2f\nscr_relsbarscale %.2f\nscr_relconscale %.2f\nscr_relcrosshairscale %.2f\n", m, m,
			  m, m);
	VKQ_TouchCommand (buf);
	VKQ_TouchSetRun (vkq_setting_f ("alwaysRun", 1.0f) > 0.5f ? 1 : 0);
	// field of view (Hor+; 90 = vanilla). Widescreen phones want a bit more.
	char fovcmd[32];
	snprintf (fovcmd, sizeof (fovcmd), "fov %.0f\n", vkq_setting_f ("fov", 90.0f));
	VKQ_TouchCommand (fovcmd);
	// Brightness is stored 0..1 (dark..bright) and drives the engine's gamma,
	// which runs the other way over the same range its own menu uses: 1.0 is
	// darkest, 0.5 brightest. The engine default (gamma 0.9) is 0.2 here.
	float b = vkq_setting_f ("brightness", 0.2f);
	b = fmaxf (0.0f, fminf (1.0f, b));
	char gammacmd[32];
	snprintf (gammacmd, sizeof (gammacmd), "gamma %.3f\n", 1.0f - 0.5f * b);
	VKQ_TouchCommand (gammacmd);
	VKQ_iOS_SetRefresh ();
	VKQ_iOS_AudioApply (); // session category/options + master gain (Audio section)
	/*
	 * MP-DL1 (overlay 0028): 0 never / 1 ask / 2 always, mirrored into the engine's
	 * cl_mapdownload.
	 *
	 * Pushed ONLY once the player has actually used the row. Every other setting
	 * here is unconditionally authoritative, and it can be, because nothing else
	 * writes menuSize or fov. cl_mapdownload is different: it is a real archived
	 * cvar that a config.cfg, an autoexec.cfg or a console line can set, and this
	 * function runs AFTER quake.rc (VKQ_iOS_SetupUI is called at the end of
	 * Host_Init) — so an unconditional push would silently undo a value the player
	 * had just set by hand, every launch. Absent key means "nobody has expressed a
	 * preference in the UI", and the engine's own default (1 = ask) then stands.
	 */
	if ([NSUserDefaults.standardUserDefaults objectForKey:KEYPREFIX @"mapDownload"] != nil)
	{
		char mdcmd[40];
		snprintf (mdcmd, sizeof (mdcmd), "cl_mapdownload %d\n", (int)lroundf (vkq_setting_f ("mapDownload", 1.0f)));
		VKQ_TouchCommand (mdcmd);
	}
#ifdef VKQ_VISIONOS
	VKQ_iOS_Apply3DSettings (); // includes Surroundings Dimming + panel FPS on entry
	// Engine-drawn FPS belongs to the 3D PANEL only (the UIKit "FPS Counter"
	// label owns the 2D window). Gate on being in 3D so 2D never double-counts,
	// and so a live toggle of "FPS on Panel" while in 3D applies immediately.
	VKQ_TouchCommand ((vkq3d_immersive_on && vkq_setting_f ("vp3dFps", 0.0f) > 0.5f) ? "scr_showfps 1\n" : "scr_showfps 0\n");
#endif
}

// ---------------------------------------------------------------------------
typedef enum
{
	ROW_SLIDER,
	ROW_SWITCH,
	ROW_BUTTON,
	ROW_INFO,	// read-only feedback (panel width / aspect / height)
	ROW_SEG,	// segmented m|ft (units)
	ROW_CHOICE, // one-of-N; taps through to a list with an explanation per option
	ROW_SUBHEAD // R6: a small heading INSIDE a section ("Cheats"), not a row you can touch
} VKQRowType;

// Live readout for a slider row, so you can see what you are sliding TO rather
// than guessing from the knob position. Multipliers read "1.25x", angles carry
// a degree sign, 0..1 amounts read as a percentage.
static NSString *vkq_value_text (NSString *key, float v)
{
	if ([key isEqualToString:@"fov"])
		return [NSString stringWithFormat:@"%.0f°", v];
	if ([key isEqualToString:@"touchOpacity"] || [key isEqualToString:@"brightness"] || [key isEqualToString:@"gameVolume"])
		return [NSString stringWithFormat:@"%.0f%%", v * 100.0f];
	if ([key isEqualToString:@"gyro"]) // 0 disables gyro aim entirely — say so
		return v < 0.05f ? @"Off" : [NSString stringWithFormat:@"%.2f×", v];
	return [NSString stringWithFormat:@"%.2f×", v];
}

#ifdef VKQ_VISIONOS
extern void VKQ_GetWindowSize (int *w, int *h); // engine (points; drawable is 2x)

// Value-label text for the Vision Pro sliders: lengths honor the ft/m toggle
// (storage is always meters / game units), stereo depth reads as a percentage
// of the default separation.
static NSString *vkq_vp3d_value_text (NSString *key, float v)
{
	BOOL ft = vkq_setting_f ("vp3dUnits", 1.0f) > 0.5f; // ft default (matches quake3e)
	if ([key isEqualToString:@"vp3dHeight"]) // relative to eye level — show the sign
		return ft ? [NSString stringWithFormat:@"%+.1f ft", v * 3.28084f] : [NSString stringWithFormat:@"%+.2f m", v];
	if ([key isEqualToString:@"vp3dDist"])
		return ft ? [NSString stringWithFormat:@"%.1f ft", v * 3.28084f] : [NSString stringWithFormat:@"%.1f m", v];
	if ([key isEqualToString:@"vp3dHalfW"] || [key isEqualToString:@"vp3dSizeH"]) // stored half; show full
		return ft ? [NSString stringWithFormat:@"%.1f ft", v * 2.0f * 3.28084f] : [NSString stringWithFormat:@"%.1f m", v * 2.0f];
	if ([key isEqualToString:@"vp3dSep"])
		return [NSString stringWithFormat:@"%.0f%%", v / 2.5f * 100.0f];
	if ([key isEqualToString:@"vp3dDim"])
		return [NSString stringWithFormat:@"%.0f%%", v * 100.0f];
	if ([key isEqualToString:@"vp3dConv"]) // game units ~1 inch each
		return ft ? [NSString stringWithFormat:@"%.0f ft", v * 0.0254f * 3.28084f] : [NSString stringWithFormat:@"%.1f m", v * 0.0254f];
	return vkq_value_text (key, v);
}

// VR sliders read in the units the charter argues in: world scale is Quake units
// per metre (39.37 = 1 unit ≈ 1 inch, the default), height trim is a signed
// real-world offset.
static NSString *vkq_vr_value_text (NSString *key, float v)
{
	BOOL ft = vkq_setting_f ("vp3dUnits", 1.0f) > 0.5f;
	if ([key isEqualToString:@"vrScale"])
		return [NSString stringWithFormat:@"%.1f u/m", v];
	// R6 part C3: Height and Holster Position are ALWAYS in inches. the user speaks
	// inches for both, they are both small signed body measurements, and a
	// centimetre reading of "+3.8 cm" is not a number anyone has an opinion about.
	// (The m/ft toggle still governs the panel distances, which are room-sized.)
	if ([key isEqualToString:@"vrHeight"] || [key isEqualToString:@"vrHolFwd"])
		return [NSString stringWithFormat:@"%+.1f in", v * 39.3701f];
	if ([key isEqualToString:@"vrRenderScale"])
		return v >= 2.495f ? @"2.50x (full)" : [NSString stringWithFormat:@"%.2fx", v];
	if ([key isEqualToString:@"vrGunScale"])
		return [NSString stringWithFormat:@"%.2fx", v];
	if ([key isEqualToString:@"vrTurnSpeed"])
		return [NSString stringWithFormat:@"%.0f°/s", v];
	if ([key isEqualToString:@"vrAimPitch"])
		return fabsf (v) < 0.5f ? @"0°" : [NSString stringWithFormat:@"%+.0f°", v];
	// Grip calibration: degrees turn the model in the fist, units move it. Both
	// read better as raw numbers than as a percentage — they are the values you
	// would type into vkqvrgun.
	if ([key isEqualToString:@"vrGunPitch"] || [key isEqualToString:@"vrGunYaw"] || [key isEqualToString:@"vrGunRoll"])
		return [NSString stringWithFormat:@"%+.0f°", v];
	if ([key isEqualToString:@"vrGunFwd"] || [key isEqualToString:@"vrGunRight"] || [key isEqualToString:@"vrGunUp"])
		return [NSString stringWithFormat:@"%+.1f u", v];
	if ([key isEqualToString:@"vrFlash"] || [key isEqualToString:@"vrSharpen"])
		return v < 0.005f ? @"Off" : [NSString stringWithFormat:@"%.0f%%", v * 100.0f];
	if ([key isEqualToString:@"vrHolSize"])
		return [NSString stringWithFormat:@"%.2fx", v];
	(void)ft;
	return vkq_value_text (key, v);
}
#endif

// One entry point for every slider readout: panel/stereo rows carry real-world
// units, everything else falls through to the shared formatter.
static NSString *vkq_row_value_text (NSString *key, float v)
{
#ifdef VKQ_VISIONOS
	if ([key hasPrefix:@"vp3d"])
		return vkq_vp3d_value_text (key, v);
	if ([key hasPrefix:@"vr"])
		return vkq_vr_value_text (key, v);
#endif
	return vkq_value_text (key, v);
}

@interface VKQRow : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *key;
@property (nonatomic) VKQRowType type;
@property (nonatomic) float mn, mx, def;
// One-of-N segment titles. ROW_SEG used to hard-code "m"/"ft"; VR needs Aim Hand,
// Movement and Snap Turn as the same one-tap control, so the labels come with the
// row instead of being baked into the cell.
@property (nonatomic, copy) NSArray<NSString *> *segs;
@end
@implementation VKQRow
@end

static VKQRow *mkrow (NSString *t, NSString *k, VKQRowType ty, float mn, float mx, float def)
{
	VKQRow *r = [VKQRow new];
	r.title = t;
	r.key = k;
	r.type = ty;
	r.mn = mn;
	r.mx = mx;
	r.def = def;
	return r;
}

#ifdef VKQ_VISIONOS
static VKQRow *mkrowseg (NSString *t, NSString *k, float def, NSArray<NSString *> *segs)
{
	VKQRow *r = mkrow (t, k, ROW_SEG, 0, (float)segs.count - 1, def);
	r.segs = segs;
	return r;
}
#endif

// stash the row's key on its control via an associated object
static char kRowKeyTag;
static void tag_ctl (UIControl *ctl, VKQRow *r) { objc_setAssociatedObject (ctl, &kRowKeyTag, r.key, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
static const char *ctl_key (UIControl *ctl)
{
	NSString *k = objc_getAssociatedObject (ctl, &kRowKeyTag);
	return k.UTF8String;
}

// ---------------------------------------------------------------------------
// MP-DL1 (overlay 0028) — the option list for a ROW_CHOICE, keyed by the row.
//
// ROW_CHOICE used to be hard-wired to the audio mode: both the summary on the
// parent row and the picker itself called VKQ_iOS_AudioModeTitles directly, so a
// second choice row would silently have rendered the audio options. These two
// functions are the whole of the generalisation, and an unknown key returns an
// empty list rather than the audio one — a row that shows nothing is a bug you
// can see, a row that shows the wrong menu's options is one you cannot.
static NSArray<NSString *> *vkq_choice_titles (NSString *key)
{
	if ([key isEqualToString:@"audioMode"])
		return VKQ_iOS_AudioModeTitles ();
	if ([key isEqualToString:@"mapDownload"])
		return @[ @"Never", @"Ask First", @"Always" ];
	return @[];
}

static NSArray<NSString *> *vkq_choice_details (NSString *key)
{
	if ([key isEqualToString:@"audioMode"])
		return VKQ_iOS_AudioModeDetails ();
	if ([key isEqualToString:@"mapDownload"])
		return @[
			@"Joining a server running a map you do not have simply fails, with a message.",
			@"Offer to fetch the map from the community archives, showing its size first. Recommended.",
			@"Fetch it and rejoin without asking. Uses cellular data if that is all you have.",
		];
	return @[];
}

// ---------------------------------------------------------------------------
// One-of-N picker for a ROW_CHOICE. Each option carries a sentence saying what
// it actually does — the whole point of the Audio section is that "duck" and
// "mix" mean nothing to a player, and a bare four-word label would not help.
@interface VKQChoiceVC : UITableViewController
@property (nonatomic, copy) NSArray<NSString *> *titles, *details;
@property (nonatomic, copy) NSString			*key;
@property (nonatomic) float					 def; // the row's default, so a never-set key checkmarks the right option
@property (nonatomic, copy) void (^onPick) (void);
@end

/*
 * R6.1 item 4 — IS A SETTINGS SCREEN ON SCREEN RIGHT NOW?
 *
 * A COUNTER, not a flag, and that is the whole subtlety. UIKit's transition
 * order when the Audio picker is pushed is: parent viewWillDisappear, child
 * viewWillAppear, child viewDidAppear, parent viewDidDisappear — so a boolean
 * set by appear/disappear ends the push reading "closed" while a settings screen
 * is plainly in front of the player. A depth count is monotone under nesting and
 * reaches zero only when the last one leaves, whichever way it left: Done, the
 * SwiftUI sheet's own header button, a swipe dismiss, or the console command.
 *
 * Read from the ENGINE thread (VKQ_VR_UIInputPump, once per host frame) and only
 * ever written on the main thread, which is why it is a plain volatile int and
 * not an object graph being walked off-thread.
 */
static volatile int vkq_settings_depth = 0;

int VKQ_iOS_SettingsSheetOpen (void) { return vkq_settings_depth > 0 ? 1 : 0; }

@implementation VKQChoiceVC
- (void)viewDidLoad
{
	[super viewDidLoad];
	self.tableView.backgroundColor = UIColor.blackColor;
}
- (void)viewDidAppear:(BOOL)a
{
	[super viewDidAppear:a];
	vkq_settings_depth++;
}
- (void)viewDidDisappear:(BOOL)a
{
	[super viewDidDisappear:a];
	if (vkq_settings_depth > 0)
		vkq_settings_depth--;
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return self.titles.count; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip
{
	UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
	c.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
	c.textLabel.text = self.titles[ip.row];
	c.textLabel.textColor = [UIColor colorWithRed:0.35 green:1 blue:0.35 alpha:1];
	c.detailTextLabel.text = self.details[ip.row];
	c.detailTextLabel.textColor = [UIColor colorWithWhite:0.68 alpha:1];
	c.detailTextLabel.numberOfLines = 0; // let the explanation wrap rather than truncate
	int cur = (int)lroundf (vkq_setting_f (self.key.UTF8String, self.def));
	c.accessoryType = (ip.row == cur) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	c.tintColor = [UIColor colorWithRed:0.35 green:1 blue:0.35 alpha:1];
	return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip
{
	[t deselectRowAtIndexPath:ip animated:YES];
	vkq_setting_set_f (self.key.UTF8String, (float)ip.row);
	[t reloadData];
	if (self.onPick)
		self.onPick ();
	// Let the checkmark land before backing out, so the choice is visibly taken.
	dispatch_after (dispatch_time (DISPATCH_TIME_NOW, (int64_t) (0.25 * NSEC_PER_SEC)), dispatch_get_main_queue (), ^{
		if (self.navigationController.viewControllers.firstObject == self)
			[self dismissViewControllerAnimated:YES completion:nil];
		else
			[self.navigationController popViewControllerAnimated:YES];
	});
}
@end

@interface VKQSettingsVC : UITableViewController
// R6: the row model is rebuilt per sheet open (mode-contextual, C1) and live
// when Interaction Style changes (C4) — and it is DUMPABLE, so the simulator
// asserts the real thing rather than a parallel description of it.
- (void)rebuildRows;
- (NSString *)dumpString;
@end

@implementation VKQSettingsVC {
	NSArray<NSString *>			 *_sections;
	NSArray<NSArray<VKQRow *> *> *_rows;
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"iOS Settings";
	self.tableView.backgroundColor = UIColor.blackColor;
	self.navigationItem.rightBarButtonItem =
		[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector (done)];
	[self rebuildRows];
}

// R6.1 item 4 — see the note on vkq_settings_depth. Both presentation paths (the
// UIKit form sheet the in-menu gear opens and the SwiftUI sheet the ornament
// gear opens) run through these, so one counter covers both without either
// caller having to remember to announce itself.
- (void)viewDidAppear:(BOOL)a
{
	[super viewDidAppear:a];
	vkq_settings_depth++;
}
- (void)viewDidDisappear:(BOOL)a
{
	[super viewDidDisappear:a];
	if (vkq_settings_depth > 0)
		vkq_settings_depth--;
}

/*
 * R6 part C1 — the sheet is built per OPEN, against the mode the app is actually
 * in. A player on the 3D panel has no use for holster sliders, and a player in
 * VR has no use for the panel's screen geometry; showing both was fine while
 * this was a lab bench and is noise now that it is a product surface.
 *
 *   2D  -> both Vision Pro sections (you can enter either mode from here)
 *   3D  -> hide the VR section
 *   VR  -> hide the 3D section
 *
 * VKQ_GetMode() is the authoritative tri-state — the same variable the ornament
 * button, the curtain label and SCR_VRPresentMode's callers read, so the sheet
 * cannot disagree with the app about which mode it is in. Rebuilt on open only:
 * switching modes closes the sheet anyway (both immersive entries dismiss it).
 */
- (void)rebuildRows
{
	NSMutableArray<NSString *>			  *secs = [NSMutableArray array];
	NSMutableArray<NSArray<VKQRow *> *> *rows = [NSMutableArray array];
#ifdef VKQ_VISIONOS
	const int  mode = VKQ_GetMode ();
	const BOOL show3D = (mode != VKQ_MODE_VR);
	const BOOL showVR = (mode != VKQ_MODE_3D);
	// C4: Convenience has no holsters to size or place, so those two rows only
	// exist in Immersive. Rebuilt live when the segment changes (segChanged).
	const BOOL immersive = vkq_setting_f ("vrStyle", VKQ_VR_DEF_STYLE) > 0.5f;
	if (show3D)
	{
		[secs addObject:@"Vision Pro 3D"];
		[rows addObject:@[
			// Sliders apply LIVE while dragging (cheap C calls into the immersive
			// loop) — tune the panel with instant feedback while in 3D.
			mkrow (@"Screen Distance", @"vp3dDist", ROW_SLIDER, 1.0, 8.0, 3.6),
			mkrow (@"Screen Width", @"vp3dHalfW", ROW_SLIDER, 0.6, 4.0, 2.75),
			mkrow (@"Screen Height", @"vp3dSizeH", ROW_SLIDER, 0.5, 3.0, 1.55),
			mkrow (@"Screen Position Height", @"vp3dHeight", ROW_SLIDER, -1.5, 10.0, 0.0),
			mkrow (@"Stereo Depth", @"vp3dSep", ROW_SLIDER, 0.0, 8.0, 2.5),
			mkrow (@"Crosshair Distance", @"vp3dConv", ROW_SLIDER, 32, 512, 240), // 240 u ≈ 20 ft
			mkrow (@"Panel Width", @"vp3dInfoW", ROW_INFO, 0, 0, 0),
			mkrow (@"Panel Height", @"vp3dInfoH", ROW_INFO, 0, 0, 0),
			mkrow (@"Aspect Ratio", @"vp3dInfoAspect", ROW_INFO, 0, 0, 0),
			mkrow (@"Surroundings Dimming", @"vp3dDim", ROW_SLIDER, 0.0, 1.0, 0.8),
			mkrow (@"FPS on Panel", @"vp3dFps", ROW_SWITCH, 0, 1, 0),
			mkrow (@"Units", @"vp3dUnits", ROW_SEG, 0, 1, 1),
			mkrow (@"Recenter Screen", @"vp3dRecenter", ROW_BUTTON, 0, 0, 0),
		]];
	}
	if (showVR)
	{
		// R6: this section is a PRODUCT surface now. The thirteen live-measurement
		// rows and the diagnostics button are gone (C5) — the file they mirrored,
		// Documents/vr-diagnostics.log, is still written in the background and the
		// console commands still print every one of those strings, so nothing was
		// lost except a lab bench in front of the player.
		NSMutableArray<VKQRow *> *vr = [NSMutableArray array];
		[vr addObject:mkrow (@"Enter VR", @"vrEnter", ROW_BUTTON, 0, 0, 0)];
		// VR is always full immersion (the user, 2026-08-10) — the old
		// passthrough/Full switch is gone. The only passthrough question left is
		// the player's own hands, and they default to hidden because a Sense
		// controller in each fist makes ghost limbs read wrong.
		[vr addObject:mkrow (@"Show Hands", @"vrHands", ROW_SWITCH, 0, 1, 0)];
		// R6 part C3 — ONE height knob. World Scale is gone: it is hardcoded to
		// 34 u/m (the value the user plays at), and with the derivation's
		// scale-dependence fixed there is nothing left for a second knob to
		// correct. `vkqvrscale` still moves it from the console.
		//
		// Height is a trim ON TOP of an automatically calibrated baseline, which
		// is why its default is 0.0 and why 0.0 should now be right: the first
		// entry into VR measures the player's standing eye height and stores it.
		[vr addObject:mkrow (@"Height", @"vrHeight", ROW_SLIDER, -0.5, 0.5, VKQ_VR_DEF_HEIGHT)];
		[vr addObject:mkrow (@"Re-calibrate Height", @"vrCalibrate", ROW_BUTTON, 0, 0, 0)];
		[vr addObject:mkrow (@"Recenter View", @"vrRecenter", ROW_BUTTON, 0, 0, 0)];
		// R4 part F. The top of the range is 2.50x, which is the FULL logical
		// resolution the compositor rasterises the blit into (5087x4081 on
		// the user's M5) — past it there is nothing left to buy.
		[vr addObject:mkrow (@"VR Render Quality", @"vrRenderScale", ROW_SLIDER, 1.0, 2.5, VKQ_VR_DEF_RENDER)];
		[vr addObject:mkrow (@"", @"vrNote0", ROW_INFO, 0, 0, 0)];
		// R5 item 6: a STRENGTH, not a switch. 50% is exactly what R4 shipped, 0%
		// skips the pass entirely, 100% is stronger than anything R4 could produce.
		[vr addObject:mkrow (@"Sharpen", @"vrSharpen", ROW_SLIDER, 0.0, 1.0, VKQ_VR_DEF_SHARPEN)];
		// --- R2: Sense controllers (docs/VR-CHARTER.md A6/A8/A10) ---------
		[vr addObject:mkrowseg (@"Aim Hand", @"vrAimHand", 1, @[ @"Left", @"Right" ])];
		[vr addObject:mkrowseg (@"Movement Direction", @"vrMoveDir", 0, @[ @"Head", @"Aim Hand", @"Off Hand" ])];
		// R6.1 item 3: Smooth is the default now (the user). The VR Reset restores
		// it by removing the key, so this constant is the single definition.
		[vr addObject:mkrowseg (@"Snap Turn", @"vrSnapTurn", VKQ_VR_DEF_SNAPTURN, @[ @"Smooth", @"30°", @"45°", @"60°" ])];
		// R4 part E: only meaningful with Snap Turn on Smooth, and labelled so.
		[vr addObject:mkrow (@"Turn Speed (Smooth)", @"vrTurnSpeed", ROW_SLIDER, 60.0, 260.0, 140.0)];
		// R4 part B: the laser is gone (the user: "it never worked for me"). A
		// crosshair drawn at the aim ray's hit, at that hit's depth, replaces it —
		// and the pitch trim is calibrated by watching it. (The huge-magenta debug
		// draw is console-only now: `vkqvrxhair debug`.)
		[vr addObject:mkrow (@"VR Crosshair", @"vrCrosshair", ROW_SWITCH, 0, 1, 1)];
		[vr addObject:mkrow (@"Aim Pitch Trim", @"vrAimPitch", ROW_SLIDER, -15.0, 15.0, 0.0)];
		[vr addObject:mkrowseg (@"HUD Position", @"vrHud", VKQ_VR_DEF_HUD, @[ @"High", @"Low", @"Off" ])];
		// R3 (charter A7), R6 default. Immersive is what the user plays and what the
		// holsters exist for; Convenience keeps the weapon in the hand always.
		[vr addObject:mkrowseg (@"Interaction Style", @"vrStyle", VKQ_VR_DEF_STYLE, @[ @"Convenience", @"Immersive" ])];
		// C4: the holster rows belong to Immersive. In Convenience there are no
		// holstered weapons to size or place, so a slider for them is a control
		// that visibly does nothing — the "Holster Zones" on/off row is gone for
		// the same reason (zones are part of Immersive, not an option).
		if (immersive)
		{
			[vr addObject:mkrow (@"Holster Size", @"vrHolSize", ROW_SLIDER, 0.4, 1.2, VKQ_VR_DEF_HOLSIZE)];
			// R5 item 3 / R6 rename: this moves the ZONE FRAME, so the drawn weapon
			// and the place your hand must reach move together.
			[vr addObject:mkrow (@"Holster Position", @"vrHolFwd", ROW_SLIDER, -0.30, 0.30, VKQ_VR_DEF_HOLFWD)];
		}
		[vr addObject:mkrow (@"Weapon Size", @"vrGunScale", ROW_SLIDER, 0.5, 2.0, 1.0)];
		[vr addObject:mkrow (@"Damage Flash", @"vrFlash", ROW_SLIDER, 0.0, 1.0, 0.5)];
		[vr addObject:mkrow (@"Controller Haptics", @"vrHaptics", ROW_SWITCH, 0, 1, 1)];
		[secs addObject:@"Vision Pro VR"];
		[rows addObject:vr];
	}
#endif
	[secs addObjectsFromArray:@[ @"Aim", @"Display", @"Audio", @"Touch Controls", @"Gameplay" ]];
	[rows addObject:@[
		mkrow (@"Look Sensitivity (H)", @"sensH", ROW_SLIDER, 0.3, 3.0, 1.0),
		mkrow (@"Look Sensitivity (V)", @"sensV", ROW_SLIDER, 0.3, 3.0, 1.0),
		mkrow (@"Invert Look", @"invert", ROW_SWITCH, 0, 1, 0),
		mkrow (@"Gyro Aim", @"gyro", ROW_SLIDER, 0.0, 3.0, 0.0),
		// Separate from "Invert Look" on purpose — tilt-to-aim has two equally
		// common conventions and they are not the same preference as a thumb drag.
		mkrow (@"Invert Gyro (Vertical)", @"gyroInvert", ROW_SWITCH, 0, 1, 0),
	]];
	[rows addObject:@[
		mkrow (@"Field of View", @"fov", ROW_SLIDER, 90, 120, 90),
		// Drives the engine's gamma over the same range its own menu uses
		// (1.0 dark .. 0.5 bright); 0.2 here reproduces the stock gamma 0.9.
		mkrow (@"Brightness", @"brightness", ROW_SLIDER, 0.0, 1.0, 0.2),
		mkrow (@"Menu / HUD Size", @"menuSize", ROW_SLIDER, 0.6, 2.5, 1.3),
		mkrow (@"120 Hz (ProMotion)", @"refresh120", ROW_SWITCH, 0, 1, 1),
	]];
	[rows addObject:@[
		// Master gain on top of the engine's own Sound/Music Volume sliders, so
		// this never overwrites what the in-game Options menu is set to.
		mkrow (@"Game Volume", @"gameVolume", ROW_SLIDER, 0.0, 1.0, 1.0),
		mkrow (@"Other App Audio", @"audioMode", ROW_CHOICE, 0, VKQ_AUDIO_MODE_COUNT - 1, VKQ_AUDIO_DUCK_OTHERS),
	]];
	[rows addObject:@[
		// Button size lives in the layout editor now, as a live slider you can
		// see the result of. Opacity stays here — it reads fine as a number.
		mkrow (@"Button Opacity", @"touchOpacity", ROW_SLIDER, 0.2, 1.0, 0.8),
		// No lefty toggle: the move stick's zone is draggable like every other
		// control, which covers stick-on-the-right and every position between.
		mkrow (@"Customize Touch Layout…", @"layoutEdit", ROW_BUTTON, 0, 0, 0),
		mkrow (@"Fire Haptics", @"haptics", ROW_SWITCH, 0, 1, 1),
	]];
	{
		NSMutableArray<VKQRow *> *gameplay = [NSMutableArray arrayWithArray:@[
			mkrow (@"Always Run", @"alwaysRun", ROW_SWITCH, 0, 1, 1),
			mkrow (@"FPS Counter", @"fps", ROW_SWITCH, 0, 1, 0),
			// MP-DL1 (overlay 0028): mirrors the cl_mapdownload cvar (0/1/2). The
			// cvar is the engine's truth and is archived in config.cfg; this row is
			// the way a phone player reaches it, and ApplySettingsToEngine pushes it
			// down at boot and on every change.
			mkrow (@"Download Missing Maps", @"mapDownload", ROW_CHOICE, 0, 2, 1),
		]];
#ifdef VKQ_DEV_BUILD
		// DEV BUILDS ONLY — compiled out of anything with a public version number.
		// Opens the engine console on TCP 27999 to the local network and tailnet,
		// unauthenticated, so it must never ship publicly.
		[gameplay addObject:mkrow (@"Remote Console (port 27999)", @"remoteConsole", ROW_SWITCH, 0, 1, 0)];
#endif
		// R6 part C6 — CHEATS, at the bottom of Gameplay, in every mode. The old
		// "Give All Weapons (testing)" button lived in the VR section and read as
		// debug scaffolding; these are the same two cheats a Quake player has
		// always had, named as what they are.
		[gameplay addObject:mkrow (@"Cheats", @"cheatHdr", ROW_SUBHEAD, 0, 0, 0)];
		// A BUTTON, not a toggle: `impulse 9` is an event (all weapons, full ammo,
		// all keys) and pressing it again refills. There is no "off".
		[gameplay addObject:mkrow (@"All Weapons", @"cheatWeapons", ROW_BUTTON, 0, 0, 0)];
		// A SWITCH, and its displayed state is read from the player edict's
		// FL_GODMODE rather than remembered here — see switchChanged/cellForRow.
		[gameplay addObject:mkrow (@"God Mode", @"cheatGod", ROW_SWITCH, 0, 1, 0)];
		[rows addObject:gameplay];
	}
	_sections = secs;
	_rows = rows;
}

/*
 * R6 part D — the settings sheet, as a line a harness can assert on.
 *
 * This walks the SAME model the table view renders: same rebuildRows, same row
 * objects, same defaults. A dump built from a separate description of what the
 * sheet "should" contain would pass forever while the sheet said something else
 * — which is the shape of every bug this project has paid for twice.
 */
- (NSString *)dumpString
{
	NSMutableString *s = [NSMutableString string];
#ifdef VKQ_VISIONOS
	[s appendFormat:@"mode=%d ", VKQ_GetMode ()];
#else
	[s appendString:@"mode=ios "];
#endif
	[s appendFormat:@"sections=%lu |", (unsigned long)_sections.count];
	for (NSUInteger i = 0; i < _sections.count; i++)
	{
		[s appendFormat:@" [%@]", _sections[i]];
		for (VKQRow *r in _rows[i])
		{
			if (r.type == ROW_SUBHEAD)
				[s appendFormat:@" <%@>", r.title];
			else if (r.type == ROW_BUTTON || r.type == ROW_INFO)
				[s appendFormat:@" %@", r.key];
			else
				[s appendFormat:@" %@=%.4f", r.key, vkq_setting_f (r.key.UTF8String, r.def)];
		}
		[s appendString:@" |"];
	}
	return s;
}

const char *VKQ_iOS_SettingsDumpText (void)
{
	static char buf[8192];
	@autoreleasepool
	{
		VKQSettingsVC *vc = [[VKQSettingsVC alloc] initWithStyle:UITableViewStyleInsetGrouped];
		[vc rebuildRows];
		snprintf (buf, sizeof (buf), "%s", vc.dumpString.UTF8String);
	}
	return buf;
}

- (void)done
{
#ifdef VKQ_VISIONOS
	extern void VKQ_CloseSettingsSheet (void); // SwiftUI sheet path (@_cdecl)
	VKQ_CloseSettingsSheet ();
#endif
	[self dismissViewControllerAnimated:YES completion:nil]; // UIKit modal path
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return _sections.count; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { return _sections[s]; }
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s
{
	if ([_sections[s] isEqualToString:@"Audio"])
		return @"“Other App Audio” only matters while something else — music, a podcast — is already playing. "
			   @"Game Volume rides on top of the in-game Options → Sound/Music Volume sliders, so it never overwrites them.";
	return nil;
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return _rows[s].count; }

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip
{
	VKQRow			*r = _rows[ip.section][ip.row];
	UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
	c.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
	c.textLabel.text = r.title;
	c.textLabel.textColor = [UIColor colorWithRed:0.35 green:1 blue:0.35 alpha:1];
	c.selectionStyle = UITableViewCellSelectionStyleNone;
	float v = vkq_setting_f (r.key.UTF8String, r.def);
	if (r.type == ROW_CHOICE)
	{
		// Value1 style: title on the left, the CURRENT option on the right, so the
		// section reads as an answer without having to open the picker.
		UITableViewCell *cc = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
		cc.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
		cc.textLabel.text = r.title;
		cc.textLabel.textColor = [UIColor colorWithRed:0.35 green:1 blue:0.35 alpha:1];
		NSArray<NSString *> *opts = vkq_choice_titles (r.key);
		int					 idx = (int)lroundf (v);
		cc.detailTextLabel.text = (idx >= 0 && idx < (int)opts.count) ? opts[idx] : @"-";
		cc.detailTextLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1];
		cc.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		return cc;
	}
	if (r.type == ROW_SUBHEAD)
	{
		// R6 part C6 — a heading inside a section. Same idiom as the section
		// headers (semibold, label colour) at row scale, and untouchable.
		c.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
		c.textLabel.textColor = [UIColor colorWithWhite:0.62 alpha:1];
		c.selectionStyle = UITableViewCellSelectionStyleNone;
		c.accessoryView = nil;
		c.userInteractionEnabled = NO;
		return c;
	}
	if (r.type == ROW_BUTTON)
	{
		c.textLabel.textColor = [UIColor colorWithRed:0.4 green:0.8 blue:1.0 alpha:1];
		c.selectionStyle = UITableViewCellSelectionStyleDefault;
		// A cheat that the engine will refuse (no level loaded, or deathmatch)
		// says so instead of doing nothing when tapped.
		if ([r.key isEqualToString:@"cheatWeapons"] && !VKQ_iOS_CheatsAvailable ())
		{
			c.textLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1];
			c.selectionStyle = UITableViewCellSelectionStyleNone;
		}
		return c;
	}
#ifdef VKQ_VISIONOS
	if (r.type == ROW_SEG)
	{
		UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:r.segs ?: @[ @"m", @"ft" ]];
		int					idx = (int)lroundf (v);
		seg.selectedSegmentIndex = (idx >= 0 && idx < (int)seg.numberOfSegments) ? idx : 0;
		tag_ctl (seg, r);
		[seg addTarget:self action:@selector (segChanged:) forControlEvents:UIControlEventValueChanged];
		c.accessoryView = seg;
		return c;
	}
	if (r.type == ROW_INFO && [r.key isEqualToString:@"vrNote0"])
	{
		// The measured tradeoff, stated where the slider is. From the user's own
		// vr-diagnostics.log of 2026-08-10: at 1.00x the device presented
		// 116-120 Hz all session; at 2.00x the PACING lines read 60.0 Hz — the
		// compositor halved the cadence rather than dropping frames. 60 Hz is
		// exactly the head-turn smear he reported in R1.
		c.textLabel.text = @"2.0x and above render sharper but halve motion smoothness to 60 Hz. "
						   @"1.25-1.5x with Sharpen on holds 120 Hz.";
		c.textLabel.numberOfLines = 0;
		c.textLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1];
		c.textLabel.font = [UIFont systemFontOfSize:13];
		c.selectionStyle = UITableViewCellSelectionStyleNone;
		c.accessoryView = nil;
		return c;
	}
	// R6 part C5: the thirteen vrStatus rows and the Write Diagnostics button are
	// GONE from the sheet. Documents/vr-diagnostics.log still receives every one
	// of those strings in the background, and every console command that printed
	// them still does — this is a product screen now, not a lab bench.
	if (r.type == ROW_INFO)
	{
		// Read-only feedback: the live render-target size and its aspect
		// (normalized to :9, whole numbers). In 3D the panel resolution is the
		// engine override (decoupled from the parked 2D window) — report the
		// ACTUAL live target, not the window.
		extern int	VKQ_Get3DMode (void);
		extern void VKQ_Get3DPresentSize (int *w, int *h);
		int pw = 0, ph = 0;
		VKQ_Get3DPresentSize (&pw, &ph);
		if (!(VKQ_Get3DMode () && pw > 0))
		{
			VKQ_GetWindowSize (&pw, &ph);
			pw *= 2; // points -> pixels (visionOS scale 2)
			ph *= 2;
		}
		UILabel *val = [UILabel new];
		if ([r.key isEqualToString:@"vp3dInfoW"])
			val.text = [NSString stringWithFormat:@"%d px", pw];
		else if ([r.key isEqualToString:@"vp3dInfoH"])
			val.text = [NSString stringWithFormat:@"%d px", ph];
		else
			val.text = ph > 0 ? [NSString stringWithFormat:@"%d:9", (int)lroundf ((float)pw * 9.0f / (float)ph)] : @"-";
		val.textColor = [UIColor colorWithWhite:0.7 alpha:1];
		val.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightMedium];
		[val sizeToFit];
		c.textLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1];
		c.accessoryView = val;
		return c;
	}
#endif
	if (r.type == ROW_SWITCH)
	{
		UISwitch *sw = [UISwitch new];
		sw.on = v > 0.5f;
		// R6 part C6 — GROUND TRUTH, not the stored preference. The local server
		// is in-process, so the switch shows the player edict's FL_GODMODE: a
		// console `god`, a fresh level (which clears it) and a loaded save all
		// move this switch, because it is reading the same bit they change.
		if ([r.key isEqualToString:@"cheatGod"])
		{
			sw.on = VKQ_iOS_GodModeActive () != 0;
			sw.enabled = VKQ_iOS_CheatsAvailable () != 0;
			c.textLabel.textColor = sw.enabled ? c.textLabel.textColor : [UIColor colorWithWhite:0.4 alpha:1];
		}
		sw.onTintColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.2 alpha:1];
		tag_ctl (sw, r);
		[sw addTarget:self action:@selector (switchChanged:) forControlEvents:UIControlEventValueChanged];
		c.accessoryView = sw;
	}
	else
	{
		// Slider + live value readout. The readout is the point of the row — a
		// bare knob tells you nothing about what you are sliding to. visionOS
		// gets the wider treatment (m/ft honoring the units toggle).
		//
		// LAID OUT WITH CONSTRAINTS, not a fixed-size accessoryView. The old
		// accessoryView was a rigid 452pt box on visionOS, which fits the 900pt
		// SwiftUI sheet but not the much narrower UIKit form sheet the in-menu
		// gear button opens — there the box ate the whole cell and cropped every
		// title down to its first letter ("Screen Distance" -> "S"). Now the
		// slider gives up width first (down to slMin) and the title only shrinks
		// after that, so no sheet width can hide what a slider controls.
#ifdef VKQ_VISIONOS
		const CGFloat valW = 84, slMin = 170, slMax = 360, gap = 10, valFont = 16;
#else
		const CGFloat valW = 58, slMin = 120, slMax = 220, gap = 8, valFont = 14;
#endif
		UIView	*cv = c.contentView;
		UILabel *title = [UILabel new];
		title.text = r.title;
		title.font = c.textLabel.font;
		title.textColor = c.textLabel.textColor;
		title.adjustsFontSizeToFitWidth = YES; // shrink before truncating
		title.minimumScaleFactor = 0.7;
		title.lineBreakMode = NSLineBreakByTruncatingTail;
		c.textLabel.text = nil; // the constrained title replaces the stock one

		UISlider *sl = [UISlider new];
		UILabel	 *val = [UILabel new];
		val.textColor = [UIColor colorWithWhite:0.85 alpha:1];
		val.font = [UIFont monospacedDigitSystemFontOfSize:valFont weight:UIFontWeightMedium];
		val.textAlignment = NSTextAlignmentRight;
		val.text = vkq_row_value_text (r.key, v);
		objc_setAssociatedObject (sl, "vkq_val_label", val, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		sl.minimumValue = r.mn;
		sl.maximumValue = r.mx;
		sl.value = v;
		sl.minimumTrackTintColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.2 alpha:1];
		tag_ctl (sl, r);
		[sl addTarget:self action:@selector (sliderChanged:) forControlEvents:UIControlEventValueChanged];
		[sl addTarget:self action:@selector (sliderReleased:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];

		for (UIView *sub in @[ title, sl, val ])
		{
			sub.translatesAutoresizingMaskIntoConstraints = NO;
			[cv addSubview:sub];
		}
		// The title holds its natural width (hugging 751) but yields it under
		// pressure (compression resistance 250) — the slider's slMin floor wins
		// the argument, and slack lands in the gap between title and slider.
		[title setContentHuggingPriority:UILayoutPriorityDefaultHigh + 1 forAxis:UILayoutConstraintAxisHorizontal];
		[title setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
		NSLayoutConstraint *slWide = [sl.widthAnchor constraintEqualToConstant:slMax];
		slWide.priority = UILayoutPriorityDefaultHigh; // 750: honored when there is room
		NSLayoutConstraint *slBottom = [sl.bottomAnchor constraintEqualToAnchor:cv.bottomAnchor constant:-6];
		slBottom.priority = UILayoutPriorityRequired - 1; // avoid fighting UIKit's sizing pass
		[NSLayoutConstraint activateConstraints:@[
			[title.leadingAnchor constraintEqualToAnchor:cv.layoutMarginsGuide.leadingAnchor],
			[sl.leadingAnchor constraintGreaterThanOrEqualToAnchor:title.trailingAnchor constant:gap + 4],
			[sl.trailingAnchor constraintEqualToAnchor:val.leadingAnchor constant:-gap],
			[sl.widthAnchor constraintGreaterThanOrEqualToConstant:slMin],
			[sl.widthAnchor constraintLessThanOrEqualToConstant:slMax],
			slWide,
			[val.trailingAnchor constraintEqualToAnchor:cv.layoutMarginsGuide.trailingAnchor],
			[val.widthAnchor constraintEqualToConstant:valW],
			[sl.topAnchor constraintEqualToAnchor:cv.topAnchor constant:6],
			slBottom,
			[sl.heightAnchor constraintGreaterThanOrEqualToConstant:30],
			[title.centerYAnchor constraintEqualToAnchor:sl.centerYAnchor],
			[val.centerYAnchor constraintEqualToAnchor:sl.centerYAnchor],
			[title.topAnchor constraintGreaterThanOrEqualToAnchor:cv.topAnchor constant:4],
			[title.bottomAnchor constraintLessThanOrEqualToAnchor:cv.bottomAnchor constant:-4],
		]];
	}
	return c;
}

#ifdef VKQ_VISIONOS
- (void)segChanged:(UISegmentedControl *)seg
{
	const BOOL styleChanged = !strcmp (ctl_key (seg), "vrStyle");
	vkq_setting_set_f (ctl_key (seg), (float)seg.selectedSegmentIndex);
	VKQ_iOS_ApplySettingsToEngine ();
	VKQ_iOS_ApplyVRSettings (); // aim hand / movement / snap turn take effect now
	// R6 part C4: Convenience has no holsters, so its two rows appear and
	// disappear with the segment, live, under the finger that just moved it.
	if (styleChanged)
		[self rebuildRows];
	[self.tableView reloadData]; // every value label changes with the units
}
#endif

- (void)switchChanged:(UISwitch *)sw
{
	vkq_setting_set_f (ctl_key (sw), sw.on ? 1.0f : 0.0f);
	VKQ_iOS_ApplySettingsToEngine ();
#ifdef VKQ_VISIONOS
	// Upper-limb visibility is a SwiftUI scene modifier on the open VR space; it
	// is bound to the model, so it takes effect on the next scene update.
	if (!strcmp (ctl_key (sw), "vrHands"))
		VKQ_VR_SetShowHands (sw.on);
	if (!strncmp (ctl_key (sw), "vr", 2))
		VKQ_iOS_ApplyVRSettings ();
#endif
	// Start the bridge the moment it is switched on, so it does not need a
	// relaunch. Switching it off takes effect on next launch (the listener is not
	// torn down mid-session) — the row title says port, the OTA notes say the rest.
#ifdef VKQ_DEV_BUILD
	if (!strcmp (ctl_key (sw), "remoteConsole") && sw.on)
	{
		extern void VKQ_iOS_ConsoleBridgeStart (void);
		VKQ_iOS_ConsoleBridgeStart ();
	}
#endif
	// R6 part C6 — God Mode. `god 1` / `god 0` is the EXPLICIT form (host_cmd.c
	// supports it), never the bare toggle: the switch says what it wants and the
	// re-assert below can then run as often as it likes without inverting
	// anything. The row redraws from the edict, so if the engine refuses the
	// cheat the switch springs straight back — which is the truth.
	if (!strcmp (ctl_key (sw), "cheatGod"))
	{
		VKQ_iOS_SetGodMode (sw.on ? 1 : 0);
		dispatch_after (dispatch_time (DISPATCH_TIME_NOW, (int64_t) (0.30 * NSEC_PER_SEC)), dispatch_get_main_queue (), ^{ [self.tableView reloadData]; });
	}
}

// ROW_BUTTON rows had no tap handler at all until now — this table view never
// implemented didSelectRowAtIndexPath, so "Recenter Screen" on Vision Pro drew
// as a tappable row and did nothing when tapped.
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip
{
	VKQRow *r = _rows[ip.section][ip.row];
	[t deselectRowAtIndexPath:ip animated:YES];
	if (r.type == ROW_CHOICE)
	{
		VKQChoiceVC *pick = [[VKQChoiceVC alloc] initWithStyle:UITableViewStyleInsetGrouped];
		pick.title = r.title;
		pick.titles = vkq_choice_titles (r.key);
		pick.details = vkq_choice_details (r.key);
		pick.key = r.key;
		pick.def = r.def;
		__weak VKQSettingsVC *weakSelf = self;
		pick.onPick = ^{
			// Both choice rows push their answer straight into the engine:
			// audioMode reconfigures the session, mapDownload writes the cvar.
			VKQ_iOS_AudioApply ();
			VKQ_iOS_ApplySettingsToEngine ();
			[weakSelf.tableView reloadData]; // refresh the summary on the parent row
		};
		// Vision Pro opens this table bare inside a SwiftUI sheet — there is no
		// navigation controller to push onto there, so wrap and present instead.
		if (self.navigationController)
			[self.navigationController pushViewController:pick animated:YES];
		else
		{
			UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:pick];
			nav.navigationBar.titleTextAttributes = @{NSForegroundColorAttributeName : UIColor.greenColor};
			[self presentViewController:nav animated:YES completion:nil];
		}
		return;
	}
	if (r.type != ROW_BUTTON)
		return;
	if ([r.key isEqualToString:@"layoutEdit"])
	{
		// The sheet covers the screen you are about to arrange — close it first,
		// then hand over to the on-screen editor.
		extern void VKQ_iOS_ToggleLayoutEdit (void);
		[self done];
		dispatch_after (dispatch_time (DISPATCH_TIME_NOW, (int64_t) (0.35 * NSEC_PER_SEC)), dispatch_get_main_queue (),
						^{ VKQ_iOS_ToggleLayoutEdit (); });
		return;
	}
#ifdef VKQ_VISIONOS
	if ([r.key isEqualToString:@"vp3dRecenter"])
		VKQ_Recenter3D ();
	if ([r.key isEqualToString:@"vrEnter"])
	{
		// The sheet lives over the flat window; close it before the space opens.
		[self done];
		dispatch_after (dispatch_time (DISPATCH_TIME_NOW, (int64_t) (0.35 * NSEC_PER_SEC)), dispatch_get_main_queue (), ^{ VKQ_EnterMode (2); });
		return;
	}
	if ([r.key isEqualToString:@"vrCalibrate"])
	{
		// R6 part C3 — RE-calibrate. Two things, because a baseline and a trim on
		// top of it are only meaningful together: re-derive the stored standing
		// eye height from where the head is right now, AND put Height back to 0.0.
		// Otherwise a player who had dialled +9 in against the old derivation
		// re-calibrates and is nine inches too tall, which reads as the button
		// having made things worse.
		VKQ_VR_ClearHeightBaseline ();
		VKQ_VR_CalibrateHeight ();
		vkq_setting_set_f ("vrHeight", VKQ_VR_DEF_HEIGHT);
		vkq_vrHeightOffset = VKQ_VR_DEF_HEIGHT;
		[self.tableView reloadData];
	}
	if ([r.key isEqualToString:@"vrRecenter"])
		VKQ_VR_Recenter ();
#endif
	// R6 part C6 — `impulse 9`: all weapons, full ammo, all keys. An event, not a
	// state; pressing it again refills. Exactly what typing it in the console
	// does, on every platform and in every mode.
	if ([r.key isEqualToString:@"cheatWeapons"])
	{
		extern void Cbuf_AddText (const char *text);
		if (VKQ_iOS_CheatsAvailable ())
			Cbuf_AddText ("impulse 9\n");
	}
}

#ifdef VKQ_VISIONOS
// Custom header views get a COMPRESSED height without an explicit delegate —
// which shoved "Vision Pro 3D"/Reset up under the sheet's Settings bar.
// ... and a header that is TALLER than its content, not shorter: the button is
// ~44pt of glass, and a 72pt slot with the label pinned 6pt off the bottom left
// it hanging 6pt past the header, painted over the first slider row.
// R6: keyed by TITLE, not by index. The Vision Pro sections are conditional now
// (C1), so "section 0 is the 3D one" stopped being true the moment VR mode hid
// it — and a Reset button wired to an index would have started resetting the
// panel from the VR section's header.
- (BOOL)sectionHasReset:(NSInteger)s
{
	return [_sections[s] isEqualToString:@"Vision Pro 3D"] || [_sections[s] isEqualToString:@"Vision Pro VR"];
}

- (CGFloat)tableView:(UITableView *)t heightForHeaderInSection:(NSInteger)s
{
	return [self sectionHasReset:s] ? 92.0 : UITableViewAutomaticDimension;
}

// Both Vision Pro headers carry their own Reset control.
- (UIView *)tableView:(UITableView *)t viewForHeaderInSection:(NSInteger)s
{
	if (![self sectionHasReset:s])
		return nil;
	const BOOL isVR = [_sections[s] isEqualToString:@"Vision Pro VR"];
	// Tall header with a REAL bordered Reset button — the bare-text version sat
	// tight under the sheet's Settings bar and was nearly impossible to gaze-pinch.
	UIView	*hv = [[UIView alloc] initWithFrame:CGRectMake (0, 0, t.bounds.size.width, 92)];
	UILabel *l = [UILabel new];
	l.text = _sections[s];
	l.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
	l.textColor = UIColor.labelColor;
	l.translatesAutoresizingMaskIntoConstraints = NO;
	UIButton *reset;
	UIButtonConfiguration *cfg = [UIButtonConfiguration tintedButtonConfiguration];
	cfg.title = @"Reset";
	cfg.contentInsets = NSDirectionalEdgeInsetsMake (10, 22, 10, 22);
	reset = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
	reset.translatesAutoresizingMaskIntoConstraints = NO;
	[reset addTarget:self action:(isVR ? @selector (resetVisionVR) : @selector (resetVision3D)) forControlEvents:UIControlEventTouchUpInside];
	[hv addSubview:l];
	[hv addSubview:reset];
	// Anchor the BUTTON (the tallest thing here) with real clearance above the
	// first row, and hang the label off its centre — pinning the label instead
	// let the button overflow by however much taller than the text it was.
	[NSLayoutConstraint activateConstraints:@[
		[l.leadingAnchor constraintEqualToAnchor:hv.leadingAnchor constant:20],
		[reset.trailingAnchor constraintEqualToAnchor:hv.trailingAnchor constant:-20],
		[reset.bottomAnchor constraintEqualToAnchor:hv.bottomAnchor constant:-16],
		[reset.topAnchor constraintGreaterThanOrEqualToAnchor:hv.topAnchor constant:8],
		[l.centerYAnchor constraintEqualToAnchor:reset.centerYAnchor],
		[l.trailingAnchor constraintLessThanOrEqualToAnchor:reset.leadingAnchor constant:-12],
	]];
	return hv;
}

- (void)resetVision3D
{
	// Back to defaults for the panel/stereo sliders (units & FPS prefs kept),
	// then re-sync the render target to the default panel shape.
	extern void VKQ_iOS_Sync3DAspect (void);
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	for (NSString *k in @[ @"vp3dDist", @"vp3dHalfW", @"vp3dSizeH", @"vp3dHeight", @"vp3dSep", @"vp3dConv", @"vp3dDim" ])
		[d removeObjectForKey:[KEYPREFIX stringByAppendingString:k]];
	VKQ_iOS_ApplySettingsToEngine ();
	VKQ_iOS_Sync3DAspect ();
	[self.tableView reloadData];
}

/*
 * R6 part C2 — the VR section's own Reset. ONLY the VR keys: 3D, Gameplay,
 * Audio, Aim and the cheats are untouched, which is the whole reason this is a
 * second button rather than a bigger first one.
 *
 * It also clears the stored height BASELINE, so the next VR entry measures the
 * player again from scratch. A reset that restored Height to 0.0 while keeping
 * a baseline captured in some other posture would put them back at a number
 * that is only correct for whoever calibrated it.
 */
- (void)resetVisionVR
{
	VKQ_iOS_ResetVRSettings ();
	[self rebuildRows]; // Interaction Style went back to Immersive: the holster rows may return
	[self.tableView reloadData];
}

// The reset itself, callable without a sheet — the `vkqvrreset` console command
// runs THIS, so the simulator exercises the shipping path rather than a copy of
// it that could drift from the button.
void VKQ_iOS_ResetVRSettings (void)
{
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	// Removing the key is how a row goes back to the DEFAULT in its mkrow, which
	// keeps one definition of every default (the row) rather than two.
	for (NSString *k in @[
			 @"vrHeight", @"vrRenderScale", @"vrSharpen", @"vrHands", @"vrAimHand", @"vrMoveDir", @"vrSnapTurn", @"vrTurnSpeed", @"vrCrosshair",
			 @"vrAimPitch", @"vrHud", @"vrStyle", @"vrHolSize", @"vrHolFwd", @"vrGunScale", @"vrFlash", @"vrHaptics"
		 ])
		[d removeObjectForKey:[KEYPREFIX stringByAppendingString:k]];
	// The two that are no longer rows and must not drift: world scale is fixed at
	// 34 u/m (C3) and holster zones are part of Immersive (C4).
	vkq_setting_set_f ("vrScale", VKQ_VR_DEF_SCALE);
	vkq_setting_set_f ("vrZones", 1.0f);
	vkq_setting_set_f ("vrXhairDebug", 0.0f);
	VKQ_VR_ClearHeightBaseline ();
	vkq_vrWorldScale = VKQ_VR_DEF_SCALE;
	vkq_vrHeightOffset = VKQ_VR_DEF_HEIGHT;
	vkq_vrRenderScale = VKQ_VR_DEF_RENDER;
	VKQ_iOS_ApplySettingsToEngine ();
	VKQ_iOS_ApplyVRSettings ();
	NSLog (@"[vkquake] VR settings reset to the R6 defaults; height baseline cleared");
}
#endif

- (void)sliderChanged:(UISlider *)sl
{
	// overlay settings (sensitivity, touch size/opacity, gyro) are read live by the
	// overlay; engine cvars (menu size) are pushed on release to avoid flooding the
	// command buffer while dragging.
	vkq_setting_set_f (ctl_key (sl), sl.value);
	NSString *key = [NSString stringWithUTF8String:ctl_key (sl)];
	UILabel	 *val = objc_getAssociatedObject (sl, "vkq_val_label");
	if (val)
		val.text = vkq_row_value_text (key, sl.value); // track the thumb live
#ifdef VKQ_VISIONOS
	// panel/stereo sliders are plain C state — safe (and delightful) to apply
	// live while dragging, with instant feedback on the 3D panel
	if ([key hasPrefix:@"vp3d"])
		VKQ_iOS_Apply3DSettings ();
	// VR scale/height are plain floats the compositor reads every frame, so they
	// retune the world live while you drag — the fastest way to find the scale
	// that feels architectural rather than doll-house.
	if ([key isEqualToString:@"vrScale"])
		vkq_vrWorldScale = sl.value;
	if ([key isEqualToString:@"vrHeight"])
		vkq_vrHeightOffset = sl.value;
	// Render quality is NOT live: the eye render target is sized once, on the VR
	// loop's first drawable, and resizing it mid-space would blit a dying texture
	// (the two-phase-entry trap). It applies on the next VR entry.
	if ([key isEqualToString:@"vrRenderScale"])
		vkq_vrRenderScale = sl.value;
	// R2 grip calibration + damage flash: plain cvars the render path reads every
	// frame, so the weapon turns in the hand while the slider moves. This is the
	// point of the row — a build-per-guess loop is what it exists to avoid.
	if ([key hasPrefix:@"vrGun"] || [key isEqualToString:@"vrFlash"])
		VKQ_iOS_ApplyVRSettings ();
	// R4 part B: the Aim Pitch Trim MUST be live while the thumb is down — the
	// crosshair is the instrument you calibrate it with, and the settings sheet
	// floats beside the world rather than replacing it, so the world keeps
	// rendering and the reticle keeps moving under the finger. Turn speed is
	// live for the same reason: you find it by turning.
	if ([key isEqualToString:@"vrAimPitch"] || [key isEqualToString:@"vrTurnSpeed"])
		VKQ_iOS_ApplyVRSettings ();
	// R5: the holster sliders are live for exactly the same reason — you find
	// them by reaching for your hip and looking at what is there. Sharpen is read
	// straight out of the settings store by the blit every frame, so it needs no
	// push at all; it is listed here only so the next reader does not go looking
	// for the missing case.
	if ([key isEqualToString:@"vrHolSize"] || [key isEqualToString:@"vrHolFwd"])
		VKQ_iOS_ApplyVRSettings ();
#endif
}
- (void)sliderReleased:(UISlider *)sl
{
	vkq_setting_set_f (ctl_key (sl), sl.value);
	VKQ_iOS_ApplySettingsToEngine ();
#ifdef VKQ_VISIONOS
	// Panel shape changed: re-sync the render target's aspect (sharp again) and
	// refresh the Panel Width/Height/Aspect feedback rows.
	NSString *key = [NSString stringWithUTF8String:ctl_key (sl)];
	if ([key isEqualToString:@"vp3dHalfW"] || [key isEqualToString:@"vp3dSizeH"])
	{
		extern void VKQ_iOS_Sync3DAspect (void);
		VKQ_iOS_Sync3DAspect ();
		dispatch_after (dispatch_time (DISPATCH_TIME_NOW, (int64_t) (0.6 * NSEC_PER_SEC)), dispatch_get_main_queue (),
						^{ [self.tableView reloadData]; });
	}
#endif
}
@end

// ---------------------------------------------------------------------------
static UIWindow *vkq_settings_window (void)
{
	for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
		if ([s isKindOfClass:UIWindowScene.class])
		{
			UIWindowScene *ws = (UIWindowScene *)s;
			for (UIWindow *w in ws.windows)
				if (w.isKeyWindow)
					return w;
			return ws.windows.firstObject;
		}
	return nil;
}

#ifdef VKQ_VISIONOS
// Factory for the SwiftUI sheet host: a UIKit modal presented directly works in
// 2D but silently fails over an open ImmersiveSpace (quake3e-documented); the
// SwiftUI .sheet presents correctly alongside the 3D panel.
UIViewController *VKQ_iOS_MakeSettingsNav (void)
{
	// BARE table for the SwiftUI sheet: the sheet supplies its own header with a
	// Done button (the UIKit nav bar's Done did not survive presentation from
	// the small parked window — that left only the window-close X,
	// which kills the scene and the audio session with it).
	return [[VKQSettingsVC alloc] initWithStyle:UITableViewStyleInsetGrouped];
}
#endif

/*
 * VKQ_iOS_DismissSettings -- R6.1 item 4.
 *
 * Close whatever settings screen is up, from anywhere: the `vkqsettings close`
 * console command (so a remote rescue over the bridge is never blocked on a hand
 * reaching for Done — the thing that stalled the user's 1.0.7.9 round), the Sense
 * B/menu press in VKQ_VR_UIInputPump, and `done` itself.
 *
 * BOTH presentation paths are told, unconditionally, because they are not
 * alternatives that this function can distinguish from a background thread: the
 * ornament gear opens a SwiftUI sheet bound to VKQAppModel.showSettings, while
 * the in-menu gear presents a UIKit form sheet on the key window. Telling the
 * one that is not up costs a no-op assignment and a nil-check; guessing wrong
 * costs the rescue this exists for.
 *
 * Dismissing the ROOT's presented controller takes any pushed or presented child
 * (the Audio picker) with it, which is why there is no walk down the chain.
 */
void VKQ_iOS_DismissSettings (void)
{
	dispatch_async (dispatch_get_main_queue (), ^{
#ifdef VKQ_VISIONOS
		extern void VKQ_CloseSettingsSheet (void); // @_cdecl, VKQVisionApp.swift
		VKQ_CloseSettingsSheet ();
#endif
		UIViewController *root = vkq_settings_window ().rootViewController;
		if (root.presentedViewController)
			[root dismissViewControllerAnimated:YES completion:nil];
	});
}

void VKQ_iOS_PresentSettings (void)
{
	dispatch_async (dispatch_get_main_queue (), ^{
		UIWindow		 *win = vkq_settings_window ();
		UIViewController *root = win.rootViewController;
		if (!root || root.presentedViewController)
			return;
		VKQSettingsVC		  *vc = [[VKQSettingsVC alloc] initWithStyle:UITableViewStyleInsetGrouped];
		UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
		nav.modalPresentationStyle = UIModalPresentationFormSheet;
		nav.navigationBar.titleTextAttributes = @{NSForegroundColorAttributeName : UIColor.greenColor};
#ifdef VKQ_VISIONOS
		// Match the SwiftUI sheet's 900pt: the stock form-sheet width left the
		// panel sliders no room to be precise with, and this is the sheet the
		// in-menu gear opens (the ornament's gear opens the SwiftUI one).
		nav.preferredContentSize = CGSizeMake (900, 760);
#endif
		[root presentViewController:nav animated:YES completion:nil];
	});
}
