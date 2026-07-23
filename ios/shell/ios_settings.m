/*
 * ios_settings.m — NSUserDefaults-backed settings + a native panel.
 * The touch overlay reads values live via vkq_setting_f(); engine-backed
 * settings (menu size, always-run) are pushed through the Cbuf bridge.
 */
#import "ios_settings.h"
#import <objc/runtime.h>

extern void VKQ_TouchCommand (const char *text);
extern void VKQ_TouchSetRun (int on);
extern void VKQ_iOS_SetRefresh (void);

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
// shell-visionos externs (panel/stereo live-tuning)
extern void VKQ_iOS_Apply3DSettings (void);
extern void VKQ_Recenter3D (void);
extern int	vkq3d_immersive_on; // ios_touch.m — 1 while the 3D panel is up
#endif

void VKQ_iOS_ApplySettingsToEngine (void)
{
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
	VKQ_iOS_SetRefresh ();
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
	ROW_INFO, // read-only feedback (panel width / aspect / height)
	ROW_SEG	  // segmented m|ft (units)
} VKQRowType;

#ifdef VKQ_VISIONOS
extern void VKQ_GetWindowSize (int *w, int *h); // engine (points; drawable is 2x)

// Value-label text for the Vision Pro sliders: lengths honor the ft/m toggle
// (storage is always meters / game units), stereo depth reads as a percentage
// of the default separation.
static NSString *vkq_vp3d_value_text (NSString *key, float v)
{
	BOOL ft = vkq_setting_f ("vp3dUnits", 1.0f) > 0.5f; // ft default (quake3e)
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
	return [NSString stringWithFormat:@"%.1f", v];
}
#endif

@interface VKQRow : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *key;
@property (nonatomic) VKQRowType type;
@property (nonatomic) float mn, mx, def;
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

// stash the row's key on its control via an associated object
static char kRowKeyTag;
static void tag_ctl (UIControl *ctl, VKQRow *r) { objc_setAssociatedObject (ctl, &kRowKeyTag, r.key, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
static const char *ctl_key (UIControl *ctl)
{
	NSString *k = objc_getAssociatedObject (ctl, &kRowKeyTag);
	return k.UTF8String;
}

@interface VKQSettingsVC : UITableViewController
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

	_sections = @[
#ifdef VKQ_VISIONOS
		@"Vision Pro 3D",
#endif
		@"Aim", @"Display", @"Touch Controls", @"Gameplay"
	];
	_rows = @[
#ifdef VKQ_VISIONOS
		// Sliders apply LIVE while dragging (cheap C calls into the immersive
		// loop) — tune the panel with instant feedback while in 3D.
		@[
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
		],
#endif
		@[
			mkrow (@"Look Sensitivity (H)", @"sensH", ROW_SLIDER, 0.3, 3.0, 1.0),
			mkrow (@"Look Sensitivity (V)", @"sensV", ROW_SLIDER, 0.3, 3.0, 1.0),
			mkrow (@"Invert Look", @"invert", ROW_SWITCH, 0, 1, 0),
			mkrow (@"Gyro Aim", @"gyro", ROW_SLIDER, 0.0, 3.0, 0.0),
		],
		@[
			mkrow (@"Field of View", @"fov", ROW_SLIDER, 90, 120, 90),
			mkrow (@"Menu / HUD Size", @"menuSize", ROW_SLIDER, 0.6, 2.5, 1.3),
			mkrow (@"120 Hz (ProMotion)", @"refresh120", ROW_SWITCH, 0, 1, 1),
		],
		@[
			mkrow (@"Button Size", @"touchSize", ROW_SLIDER, 0.6, 1.6, 1.0),
			mkrow (@"Button Opacity", @"touchOpacity", ROW_SLIDER, 0.2, 1.0, 0.8),
			mkrow (@"Lefty Layout", @"lefty", ROW_SWITCH, 0, 1, 0),
			mkrow (@"Fire Haptics", @"haptics", ROW_SWITCH, 0, 1, 1),
		],
		@[
			mkrow (@"Always Run", @"alwaysRun", ROW_SWITCH, 0, 1, 1),
			mkrow (@"FPS Counter", @"fps", ROW_SWITCH, 0, 1, 0),
		],
	];
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
	if (r.type == ROW_BUTTON)
	{
		c.textLabel.textColor = [UIColor colorWithRed:0.4 green:0.8 blue:1.0 alpha:1];
		c.selectionStyle = UITableViewCellSelectionStyleDefault;
		return c;
	}
#ifdef VKQ_VISIONOS
	if (r.type == ROW_SEG)
	{
		UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[ @"m", @"ft" ]];
		seg.selectedSegmentIndex = v > 0.5f ? 1 : 0;
		tag_ctl (seg, r);
		[seg addTarget:self action:@selector (segChanged:) forControlEvents:UIControlEventValueChanged];
		c.accessoryView = seg;
		return c;
	}
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
		sw.onTintColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.2 alpha:1];
		tag_ctl (sw, r);
		[sw addTarget:self action:@selector (switchChanged:) forControlEvents:UIControlEventValueChanged];
		c.accessoryView = sw;
	}
	else
	{
#ifdef VKQ_VISIONOS
		// Wider slider + live value readout (m/ft honoring the units toggle).
		const CGFloat labelW = 84, sliderW = 360, gap = 8;
		UIView	 *box = [[UIView alloc] initWithFrame:CGRectMake (0, 0, sliderW + gap + labelW, 34)];
		UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake (0, 2, sliderW, 30)];
		UILabel	 *val = [[UILabel alloc] initWithFrame:CGRectMake (sliderW + gap, 2, labelW, 30)];
		val.textColor = [UIColor colorWithWhite:0.85 alpha:1];
		val.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightMedium];
		val.textAlignment = NSTextAlignmentRight;
		val.text = [r.key hasPrefix:@"vp3d"] ? vkq_vp3d_value_text (r.key, v) : [NSString stringWithFormat:@"%.1f", v];
		objc_setAssociatedObject (sl, "vkq_val_label", val, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[box addSubview:sl];
		[box addSubview:val];
#else
		UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake (0, 0, 190, 30)];
#endif
		sl.minimumValue = r.mn;
		sl.maximumValue = r.mx;
		sl.value = v;
		sl.minimumTrackTintColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.2 alpha:1];
		tag_ctl (sl, r);
		[sl addTarget:self action:@selector (sliderChanged:) forControlEvents:UIControlEventValueChanged];
		[sl addTarget:self action:@selector (sliderReleased:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
#ifdef VKQ_VISIONOS
		c.accessoryView = box;
#else
		c.accessoryView = sl;
#endif
	}
	return c;
}

#ifdef VKQ_VISIONOS
- (void)segChanged:(UISegmentedControl *)seg
{
	vkq_setting_set_f (ctl_key (seg), seg.selectedSegmentIndex > 0 ? 1.0f : 0.0f);
	VKQ_iOS_ApplySettingsToEngine ();
	[self.tableView reloadData]; // every value label changes with the units
}
#endif

- (void)switchChanged:(UISwitch *)sw
{
	vkq_setting_set_f (ctl_key (sw), sw.on ? 1.0f : 0.0f);
	VKQ_iOS_ApplySettingsToEngine ();
}

#ifdef VKQ_VISIONOS
// Custom header views get a COMPRESSED height without an explicit delegate —
// which shoved "Vision Pro 3D"/Reset up under the sheet's Settings bar.
- (CGFloat)tableView:(UITableView *)t heightForHeaderInSection:(NSInteger)s
{
	return s == 0 ? 72.0 : UITableViewAutomaticDimension;
}

// "Vision Pro 3D" header carries the Reset control (the maintainer's layout).
- (UIView *)tableView:(UITableView *)t viewForHeaderInSection:(NSInteger)s
{
	if (s != 0)
		return nil;
	// Tall header with a REAL bordered Reset button — the bare-text version sat
	// tight under the sheet's Settings bar and was nearly impossible to gaze-pinch.
	UIView	*hv = [[UIView alloc] initWithFrame:CGRectMake (0, 0, t.bounds.size.width, 64)];
	UILabel *l = [UILabel new];
	l.text = @"Vision Pro 3D";
	l.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
	l.textColor = UIColor.labelColor;
	l.translatesAutoresizingMaskIntoConstraints = NO;
	UIButton *reset;
	UIButtonConfiguration *cfg = [UIButtonConfiguration tintedButtonConfiguration];
	cfg.title = @"Reset";
	cfg.contentInsets = NSDirectionalEdgeInsetsMake (10, 22, 10, 22);
	reset = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
	reset.translatesAutoresizingMaskIntoConstraints = NO;
	[reset addTarget:self action:@selector (resetVision3D) forControlEvents:UIControlEventTouchUpInside];
	[hv addSubview:l];
	[hv addSubview:reset];
	[NSLayoutConstraint activateConstraints:@[
		[l.leadingAnchor constraintEqualToAnchor:hv.leadingAnchor constant:20],
		[l.bottomAnchor constraintEqualToAnchor:hv.bottomAnchor constant:-6],
		[reset.trailingAnchor constraintEqualToAnchor:hv.trailingAnchor constant:-20],
		[reset.centerYAnchor constraintEqualToAnchor:l.centerYAnchor],
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
#endif

- (void)sliderChanged:(UISlider *)sl
{
	// overlay settings (sensitivity, touch size/opacity, gyro) are read live by the
	// overlay; engine cvars (menu size) are pushed on release to avoid flooding the
	// command buffer while dragging.
	vkq_setting_set_f (ctl_key (sl), sl.value);
#ifdef VKQ_VISIONOS
	// panel/stereo sliders are plain C state — safe (and delightful) to apply
	// live while dragging, with instant feedback on the 3D panel
	NSString *key = [NSString stringWithUTF8String:ctl_key (sl)];
	UILabel	 *val = objc_getAssociatedObject (sl, "vkq_val_label");
	if (val)
		val.text = [key hasPrefix:@"vp3d"] ? vkq_vp3d_value_text (key, sl.value) : [NSString stringWithFormat:@"%.1f", sl.value];
	if ([key hasPrefix:@"vp3d"])
		VKQ_iOS_Apply3DSettings ();
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
	// the small parked window — testing got stuck with only the window-close X,
	// which kills the scene and the audio session with it).
	return [[VKQSettingsVC alloc] initWithStyle:UITableViewStyleInsetGrouped];
}
#endif

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
		[root presentViewController:nav animated:YES completion:nil];
	});
}
