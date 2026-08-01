/*
 * ios_touch.m — UIKit touch overlay above SDL3's Metal view for vkQuake.
 *
 * Left region: a FLOATING virtual stick (touch-down sets the origin, released
 * on lift) → analog move. Right region: drag-to-look (no visible stick) →
 * view deltas. Buttons send engine commands (+attack, +jump, …). The overlay
 * hides itself whenever a menu/console is up so raw SDL touches drive the menu
 * (mouse emulation) and a back button appears.
 *
 * Everything runs on the main thread (UIKit events + the SDL display-link frame
 * both do), so the C bridge into the engine needs no locking.
 */
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <CoreMotion/CoreMotion.h>
#import <QuartzCore/QuartzCore.h>
#import "ios_audio.h"
#import "ios_settings.h"

// --- engine bridge (in_sdl.c, overlay patch 0004) ---
extern void VKQ_TouchMove (float fwd, float side);       // analog stick [-1,1]
extern void VKQ_TouchLook (float dyaw_deg, float dpitch_deg);
extern void VKQ_TouchKey (int key, int down);
extern void VKQ_TouchCommand (const char *text);
extern void SCR_WeaponWheel_TouchOpen (float nx, float ny); // engine weapon wheel (touch)
extern void SCR_WeaponWheel_TouchClose (void);
extern void SCR_WeaponWheel_SetAim (float x, float y);
extern int  VKQ_TouchKeyDest (void);                     // 0 = in-game
extern int  VKQ_TouchInGame (void);                      // real game (not demo/menu)
extern int  VKQ_TouchIsDemo (void);                      // attract/demo playback
extern int  VKQ_HasActiveController (void);              // engine has an open gamepad
extern void VKQ_iOS_EngineFrame (void);                  // engine frame (driven by our CADisplayLink)
extern void VKQ_iOS_ConsoleBridgeStart (void);           // TCP remote console (opt-in via env)
extern void VKQ_iOS_ConsoleBridgeDrain (void);           // per-frame: feed commands / stream output
extern void VKQ_iOS_OnboardingDismiss (void);            // hide the onboarding "Loading…" once the game draws

#define K_ESCAPE 27
#define K_ABUTTON 211 // controller A — SCR_ModalMessage treats it as "yes"

#define STICK_RADIUS 62.0f     // move stick: thumb travel for full deflection
#define LOOK_DEG_PER_PT 0.22f  // drag-to-look base sensitivity

static float look_accel (float d)
{
	// gentle velocity boost so deliberate flicks turn faster than slow tracking
	float boost = 1.0f + fabsf (d) / 28.0f;
	return d * (boost > 2.4f ? 2.4f : boost);
}

// The move stick is FLOATING: it materialises wherever your thumb lands inside
// its activation zone and vanishes on release. So the stick has no fixed
// position — what it has is a zone, and that zone is draggable like everything
// else. The default is a circle covering roughly the old left half, so the feel
// is unchanged: a generous target you cannot really miss.
//
// This replaces the old Lefty Layout toggle outright. Handedness was never the
// real axis — gamepads have no left/right-handed layouts because both thumbs are
// engaged at once, and a left-handed player aims with the right thumb just fine.
// What people actually want is the stick somewhere else, which dragging gives
// you at any position, not just mirrored.
#define STICK_ZONE_DIAMETER 300.0f

// ---------------------------------------------------------------------------
@interface VKQButton : UIView
@property (nonatomic, copy) NSString *downCmd; // executed on press (nil = none)
@property (nonatomic, copy) NSString *upCmd;   // executed on release (nil = none)
@property (nonatomic, copy) NSString *ident;   // stable id — key for the saved position
@property (nonatomic) int keyCode;             // key event on press/release (0 = none)
@property (nonatomic) BOOL haptic;
@property (nonatomic) BOOL settingsButton;     // opens the native settings panel
@property (nonatomic) BOOL engineWheel; // opens the engine weapon wheel (hold + drag)
@property (nonatomic) BOOL zoneOnly;    // not a button — the move-stick activation zone
@property (nonatomic) CGPoint unit;            // effective placement, 0..1 of safe area
@property (nonatomic) CGPoint defaultUnit;     // shipped placement, for Reset
@property (nonatomic) CGFloat baseSize;
@property (nonatomic, weak) UITouch *touch;
@end
@implementation VKQButton @end

// Saved position keys: vkq.btn.<ident>.x / .y, alongside vkq.layoutSet which
// records whether the user has customised anything at all.
static NSString *vkq_btn_key (NSString *ident, const char *axis) { return [NSString stringWithFormat:@"btn.%@.%s", ident, axis]; }

// ---------------------------------------------------------------------------
@interface VKQTouchView : UIView
- (void)applyAppearance:(CGFloat)scale opacity:(CGFloat)op;
- (void)reloadButtonPositions;
- (NSArray<VKQButton *> *)placeableButtons;
- (void)seedMirroredLayoutForLegacyLefty;
- (BOOL)isEditingLayout;
- (BOOL)pointInMoveZone:(CGPoint)p;
- (void)beginEditingLayout;
- (void)endEditingLayout;
- (void)resetLayoutToDefaults;
// Edit-mode drag, factored so the real finger path and the synthetic finger
// (vkq_faketouch) drive exactly the same code.
- (BOOL)editDragBegin:(CGPoint)p;
- (void)editDragMove:(CGPoint)p;
- (void)editDragEnd;
@end

@implementation VKQTouchView {
	UITouch *moveTouch, *lookTouch;
	CGPoint	 moveOrigin, lastLook;
	UIView	*stickBase, *stickNub;
	VKQButton					*stickZone; // move-stick activation zone (draggable, drawn only in the editor)
	NSMutableArray<VKQButton *> *buttons;
#ifdef VKQ_VISIONOS
	id haptics; // UIImpactFeedbackGenerator is unavailable on visionOS (no haptics)
#else
	UIImpactFeedbackGenerator   *haptics;
#endif
	UITouch						*wheelTouch;		// touch driving the engine weapon wheel
	CGPoint						 engineWheelCenter; // wheel-button centre, in this view's coords
	// layout edit mode
	BOOL	   _editing;
	VKQButton *_dragBtn;   // button under the editing finger
	CGSize	   _dragOffset; // finger -> button centre, so it doesn't jump on grab
	UIView	  *_editBar;
	UISlider  *_editSlider;
	UILabel	  *_editPct;
}

- (instancetype)initWithFrame:(CGRect)frame
{
	if (!(self = [super initWithFrame:frame]))
		return nil;
	self.multipleTouchEnabled = YES;
	self.backgroundColor = UIColor.clearColor;
	self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	stickBase = [self circle:128 alpha:0.16];
	stickNub = [self circle:56 alpha:0.28];
	stickBase.hidden = stickNub.hidden = YES;
	buttons = [NSMutableArray array];
#ifndef VKQ_VISIONOS
	haptics = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
#endif
	return self;
}

- (UIView *)circle:(CGFloat)size alpha:(CGFloat)alpha
{
	UIView *v = [[UIView alloc] initWithFrame:CGRectMake (0, 0, size, size)];
	v.backgroundColor = [UIColor colorWithWhite:1 alpha:alpha];
	v.layer.cornerRadius = size / 2;
	v.layer.borderWidth = 1.5;
	v.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
	v.userInteractionEnabled = NO;
	[self addSubview:v];
	return v;
}

- (VKQButton *)addButton:(NSString *)label ident:(NSString *)ident size:(CGFloat)size at:(CGPoint)unit
{
	VKQButton *b = [[VKQButton alloc] initWithFrame:CGRectMake (0, 0, size, size)];
	b.ident = ident;
	b.defaultUnit = unit;
	b.unit = unit; // reloadButtonPositions overrides from saved settings
	b.baseSize = size;
	b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
	b.layer.cornerRadius = size / 2;
	b.layer.borderWidth = 1.5;
	b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
	b.userInteractionEnabled = NO;

	UILabel *l = [[UILabel alloc] initWithFrame:b.bounds];
	l.text = label;
	l.textAlignment = NSTextAlignmentCenter;
	l.font = [UIFont boldSystemFontOfSize:size * 0.28];
	l.textColor = [UIColor colorWithWhite:1 alpha:0.7];
	l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[b addSubview:l];

	[buttons addObject:b];
	[self addSubview:b];
	if ([ident isEqualToString:@"stick"])
		stickZone = b;
	return b;
}

// Effective position for every button: the saved one if the layout has been
// customised, otherwise the shipped default. Called at build time and whenever
// the editor writes or resets a position.
- (void)reloadButtonPositions
{
	BOOL custom = vkq_setting_f ("layoutSet", 0.0f) > 0.5f;
	for (VKQButton *b in buttons)
	{
		if (custom)
			b.unit = CGPointMake (vkq_setting_f (vkq_btn_key (b.ident, "x").UTF8String, b.defaultUnit.x),
								  vkq_setting_f (vkq_btn_key (b.ident, "y").UTF8String, b.defaultUnit.y));
		else
			b.unit = b.defaultUnit;
	}
	[self setNeedsLayout];
}

// Legacy Lefty Layout mirrored button x at layout time. Bake that mirror into
// saved positions so the migration is invisible to the player.
- (void)seedMirroredLayoutForLegacyLefty
{
	for (VKQButton *b in buttons)
	{
		vkq_setting_set_f (vkq_btn_key (b.ident, "x").UTF8String, 1.0f - b.defaultUnit.x);
		vkq_setting_set_f (vkq_btn_key (b.ident, "y").UTF8String, b.defaultUnit.y);
	}
	vkq_setting_set_f ("layoutSet", 1.0f);
}

- (NSArray<VKQButton *> *)placeableButtons { return buttons; }

- (void)resetLayoutToDefaults
{
	vkq_setting_set_f ("layoutSet", 0.0f);
	for (VKQButton *b in buttons)
	{
		vkq_setting_set_f (vkq_btn_key (b.ident, "x").UTF8String, b.defaultUnit.x);
		vkq_setting_set_f (vkq_btn_key (b.ident, "y").UTF8String, b.defaultUnit.y);
	}
	[self reloadButtonPositions];
}

- (void)layoutSubviews
{
	[super layoutSubviews];
	CGRect r = UIEdgeInsetsInsetRect (self.bounds, self.safeAreaInsets);
	for (VKQButton *b in buttons)
	{
		// No lefty mirroring here any more — the editor owns button placement.
		b.center = CGPointMake (r.origin.x + r.size.width * b.unit.x, r.origin.y + r.size.height * b.unit.y);
	}
	if (_editing)
		[self centerStickGraphicOnZone]; // follows the zone through relayouts
}

- (VKQButton *)buttonAt:(CGPoint)p
{
	for (VKQButton *b in buttons)
	{
		if (b.zoneOnly)
			continue; // the stick zone is not pressable — only draggable in the editor
		CGFloat dx = p.x - b.center.x, dy = p.y - b.center.y;
		CGFloat hit = b.bounds.size.width * 0.5 * 1.3; // generous hit circle
		if (dx * dx + dy * dy <= hit * hit)
			return b;
	}
	return nil;
}

// Edit mode grabs anything placeable, the stick zone included. Smallest-first so
// a small button sitting inside the big stick circle stays grabbable.
- (VKQButton *)placeableAt:(CGPoint)p
{
	VKQButton *best = nil;
	for (VKQButton *b in buttons)
	{
		CGFloat dx = p.x - b.center.x, dy = p.y - b.center.y;
		CGFloat hit = b.bounds.size.width * 0.5 * (b.zoneOnly ? 1.0 : 1.3);
		if (dx * dx + dy * dy <= hit * hit && (!best || b.bounds.size.width < best.bounds.size.width))
			best = b;
	}
	return best;
}

- (BOOL)pointInMoveZone:(CGPoint)p
{
	if (!stickZone)
		return p.x < self.bounds.size.width * 0.5f; // pre-build fallback
	CGFloat dx = p.x - stickZone.center.x, dy = p.y - stickZone.center.y;
	CGFloat r = stickZone.bounds.size.width * 0.5f;
	return dx * dx + dy * dy <= r * r;
}

// ---- layout edit mode ------------------------------------------------------
- (BOOL)isEditingLayout { return _editing; }

- (BOOL)editDragBegin:(CGPoint)p
{
	_dragBtn = [self placeableAt:p];
	if (!_dragBtn)
		return NO;
	_dragOffset = CGSizeMake (_dragBtn.center.x - p.x, _dragBtn.center.y - p.y);
	_dragBtn.backgroundColor = [UIColor colorWithRed:1 green:0.85 blue:0.4 alpha:0.45];
	return YES;
}

- (void)editDragMove:(CGPoint)p
{
	if (!_dragBtn)
		return;
	// Only constraint: the CENTRE stays on screen, so anything you place can
	// always be grabbed again. Deliberately not the safe rect and not inset by the
	// radius — that was far too strict, and it refused to let buttons reach the
	// edges they already ship at. Overshoot is cheap here; Reset is right there.
	CGFloat cx = fmax (0, fmin (self.bounds.size.width, p.x + _dragOffset.width));
	CGFloat cy = fmax (0, fmin (self.bounds.size.height, p.y + _dragOffset.height));
	_dragBtn.center = CGPointMake (cx, cy);
	if (_dragBtn == stickZone)
		[self centerStickGraphicOnZone];
}

- (void)editDragEnd
{
	if (!_dragBtn)
		return;
	CGRect r = UIEdgeInsetsInsetRect (self.bounds, self.safeAreaInsets);
	if (r.size.width > 0 && r.size.height > 0)
	{
		CGPoint u = CGPointMake ((_dragBtn.center.x - r.origin.x) / r.size.width, (_dragBtn.center.y - r.origin.y) / r.size.height);
		_dragBtn.unit = u;
		vkq_setting_set_f (vkq_btn_key (_dragBtn.ident, "x").UTF8String, u.x);
		vkq_setting_set_f (vkq_btn_key (_dragBtn.ident, "y").UTF8String, u.y);
		vkq_setting_set_f ("layoutSet", 1.0f);
		NSLog (@"[vkquake] layout: %@ -> (%.3f, %.3f)", _dragBtn.ident, u.x, u.y);
	}
	_dragBtn.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
	_dragBtn = nil;
}

- (void)beginEditingLayout
{
	if (_editing)
		return;
	_editing = YES;
	// Drop anything mid-press so a held button doesn't stick down for the whole
	// edit session, and so the engine isn't left with +attack asserted.
	[self releaseAllInput];
	for (VKQButton *b in buttons)
		b.layer.borderColor = [UIColor colorWithRed:1 green:0.85 blue:0.4 alpha:0.95].CGColor;
	// Reveal the move-stick zone, drawn at its true radius so what you drag is
	// exactly the region that will respond — with the stick itself parked in the
	// middle of it, so the circle obviously belongs to the stick.
	stickZone.hidden = NO;
	stickZone.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
	stickZone.layer.borderColor = [UIColor colorWithRed:1 green:0.85 blue:0.4 alpha:0.35].CGColor;
	stickZone.layer.borderWidth = 2.0;
	[self sendSubviewToBack:stickZone]; // never cover a button you want to grab
	stickBase.hidden = stickNub.hidden = NO;
	[self centerStickGraphicOnZone];

	// Chrome: reset · live scale slider · done, bottom-left (Shipwright's layout).
	// No instruction text — dragging a button is self-evident once you are here.
	UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
	bar.backgroundColor = UIColor.clearColor;
	bar.translatesAutoresizingMaskIntoConstraints = NO;
	[self addSubview:bar];
	_editBar = bar;

	UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
	reset.backgroundColor = [UIColor colorWithRed:0.85 green:0.20 blue:0.22 alpha:0.95];
	[reset setImage:[[UIImage systemImageNamed:@"arrow.uturn.backward"]
						imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17
																							   weight:UIImageSymbolWeightBold]]
		   forState:UIControlStateNormal];
	reset.tintColor = UIColor.whiteColor;
	reset.layer.cornerRadius = 21;
	[reset addTarget:self action:@selector (editResetTapped) forControlEvents:UIControlEventTouchUpInside];

	UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
	done.backgroundColor = [UIColor colorWithRed:0.18 green:0.78 blue:0.34 alpha:0.95];
	[done setImage:[[UIImage systemImageNamed:@"checkmark"]
					   imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20
																							  weight:UIImageSymbolWeightBold]]
		  forState:UIControlStateNormal];
	done.tintColor = UIColor.whiteColor;
	done.layer.cornerRadius = 21;
	[done addTarget:self action:@selector (endEditingLayout) forControlEvents:UIControlEventTouchUpInside];

	UISlider *sl = [UISlider new];
	sl.minimumValue = 0.6f;
	sl.maximumValue = 1.6f;
	sl.value = vkq_setting_f ("touchSize", 1.0f);
	sl.minimumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.9];
	[sl addTarget:self action:@selector (editScaleChanged:) forControlEvents:UIControlEventValueChanged];
	_editSlider = sl;

	UILabel *pct = [UILabel new];
	pct.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
	pct.textColor = [UIColor colorWithWhite:1 alpha:0.9];
	pct.textAlignment = NSTextAlignmentCenter;
	_editPct = pct;
	[self updateScaleLabel];

	for (UIView *v in @[ reset, done, sl, pct ])
	{
		v.translatesAutoresizingMaskIntoConstraints = NO;
		[bar addSubview:v];
	}
	[NSLayoutConstraint activateConstraints:@[
		[bar.leadingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.leadingAnchor constant:14],
		[bar.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor constant:-14],
		[bar.heightAnchor constraintEqualToConstant:42],
		[bar.trailingAnchor constraintEqualToAnchor:done.trailingAnchor],

		[reset.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
		[reset.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
		[reset.widthAnchor constraintEqualToConstant:42],
		[reset.heightAnchor constraintEqualToConstant:42],

		[sl.leadingAnchor constraintEqualToAnchor:reset.trailingAnchor constant:16],
		[sl.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
		[sl.widthAnchor constraintEqualToConstant:220],

		[pct.centerXAnchor constraintEqualToAnchor:sl.centerXAnchor],
		[pct.bottomAnchor constraintEqualToAnchor:sl.topAnchor constant:-2],

		[done.leadingAnchor constraintEqualToAnchor:sl.trailingAnchor constant:16],
		[done.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
		[done.widthAnchor constraintEqualToConstant:42],
		[done.heightAnchor constraintEqualToConstant:42],
	]];
	NSLog (@"[vkquake] touch layout editor entered");
}

- (void)updateScaleLabel { _editPct.text = [NSString stringWithFormat:@"%.0f%%", vkq_setting_f ("touchSize", 1.0f) * 100.0f]; }

// Live scale: write the same setting the old Button Size row wrote, then apply
// immediately so the buttons resize under the finger.
- (void)editScaleChanged:(UISlider *)s
{
	vkq_setting_set_f ("touchSize", s.value);
	[self applyAppearance:s.value opacity:vkq_setting_f ("touchOpacity", 0.8f)];
	[self updateScaleLabel];
	[self centerStickGraphicOnZone];
}

// Park the floating stick graphic in the middle of its zone while editing, so
// the circle reads as the stick's, not as some anonymous region.
- (void)centerStickGraphicOnZone
{
	if (!stickZone)
		return;
	stickBase.center = stickNub.center = stickZone.center;
}

- (void)editResetTapped
{
	vkq_setting_set_f ("touchSize", 1.0f); // scale is part of the layout now
	[self resetLayoutToDefaults];
	[self applyAppearance:1.0f opacity:vkq_setting_f ("touchOpacity", 0.8f)];
	_editSlider.value = 1.0f;
	[self updateScaleLabel];
	[self centerStickGraphicOnZone];
	NSLog (@"[vkquake] touch layout reset to defaults");
}

- (void)endEditingLayout
{
	if (!_editing)
		return;
	[self editDragEnd]; // commit anything still under the finger
	_editing = NO;
	for (VKQButton *b in buttons)
		b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
	stickZone.hidden = YES; // invisible in play — the stick floats to your thumb
	stickBase.hidden = stickNub.hidden = YES;
	[_editBar removeFromSuperview];
	_editBar = nil;
	_editSlider = nil;
	_editPct = nil;
	NSLog (@"[vkquake] touch layout editor exited");
}

// Release every in-flight input so entering edit mode (or losing the overlay)
// never leaves a key or button asserted in the engine.
- (void)releaseAllInput
{
	if (wheelTouch)
	{
		SCR_WeaponWheel_TouchClose ();
		wheelTouch = nil;
	}
	moveTouch = nil;
	lookTouch = nil;
	stickBase.hidden = stickNub.hidden = YES;
	VKQ_TouchMove (0, 0);
	for (VKQButton *b in buttons)
		if (b.touch)
		{
			b.touch = nil;
			b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
			if (b.keyCode)
				VKQ_TouchKey (b.keyCode, 0);
			if (b.upCmd)
				VKQ_TouchCommand (b.upCmd.UTF8String);
		}
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	if (_editing)
	{
		[self editDragBegin:[touches.anyObject locationInView:self]];
		return;
	}
	for (UITouch *t in touches)
	{
		CGPoint	   p = [t locationInView:self];
		VKQButton *b = [self buttonAt:p];
		if (b && !b.touch)
		{
			b.touch = t;
			b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.32];
			if (b.engineWheel && !wheelTouch)
			{
				wheelTouch = t;
				engineWheelCenter = b.center; // this view's coords
				CGSize sz = self.bounds.size;
				SCR_WeaponWheel_TouchOpen (engineWheelCenter.x / sz.width, engineWheelCenter.y / sz.height);
#ifndef VKQ_VISIONOS
				if (vkq_setting_f ("haptics", 1.0f) > 0.5f)
					[haptics impactOccurred];
#endif
				continue;
			}
			if (b.settingsButton)
				VKQ_iOS_PresentSettings ();
			if (b.keyCode)
				VKQ_TouchKey (b.keyCode, 1);
			if (b.downCmd)
				VKQ_TouchCommand (b.downCmd.UTF8String);
#ifndef VKQ_VISIONOS
			if (b.haptic && vkq_setting_f ("haptics", 1.0f) > 0.5f)
				[haptics impactOccurred];
#endif
			continue;
		}
		// move-stick zone: the draggable circle (default ~ the old left half)
		BOOL inMoveZone = [self pointInMoveZone:p];
		if (inMoveZone && !moveTouch)
		{
			moveTouch = t;
			moveOrigin = p;
			stickBase.center = stickNub.center = p;
			stickBase.hidden = stickNub.hidden = NO;
		}
		else if (!lookTouch)
		{
			lookTouch = t;
			lastLook = p;
		}
	}
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	if (_editing)
	{
		[self editDragMove:[touches.anyObject locationInView:self]];
		return;
	}
	for (UITouch *t in touches)
	{
		// predicted touch cancels the frame of lag from the engine holding the main thread
		UITouch *pred = [[event predictedTouchesForTouch:t] lastObject];
		CGPoint	 p = [(pred ?: t) locationInView:self];
		if (t == wheelTouch)
		{
			const CGFloat R = 95.0f; // points of drag for full deflection (up == -y matches the wheel)
			SCR_WeaponWheel_SetAim ((p.x - engineWheelCenter.x) / R, (p.y - engineWheelCenter.y) / R);
			continue;
		}
		if (t == moveTouch)
		{
			CGFloat dx = p.x - moveOrigin.x, dy = p.y - moveOrigin.y;
			CGFloat len = sqrtf (dx * dx + dy * dy);
			if (len > STICK_RADIUS)
			{
				dx *= STICK_RADIUS / len;
				dy *= STICK_RADIUS / len;
			}
			stickNub.center = CGPointMake (moveOrigin.x + dx, moveOrigin.y + dy);
			VKQ_TouchMove (-dy / STICK_RADIUS, dx / STICK_RADIUS); // -dy: screen-down is back
		}
		else if (t == lookTouch)
		{
			float dx = look_accel (p.x - lastLook.x);
			float dy = look_accel (p.y - lastLook.y);
			lastLook = p;
			float sh = vkq_setting_f ("sensH", 1.0f);
			float sv = vkq_setting_f ("sensV", 1.0f);
			float inv = vkq_setting_f ("invert", 0.0f) > 0.5f ? -1.0f : 1.0f;
			// drag right -> turn right; finger up -> look up (unless inverted)
			VKQ_TouchLook (dx * LOOK_DEG_PER_PT * sh, inv * dy * LOOK_DEG_PER_PT * sv);
		}
	}
}

- (void)endTouches:(NSSet<UITouch *> *)touches
{
	if (_editing)
	{
		[self editDragEnd];
		return;
	}
	for (UITouch *t in touches)
	{
		if (t == wheelTouch)
		{
			SCR_WeaponWheel_TouchClose (); // switches to the selected weapon
			wheelTouch = nil;
			for (VKQButton *b in buttons)
				if (b.touch == t)
				{
					b.touch = nil;
					b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
				}
			continue;
		}
		if (t == moveTouch)
		{
			moveTouch = nil;
			stickBase.hidden = stickNub.hidden = YES;
			VKQ_TouchMove (0, 0);
		}
		else if (t == lookTouch)
			lookTouch = nil;
		for (VKQButton *b in buttons)
			if (b.touch == t)
			{
				b.touch = nil;
				b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
				if (b.keyCode)
					VKQ_TouchKey (b.keyCode, 0);
				if (b.upCmd)
					VKQ_TouchCommand (b.upCmd.UTF8String);
			}
	}
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self endTouches:touches]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self endTouches:touches]; }

- (void)applyAppearance:(CGFloat)scale opacity:(CGFloat)op
{
	self.alpha = op;
	// The scale slider lives in the editor now, where its effect is visible live —
	// including on the move zone, which resizes with everything else. (It was
	// excluded while the control was a blind settings row.)
	for (VKQButton *b in buttons)
	{
		CGFloat sz = b.baseSize * scale;
		b.bounds = CGRectMake (0, 0, sz, sz);
		b.layer.cornerRadius = sz / 2;
	}
	[self setNeedsLayout];
}
@end

// ---------------------------------------------------------------------------
// Set by VKQHostViewController (visionOS) while the stereoscopic immersive space
// is open; always 0 on iOS. Gates the scene-deactivate render pause below.
int vkq3d_immersive_on = 0;

static VKQTouchView *g_touch;

// The GAME window (the one whose swapchain freezes in 3D) — for shell overlays
// that must land on it (the 3D curtain). "The key window" is a guess that can
// pick a SwiftUI ornament/sheet hosting window on visionOS.
UIWindow *VKQ_iOS_GameWindow (void)
{
	return (UIWindow *)g_touch.superview;
}
static UIButton		*g_back;
static UIButton		*g_settings; // menu-only iOS settings button (shown with the back button)
static UIButton		*g_qsave, *g_qload; // main-menu-only quick save / quick load
static UIView		*g_catcher;	 // transparent; a tap during the attract demo opens the menu
static UIButton		*g_kbdismiss; // dismiss-keyboard (checkmark) button, shown while the keyboard is up

static UIWindow *vkq_key_window (void); // defined below

// --- native keyboard -------------------------------------------------------
// vkQuake uses a NATIVE UIKeyInput responder (like q2repro / quake3e), NOT SDL's
// soft keyboard. SDL's keyboard was a persistent source of bugs on this hardware:
// backspace gated behind SDL_HasKeyboard() (a connected controller made it true),
// and its touch->mouse synthesis (gated by SDL_HasMouse()) froze the menu cursor.
// Here the engine calls VKQ_iOS_SetTextActive() when a text field / console opens;
// the input view below becomes first responder, iOS shows the keyboard, and key
// presses feed straight back to the engine via VKQ_TouchChar / VKQ_TouchKey. The
// view still slides up (via SDL's text-input rect) and a Dismiss button + 3-finger
// tap toggle it.
extern void VKQ_iOS_SetTextInputRect (int x, int y, int w, int h);
extern void VKQ_TouchChar (int c);
static BOOL g_kb_visible;
// how far up to slide, as a fraction of the keyboard height (1.0 = clear it fully)
#define VKQ_KB_SHIFT_FRAC 0.28f
#define VKQ_K_BACKSPACE 127
#define VKQ_K_ENTER 13

// First-responder view that owns the keyboard and turns key presses into engine input.
@interface VKQKeyInput : UIView <UIKeyInput>
@end
@implementation VKQKeyInput
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)hasText { return YES; }
- (UIKeyboardType)keyboardType { return UIKeyboardTypeASCIICapable; }
- (UITextAutocorrectionType)autocorrectionType { return UITextAutocorrectionTypeNo; }
- (UITextAutocapitalizationType)autocapitalizationType { return UITextAutocapitalizationTypeNone; }
- (UITextSmartQuotesType)smartQuotesType { return UITextSmartQuotesTypeNo; }
- (UITextSmartDashesType)smartDashesType { return UITextSmartDashesTypeNo; }
- (UIKeyboardAppearance)keyboardAppearance { return UIKeyboardAppearanceDark; }
- (void)insertText:(NSString *)text
{
	for (NSUInteger i = 0; i < text.length; i++)
	{
		unichar c = [text characterAtIndex:i];
		if (c == '\n' || c == '\r')
		{
			VKQ_TouchKey (VKQ_K_ENTER, 1);
			VKQ_TouchKey (VKQ_K_ENTER, 0);
		}
		else if (c < 128)
			VKQ_TouchChar ((int)c);
	}
}
- (void)deleteBackward
{
	VKQ_TouchKey (VKQ_K_BACKSPACE, 1);
	VKQ_TouchKey (VKQ_K_BACKSPACE, 0);
}
@end
static VKQKeyInput *g_kbinput;

// Engine -> shell (in_sdl.c): a text field / console became active or inactive.
// Focus / unfocus the input responder on the main thread to show / hide the keyboard.
void VKQ_iOS_SetTextActive (int active)
{
	dispatch_async (dispatch_get_main_queue (), ^{
		if (!g_kbinput)
			return;
		if (active)
			[g_kbinput becomeFirstResponder];
		else
			[g_kbinput resignFirstResponder];
	});
}

@interface VKQKeyboard : NSObject
@end
@implementation VKQKeyboard
- (void)willShow:(NSNotification *)n
{
	UIWindow *win = vkq_key_window ();
	if (!win)
		return;
	CGRect	kb = [win convertRect:[n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue] fromWindow:nil];
	CGFloat h = kb.size.height;
	if (h < 1)
		return;
	g_kb_visible = YES;

	// SDL shifts up by (rectBottom - keyboardTop); place rectBottom a fraction of
	// the keyboard height below the keyboard top so the shift is only that fraction.
	CGFloat winH = win.bounds.size.height;
	CGFloat kbTop = winH - h;
	CGFloat rectBottom = kbTop + h * VKQ_KB_SHIFT_FRAC;
	int		rh = 24;
	VKQ_iOS_SetTextInputRect (0, (int)(rectBottom - rh), (int)win.bounds.size.width, rh);

	if (!g_kbdismiss)
	{
		g_kbdismiss = [UIButton buttonWithType:UIButtonTypeSystem];
		UIImage *img = [[UIImage systemImageNamed:@"keyboard.chevron.compact.down.fill"]
			imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightBold]];
		if (!img)
			img = [[UIImage systemImageNamed:@"checkmark"]
				imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightBold]];
		[g_kbdismiss setImage:img forState:UIControlStateNormal];
		g_kbdismiss.tintColor = [UIColor colorWithWhite:1 alpha:0.95];
		g_kbdismiss.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
		g_kbdismiss.layer.cornerRadius = 10;
		[g_kbdismiss addTarget:self action:@selector (dismiss) forControlEvents:UIControlEventTouchUpInside];
		[win addSubview:g_kbdismiss];
	}
	CGFloat sz = 50, ktop = win.bounds.size.height - h;
	g_kbdismiss.frame = CGRectMake (win.bounds.size.width - MAX (win.safeAreaInsets.right, 8.0) - sz - 8, ktop - sz - 8, sz, sz);
	g_kbdismiss.hidden = NO;
	[win bringSubviewToFront:g_kbdismiss];
}
- (void)willHide:(NSNotification *)n
{
	g_kb_visible = NO;
	g_kbdismiss.hidden = YES;
}
- (void)dismiss
{
	[g_kbinput resignFirstResponder]; // hide the native keyboard
}
// 3-finger tap: toggle the keyboard (re-summon after a Dismiss, or hide it)
- (void)threeFingerTap:(UITapGestureRecognizer *)g
{
	if (g_kb_visible)
		[g_kbinput resignFirstResponder];
	else
		[g_kbinput becomeFirstResponder];
}
@end
static VKQKeyboard *g_keyboard;

// --- ProMotion-aware frame driver (our own CADisplayLink, so we can request 120) ---
@interface VKQFrameDriver : NSObject
@end
@implementation VKQFrameDriver
- (void)tick:(CADisplayLink *)l
{
	static int firstframes = 0;
	VKQ_iOS_ConsoleBridgeDrain ();
	VKQ_iOS_EngineFrame ();
	if (firstframes < 3 && ++firstframes == 2)
		VKQ_iOS_OnboardingDismiss (); // reveal the game once it has actually drawn
}
@end
static VKQFrameDriver *g_driver;
static CADisplayLink  *g_link;

// UIScreen is unavailable on visionOS; the compositor runs ~90 Hz there.
static float vkq_display_max_fps (void)
{
#ifdef VKQ_VISIONOS
	return 90.0f;
#else
	return (float)UIScreen.mainScreen.maximumFramesPerSecond; // 120 on ProMotion
#endif
}

static void vkq_apply_refresh (void)
{
	if (!g_link)
		return;
	float maxfps = vkq_display_max_fps ();
	BOOL  want120 = vkq_setting_f ("refresh120", 1.0f) > 0.5f;
	float top = want120 ? maxfps : 60.0f;
	// preferred = max so iOS grants the full rate; min lets it ease down under load
	g_link.preferredFrameRateRange = CAFrameRateRangeMake (fminf (60.0f, top), top, top);
}

void VKQ_iOS_SetRefresh (void) { vkq_apply_refresh (); }

void VKQ_iOS_StartFrameLoop (void)
{
	dispatch_async (dispatch_get_main_queue (), ^{
		if (g_link)
			return;
		g_driver = [VKQFrameDriver new];
		g_link = [CADisplayLink displayLinkWithTarget:g_driver selector:@selector (tick:)];
		vkq_apply_refresh ();
		[g_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
		NSLog (@"[vkquake] display link started (max %ld Hz)", (long)vkq_display_max_fps ());
	});
}

static UIWindow *vkq_key_window (void)
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

@interface VKQBack : NSObject
+ (void)press;
@end
@implementation VKQBack
+ (void)press
{
	VKQ_TouchKey (K_ESCAPE, 1);
	VKQ_TouchKey (K_ESCAPE, 0);
}
@end

@interface VKQSettingsBtn : NSObject
+ (void)press;
@end
@implementation VKQSettingsBtn
+ (void)press { VKQ_iOS_PresentSettings (); }
@end

// vkq_quicksave / vkq_quickload do the menu teardown the engine's own load path
// does, so both return straight to the game (see overlay patch 0013).
@interface VKQQuickSaveBtn : NSObject
+ (void)press;
@end
@implementation VKQQuickSaveBtn
+ (void)press { VKQ_TouchCommand ("vkq_quicksave\n"); }
@end
@interface VKQQuickLoadBtn : NSObject
+ (void)press;
@end
@implementation VKQQuickLoadBtn
+ (void)press { VKQ_TouchCommand ("vkq_quickload\n"); }
@end

// Labelled pill for the menu chrome column (glyph + caption).
static UIButton *vkq_menu_pill (NSString *symbol, NSString *title, Class target)
{
	UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
	cfg.image = [UIImage systemImageNamed:symbol];
	cfg.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:15
																							   weight:UIImageSymbolWeightBold];
	cfg.imagePadding = 6;
	cfg.contentInsets = NSDirectionalEdgeInsetsMake (6, 10, 6, 10);
	cfg.attributedTitle = [[NSAttributedString alloc]
		initWithString:title
			attributes:@{NSFontAttributeName : [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]}];
	UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
	b.tintColor = [UIColor colorWithWhite:1 alpha:0.9];
	b.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
	b.layer.cornerRadius = 10;
	b.frame = CGRectMake (0, 0, 148, 40);
	[b addTarget:target action:@selector (press) forControlEvents:UIControlEventTouchUpInside];
	b.hidden = YES;
	return b;
}

// -------- SCR_ModalMessage (y/n prompt) touch support --------
// The engine's SCR_ModalMessage spins a blocking do/while loop that starves the
// display link AND the UIKit run loop, so touches never arrive -> deadlock.
// The gl_screen.c patch calls ModalBegin/Pump/End around that loop: we show
// Yes/No buttons and manually pump the run loop so their taps get delivered.
static UIView *g_modal;

@interface VKQModal : NSObject
+ (void)yes;
+ (void)no;
@end
@implementation VKQModal
+ (void)yes { VKQ_TouchKey (K_ABUTTON, 1); VKQ_TouchKey (K_ABUTTON, 0); }
+ (void)no { VKQ_TouchKey (K_ESCAPE, 1); VKQ_TouchKey (K_ESCAPE, 0); }
@end

static UIButton *vkq_modal_button (NSString *title, CGPoint center, SEL action, UIColor *bg)
{
	UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
	[b setTitle:title forState:UIControlStateNormal];
	b.titleLabel.font = [UIFont boldSystemFontOfSize:24];
	[b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
	b.backgroundColor = bg;
	b.layer.cornerRadius = 14;
	b.frame = CGRectMake (0, 0, 150, 64);
	b.center = center;
	[b addTarget:VKQModal.class action:action forControlEvents:UIControlEventTouchUpInside];
	return b;
}

void VKQ_iOS_ModalBegin (const char *text)
{
	(void)text; // the engine has already drawn the prompt text into the framebuffer
	UIWindow *win = vkq_key_window ();
	if (!win || g_modal)
		return;
	g_modal = [[UIView alloc] initWithFrame:win.bounds];
	g_modal.backgroundColor = [UIColor colorWithWhite:0 alpha:0.25];
	g_modal.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	CGFloat cy = win.bounds.size.height * 0.70;
	CGFloat cx = win.bounds.size.width * 0.5;
	[g_modal addSubview:vkq_modal_button (@"YES", CGPointMake (cx - 105, cy), @selector (yes),
										  [UIColor colorWithRed:0.16 green:0.52 blue:0.20 alpha:0.92])];
	[g_modal addSubview:vkq_modal_button (@"NO", CGPointMake (cx + 105, cy), @selector (no),
										  [UIColor colorWithRed:0.55 green:0.16 blue:0.16 alpha:0.92])];
	[win addSubview:g_modal];
}

void VKQ_iOS_ModalPump (void)
{
	// Deliver queued UIKit touch events (the button taps) while the engine blocks.
	[[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.016]];
}

void VKQ_iOS_ModalEnd (void)
{
	[g_modal removeFromSuperview];
	g_modal = nil;
}

// ---------------------------------------------------------------------------
// Layout editor entry points, callable from the engine console and the iOS
// settings sheet. Everything here is main-thread: the console bridge runs
// commands through Cbuf on the engine's (main) thread, same as the display link.
void VKQ_iOS_ToggleLayoutEdit (void)
{
	if (!g_touch)
		return;
	if ([g_touch isEditingLayout])
		[g_touch endEditingLayout];
	else
		[g_touch beginEditingLayout];
}

void VKQ_iOS_ResetLayout (void)
{
	[g_touch resetLayoutToDefaults];
}

// Dump the live layout in the exact form the defaults table takes, so a layout
// arranged on the device can be read over the console bridge and promoted to the
// shipped defaults without anyone transcribing numbers by eye.
void VKQ_iOS_LayoutDescription (char *out, int outsz)
{
	if (!g_touch || outsz <= 0)
		return;
	NSMutableString *s = [NSMutableString stringWithFormat:@"touch layout — scale %.2f, customised=%@\n",
														   vkq_setting_f ("touchSize", 1.0f),
														   vkq_setting_f ("layoutSet", 0.0f) > 0.5f ? @"yes" : @"no (showing defaults)"];
	for (VKQButton *b in [g_touch placeableButtons])
		[s appendFormat:@"  %-8s size %3.0f  at CGPointMake (%.3f, %.3f)\n", b.ident.UTF8String, b.baseSize, b.unit.x, b.unit.y];
	strlcpy (out, s.UTF8String, (size_t)outsz);
}

// Synthetic finger for the layout editor. Injected UIKit touches do not reach
// the touch path on the simulator, so this is the only way to exercise dragging
// without a finger on real glass — it drives the SAME editDrag* methods the real
// touch handlers call, not a parallel copy. x/y are 0..1 of the view.
void VKQ_iOS_FakeTouch (float nx, float ny, int phase)
{
	if (!g_touch)
		return;
	CGSize	sz = g_touch.bounds.size;
	CGPoint p = CGPointMake (nx * sz.width, ny * sz.height);
	if (phase == 3)
	{
		// Query, not a drag: does this point fall in the move-stick zone? Lets the
		// runtime hit test be checked against the circle the editor draws, which
		// is the only part of the stick zone a screenshot can show.
		NSLog (@"[vkquake] movezone (%.0f,%.0f) -> %@", p.x, p.y, [g_touch pointInMoveZone:p] ? @"INSIDE" : @"outside");
		return;
	}
	if (![g_touch isEditingLayout])
	{
		NSLog (@"[vkquake] vkq_faketouch ignored — layout editor is not open");
		return;
	}
	switch (phase)
	{
	case 0:
		NSLog (@"[vkquake] faketouch down (%.0f,%.0f) grabbed=%d", p.x, p.y, [g_touch editDragBegin:p]);
		break;
	case 1:
		[g_touch editDragMove:p];
		break;
	default:
		[g_touch editDragEnd];
		break;
	}
}

// place a centered SF Symbol on an icon button
static void set_symbol (VKQButton *b, NSString *name)
{
	CGFloat	 s = b.baseSize * 0.5;
	UIImage *base = [UIImage systemImageNamed:name];
	if (!base)
	{
		// Unknown symbol name on this OS: leave the button's text label alone
		// rather than clearing it below and shipping a blank circle.
		NSLog (@"[vkquake] SF Symbol '%@' unavailable — keeping text label", name);
		return;
	}
	UIImage *img = [base imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:s
																							   weight:UIImageSymbolWeightSemibold]];
	UIImageView *iv = [[UIImageView alloc] initWithImage:img];
	iv.tintColor = [UIColor colorWithWhite:1 alpha:0.85];
	iv.contentMode = UIViewContentModeCenter;
	iv.frame = b.bounds;
	iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[b addSubview:iv];
	for (UIView *sv in b.subviews)
		if ([sv isKindOfClass:UILabel.class])
			((UILabel *)sv).text = @"";
}

static void vkq_build_ui (void)
{
	UIWindow *win = vkq_key_window ();
	if (!win || g_touch)
		return;

	// visionOS: DON'T restrict window resizing. Free-aspect resize (wide or skinny)
	// is what we want — vkQuake renders at the window's aspect with Hor+ FOV, so a
	// wider window shows more horizontally and a skinny one less; neither stretches
	// or squishes. The renderer re-creates its swapchain at native drawable
	// resolution on each SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED. (Matches q2repro.)

	g_touch = [[VKQTouchView alloc] initWithFrame:win.bounds];

	// right-side action column, shifted toward the edge
	VKQButton *b;
	// Weapon-wheel button: hold to open the engine wheel centered on the thumb, drag
	// toward a weapon, release to switch (mirrors RB on the controller).
	// Move-stick activation zone. Placeable like everything else, but invisible
	// during play and never pressable — the stick itself still floats to wherever
	// your thumb lands inside it. Default centre/radius reproduce the old
	// left-half zone, so movement feels exactly as forgiving as before.
	b = [g_touch addButton:@"" ident:@"stick" size:STICK_ZONE_DIAMETER at:CGPointMake (0.214, 0.608)];
	b.zoneOnly = YES;
	b.hidden = YES;

	// Every button carries a stable ident — it is the key its dragged position is
	// saved under, so renaming one silently resets that button for everybody.
	b = [g_touch addButton:@"" ident:@"wheel" size:60 at:CGPointMake (0.90, 0.40)];
	b.engineWheel = YES;
	set_symbol (b, @"circle.hexagongrid.fill");
	// Action buttons carry glyphs, not text. The label string stays as the
	// fallback set_symbol leaves in place if a symbol ever fails to resolve.
	b = [g_touch addButton:@"JMP" ident:@"jump" size:64 at:CGPointMake (0.997, 0.548)];
	b.downCmd = @"+jump\n";
	b.upCmd = @"-jump\n";
	set_symbol (b, @"arrow.up");
	b = [g_touch addButton:@"FIRE" ident:@"fire" size:80 at:CGPointMake (0.92, 0.74)];
	b.downCmd = @"+attack\n";
	b.upCmd = @"-attack\n";
	b.haptic = YES;
	set_symbol (b, @"scope"); // crosshairs
	// Positions below were arranged on the device and
	// read back over the console bridge (touchedit print, 2026-07-28), then
	// promoted to defaults. Crouch sits hard right and off the bottom edge, which
	// clears the Quake status bar entirely.
	b = [g_touch addButton:@"CRO" ident:@"crouch" size:56 at:CGPointMake (0.995, 0.922)];
	b.downCmd = @"+movedown\n"; // swim/sink down (useful underwater in Quake 1)
	b.upCmd = @"-movedown\n";
	set_symbol (b, @"arrow.down");
	// top-row icon buttons — bigger, crisp SF Symbols
	b = [g_touch addButton:@"" ident:@"menu" size:54 at:CGPointMake (0.975, 0.11)];
	b.keyCode = K_ESCAPE; // open the Quake menu
	set_symbol (b, @"line.3.horizontal");
	b = [g_touch addButton:@"" ident:@"scores" size:54 at:CGPointMake (0.895, 0.11)];
	b.downCmd = @"+showscores\n"; // scores / objectives
	b.upCmd = @"-showscores\n";
	set_symbol (b, @"list.number");

	// One-time migration for players who had the old Lefty Layout on. That toggle
	// is gone — the editor covers it, and the stick zone moves too — so seed the
	// mirrored positions (buttons AND stick zone, since both live in `buttons`)
	// as their saved layout. Without this their whole control scheme would jump
	// across the screen on update.
	if (vkq_setting_f ("lefty", 0.0f) > 0.5f && vkq_setting_f ("layoutSet", 0.0f) < 0.5f)
	{
		[g_touch seedMirroredLayoutForLegacyLefty];
		NSLog (@"[vkquake] migrated legacy Lefty Layout into a saved custom layout");
	}
	[g_touch reloadButtonPositions];
	[win addSubview:g_touch];

	// menu-only back button (menus have no on-screen back without a keyboard)
	g_back = [UIButton buttonWithType:UIButtonTypeSystem];
	UIImage *img = [[UIImage systemImageNamed:@"arrowshape.turn.up.backward.fill"]
		imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightBold]];
	[g_back setImage:img forState:UIControlStateNormal];
	g_back.tintColor = [UIColor colorWithWhite:1 alpha:0.9];
	g_back.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
	g_back.layer.cornerRadius = 10;
	g_back.frame = CGRectMake (0, 0, 64, 46);
	[g_back addTarget:VKQBack.class action:@selector (press) forControlEvents:UIControlEventTouchUpInside];
	g_back.hidden = YES;
	[win addSubview:g_back];

	// menu-only iOS settings button (shown alongside the back button, in menus only)
	g_settings = [UIButton buttonWithType:UIButtonTypeSystem];
	UIImage *gear = [[UIImage systemImageNamed:@"gearshape.fill"]
		imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightBold]];
	[g_settings setImage:gear forState:UIControlStateNormal];
	g_settings.tintColor = [UIColor colorWithWhite:1 alpha:0.9];
	g_settings.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
	g_settings.layer.cornerRadius = 10;
	g_settings.frame = CGRectMake (0, 0, 64, 46);
	[g_settings addTarget:VKQSettingsBtn.class action:@selector (press) forControlEvents:UIControlEventTouchUpInside];
	g_settings.hidden = YES;
	[win addSubview:g_settings];

	// Quick save / quick load. Deliberately NOT part of the touch layout: these
	// are menu chrome like back and gear, offered only from the first main menu
	// of a live single-player game, never over the HUD. Labelled rather than
	// glyph-only — an icon for "quick load" is a guess, and there is room here.
	g_qsave = vkq_menu_pill (@"tray.and.arrow.down.fill", @"QUICK SAVE", VKQQuickSaveBtn.class);
	g_qload = vkq_menu_pill (@"tray.and.arrow.up.fill", @"QUICK LOAD", VKQQuickLoadBtn.class);
	[win addSubview:g_qsave];
	[win addSubview:g_qload];

	// attract-demo catcher: a tap during the demo opens the menu
	g_catcher = [[UIView alloc] initWithFrame:win.bounds];
	g_catcher.backgroundColor = UIColor.clearColor;
	g_catcher.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	g_catcher.hidden = YES;
	[g_catcher addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:VKQBack.class action:@selector (press)]];
	[win addSubview:g_catcher];

	// keyboard: shift the game up + show a Dismiss button while the soft keyboard is up
	// native keyboard input responder — offscreen 1x1 view, never hidden, that becomes
	// first responder to raise the system keyboard and receive key presses.
	g_kbinput = [[VKQKeyInput alloc] initWithFrame:CGRectMake (-10, -10, 1, 1)];
	[win addSubview:g_kbinput];

	g_keyboard = [VKQKeyboard new];
	[NSNotificationCenter.defaultCenter addObserver:g_keyboard selector:@selector (willShow:)
											   name:UIKeyboardWillShowNotification object:nil];
	[NSNotificationCenter.defaultCenter addObserver:g_keyboard selector:@selector (willHide:)
											   name:UIKeyboardWillHideNotification object:nil];
	// 3-finger tap anywhere toggles the keyboard (re-summon after Dismiss). On the
	// window so it works even in menus where the touch overlay is hidden.
	// NOTE: delaysTouchesBegan/Ended left at NO so this never holds single-finger
	// touches (a held recognizer froze SDL's primary-touch → mouse synthesis, which
	// broke menu taps — every tap stuck on the first item).
	UITapGestureRecognizer *kbtap = [[UITapGestureRecognizer alloc] initWithTarget:g_keyboard action:@selector (threeFingerTap:)];
	kbtap.numberOfTouchesRequired = 3;
	kbtap.cancelsTouchesInView = NO;  // don't swallow normal taps/aim
	kbtap.delaysTouchesBegan = NO;
	kbtap.delaysTouchesEnded = NO;
	[win addGestureRecognizer:kbtap];

	// Pause rendering when the scene leaves the foreground. visionOS forbids GPU
	// submission from a backgrounded scene (VK_ERROR_DEVICE_LOST → crash otherwise);
	// a visionOS window can lose focus while the app keeps running, unlike iOS which
	// just suspends us (so this is essentially a no-op there, but harmless).
	// Stereoscopic 3D exception: opening the immersive space deactivates the 2D
	// window scene, but the app stays foreground with an active immersive scene and
	// the engine must keep rendering (offscreen) to feed the panel — so the pause is
	// skipped while vkq3d_immersive_on. On exit the DidActivate handler both resumes
	// the link and returns the engine to the window swapchain (VKQ_Set3DMode(0) is
	// deferred to here so the engine never acquires a drawable from a hidden window).
	[NSNotificationCenter.defaultCenter addObserverForName:UISceneWillDeactivateNotification
		object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
			if (vkq3d_immersive_on)
			{
				NSLog (@"[vkquake] scene deactivated during 3D — engine keeps running");
				return;
			}
			if (g_link) g_link.paused = YES;
			NSLog (@"[vkquake] scene deactivated — rendering paused");
		}];
	[NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification
		object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
			if (g_link) g_link.paused = NO;
#ifdef VKQ_VISIONOS
			// Fallback only: the primary exit path is VKQ_Exit3DFinalize after
			// dismissImmersiveSpace completes (with mixed immersion the window
			// never deactivates, so this may not fire at all).
			extern int	VKQ_Get3DMode (void);
			extern void VKQ_Exit3DFinalize (void);
			if (!vkq3d_immersive_on && VKQ_Get3DMode ())
				VKQ_Exit3DFinalize ();
#endif
			NSLog (@"[vkquake] scene activated — rendering resumed");
		}];

	VKQ_iOS_ApplySettingsToEngine ();
	if (getenv ("VKQ_SHOW_SETTINGS"))
		dispatch_after (dispatch_time (DISPATCH_TIME_NOW, (int64_t) (1.5 * NSEC_PER_SEC)), dispatch_get_main_queue (),
						^{ VKQ_iOS_PresentSettings (); });
	NSLog (@"[vkquake] touch controls attached");
}

// Called by the engine (main_sdl.c patch 0002) after Host_Init.
void VKQ_iOS_SetupUI (void)
{
	extern void VKQ_iOS_ApplyDefaultGamepadBinds (void);
	VKQ_iOS_ConsoleBridgeStart ();		  // opt-in TCP console (VKQ_CONSOLE_BRIDGE=1); no-op otherwise
	VKQ_iOS_ApplyDefaultGamepadBinds ();  // one-time controller layout (A=jump, RT=fire, ...)
	dispatch_async (dispatch_get_main_queue (), ^{ vkq_build_ui (); });
}

// Called by the engine once per frame (display-link callback).
void VKQ_iOS_FramePoll (void)
{
#ifdef VKQ_VISIONOS
	// Stereo 3D fallback pacing: when both-eyes-per-frame is OFF, alternate the
	// parallax eye each engine frame (1=left, 2=right; half rate per eye). In
	// both-eyes mode the SCR_UpdateScreen wrapper drives the eye itself.
	{
		extern int	VKQ_Get3DMode (void);
		extern int	VKQ_Get3DBothEyes (void);
		extern void VKQ_Set3DEye (int eye);
		static int	vkq3d_eye_flip;
		if (VKQ_Get3DMode () && !VKQ_Get3DBothEyes ())
			VKQ_Set3DEye ((vkq3d_eye_flip ^= 1) ? 1 : 2);
	}
#endif
	// Master gain / other-app-audio ducking. Ahead of the g_touch guard on
	// purpose: the mix gain has to keep tracking even before the overlay exists
	// (the onboarding screen and the attract demo both make sound).
	VKQ_iOS_AudioTick ();
	if (!g_touch)
		return;
	// hide touch only when the ENGINE has an open gamepad — not merely when GCController
	// sees one — so a controller the engine can't use doesn't leave the app uncontrollable
	BOOL controller = VKQ_HasActiveController () != 0;
	int	 keydest = VKQ_TouchKeyDest ();
	BOOL inGame = VKQ_TouchInGame () != 0; // a real level — not demo, menu or disconnected
	BOOL isDemo = VKQ_TouchIsDemo () != 0;
	// The layout editor has to keep the overlay up regardless of game state — you
	// reach it from the settings sheet, which is usually open over a menu.
	BOOL showGame = (inGame && !controller) || [g_touch isEditingLayout];
	if (g_touch.hidden != !showGame)
	{
		g_touch.hidden = !showGame;
		VKQ_TouchMove (0, 0); // stop movement whenever the controls appear/disappear
	}
	// attract-demo catcher: covers the screen while a demo plays (tap -> menu)
	BOOL showCatcher = isDemo && keydest == 0;
	if (g_catcher.hidden != !showCatcher)
		g_catcher.hidden = !showCatcher;
	BOOL showBack = (keydest != 0); // in a menu/console — shown even with a controller so the iOS settings gear is reachable
	if (g_back.hidden != !showBack)
	{
		g_back.hidden = !showBack;
		if (showBack)
		{
			UIWindow *win = g_back.superview;
			g_back.center = CGPointMake (win.safeAreaInsets.left + 44, win.safeAreaInsets.top + 30);
		}
	}
	if (g_settings.hidden != !showBack)
	{
		g_settings.hidden = !showBack;
		if (showBack)
		{
			UIWindow *win = g_settings.superview;
			g_settings.center = CGPointMake (win.safeAreaInsets.left + 44, win.safeAreaInsets.top + 88); // below back
		}
	}

	// Quick save / load: only from the FIRST main menu of a live single-player
	// game (the engine owns that test — see patch 0013), stacked under the gear.
	// Quick load additionally needs a quicksave to exist, or it is a dead button.
	{
		extern int	 VKQ_iOS_QuickSaveAvailable (void);
		extern int	 VKQ_iOS_QuickSaveExists (void);
		static BOOL	 lastSave = NO, lastLoad = NO;
		BOOL		 avail = VKQ_iOS_QuickSaveAvailable () != 0;
		BOOL		 showLoad = avail && VKQ_iOS_QuickSaveExists () != 0;
		if (avail != lastSave || showLoad != lastLoad)
		{
			lastSave = avail;
			lastLoad = showLoad;
			g_qsave.hidden = !avail;
			g_qload.hidden = !showLoad;
			if (avail)
			{
				UIWindow *win = g_qsave.superview;
				CGFloat	  x = win.safeAreaInsets.left + 12 + g_qsave.bounds.size.width * 0.5f;
				g_qsave.center = CGPointMake (x, win.safeAreaInsets.top + 140);
				g_qload.center = CGPointMake (x, win.safeAreaInsets.top + 188);
			}
		}
	}

	// live-apply touch appearance (size / opacity) on change
	static float ap_size = -1, ap_op = -1;
	float		 tsz = vkq_setting_f ("touchSize", 1.0f);
	float		 top = vkq_setting_f ("touchOpacity", 0.8f);
	if (tsz != ap_size || top != ap_op)
	{
		ap_size = tsz;
		ap_op = top;
		[g_touch applyAppearance:tsz opacity:top];
	}

	// gyro aim (device rotation -> look) while playing, no controller
	static CMMotionManager *motion;
	float					gyro = vkq_setting_f ("gyro", 0.0f);
	if (gyro > 0 && inGame && !controller)
	{
		if (!motion)
		{
			motion = [CMMotionManager new];
			motion.deviceMotionUpdateInterval = 1.0 / 120.0;
			[motion startDeviceMotionUpdates];
		}
		CMDeviceMotion *dm = motion.deviceMotion;
		static double	glast;
		double			gnow = CACurrentMediaTime ();
		double			gdt = glast ? gnow - glast : 0;
		glast = gnow;
		if (dm && gdt > 0 && gdt < 0.1)
		{
			// Gyro axes, done in the WORLD frame rather than the device frame.
			//
			// CMDeviceMotion.rotationRate is in DEVICE (portrait-referenced) axes:
			// +x out the right edge, +y out the top edge, +z out of the screen. Held
			// in landscape the device is rolled 90°, so the top edge is horizontal
			// and the right edge is vertical — the old code read .y as yaw and .x as
			// pitch, which is exactly backwards, and is why tilting the phone face-up
			// turned the view sideways while turning the phone sideways pitched it.
			//
			// Swapping the two would fix the upright case only. Nobody holds a phone
			// exactly upright, and at a 45° hold a device-axis mapping bleeds each
			// rotation into the wrong angle. So resolve the axes against gravity
			// instead, which is roll-independent and needs no orientation enum:
			//   u = world up in device coords (= -gravity)
			//   yaw   = component of the rotation about u        (turning the phone)
			//   pitch = component about the horizontal axis in the screen plane,
			//           h = normalize(-u.y, u.x, 0), which is perpendicular to both
			//           u and the screen normal                  (tilting the phone)
			// Signs: VKQ_TouchLook is +yaw = look RIGHT, +pitch = look DOWN, and a
			// right-handed rotation about world up is a turn to the LEFT — hence the
			// negation on both. Result: turn the phone left, look left; tilt the
			// phone face-up, look up.
			float ux = -(float)dm.gravity.x, uy = -(float)dm.gravity.y, uz = -(float)dm.gravity.z;
			float un = sqrtf (ux * ux + uy * uy + uz * uz);
			float wx = (float)dm.rotationRate.x, wy = (float)dm.rotationRate.y, wz = (float)dm.rotationRate.z;
			float k = 57.2958f * gyro * (float)gdt;
			if (un > 0.1f)
			{
				ux /= un;
				uy /= un;
				uz /= un;
				float yaw_left = wx * ux + wy * uy + wz * uz;
				// Screen-plane horizontal axis. Degenerate only when the screen faces
				// straight up/down (|hn| -> 0), a pose you cannot aim from anyway;
				// fall back to the landscape long edge so it never divides by ~0.
				float hx = -uy, hy = ux;
				float hn = sqrtf (hx * hx + hy * hy);
				float pitch_up;
				if (hn > 0.2f)
					pitch_up = (wx * hx + wy * hy) / hn;
				else
				{
#ifdef VKQ_VISIONOS
					float s = 1.f; // no interface orientation on visionOS (gyro n/a there)
#else
					UIInterfaceOrientation o = g_touch.window.windowScene.interfaceOrientation;
					// LandscapeLeft == UIDeviceOrientationLandscapeRight: the portrait
					// top edge points to the user's RIGHT, flipping both axes.
					float s = (o == UIInterfaceOrientationLandscapeLeft) ? -1.f : 1.f;
#endif
					pitch_up = s * wy;
				}
				// Invert Gyro (Vertical) is its own switch, not the touch "Invert Look":
				// tilt-to-aim has two equally defensible conventions (tilt up = look up,
				// or the camera-lens one where it looks down) and the choice is unrelated
				// to how you want a thumb drag to behave.
				if (vkq_setting_f ("gyroInvert", 0.0f) > 0.5f)
					pitch_up = -pitch_up;
				VKQ_TouchLook (-yaw_left * k, -pitch_up * k);
			}
		}
	}
	else if (motion)
	{
		[motion stopDeviceMotionUpdates];
		motion = nil;
	}

	// fps counter (shell-measured wall fps, clamped top-corner)
	static UILabel *fps;
	static double	fps_t0;
	static int		fps_n;
	static float	fps_v;
	double			now = CACurrentMediaTime ();
	if (fps_t0 == 0)
		fps_t0 = now;
	fps_n++;
	if (now - fps_t0 >= 0.5)
	{
		fps_v = (float)(fps_n / (now - fps_t0));
		fps_n = 0;
		fps_t0 = now;
	}
	BOOL wantFps = vkq_setting_f ("fps", 0.0f) > 0.5f;
	if (wantFps && !fps)
	{
		UIWindow *win = g_touch.superview;
		fps = [[UILabel alloc] init];
#ifdef VKQ_VISIONOS
		const CGFloat fpsFont = 15, fpsW = 42, fpsH = 22;
#else
		const CGFloat fpsFont = 12, fpsW = 34, fpsH = 18;
#endif
		fps.font = [UIFont monospacedDigitSystemFontOfSize:fpsFont weight:UIFontWeightBold];
		fps.textColor = [UIColor colorWithWhite:1 alpha:0.85];
		fps.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3];
		fps.textAlignment = NSTextAlignmentCenter;
		fps.layer.cornerRadius = 4;
		fps.layer.masksToBounds = YES;
		// Auto Layout. The old absolute frame was computed ONCE from win.bounds at
		// creation and went stale when the window resized (the visionOS
		// free-resizing window / a landscape relayout), stranding the label at the
		// old x — the "top-centre-left" bug. Constraints re-anchor for free.
		fps.translatesAutoresizingMaskIntoConstraints = NO;
		[win addSubview:fps];
#ifdef VKQ_VISIONOS
		// Vision Pro: safe-area corner, as tuned in 1.0.3. No sensor housing to
		// dodge and no display corner radius eating the window's own corner.
		UILayoutGuide *anchorGuide = win.safeAreaLayoutGuide;
		const CGFloat  fpsRight = -8, fpsTop = 4;
#else
		// iPhone: deliberately NOT the safe-area guide. In landscape UIKit insets
		// it by the sensor-housing width on BOTH edges (~60 pt on a Dynamic Island
		// phone), which parked the counter a long way in from the corner. The
		// housing is a pill in the vertical MIDDLE of that edge, so the top corner
		// itself is free. These insets clear the display's own corner radius,
		// which the simulator does NOT render and so cannot verify: for a 55–62 pt
		// radius the rounded edge cuts in 8–12 pt at 26 pt down, so 16 pt keeps the
		// whole box on glass either way.
		UILayoutGuide *anchorGuide = nil;
		const CGFloat  fpsRight = -16, fpsTop = 26;
#endif
		NSLayoutXAxisAnchor *trailing = anchorGuide ? anchorGuide.trailingAnchor : win.trailingAnchor;
		NSLayoutYAxisAnchor *top = anchorGuide ? anchorGuide.topAnchor : win.topAnchor;
		[NSLayoutConstraint activateConstraints:@[
			[fps.trailingAnchor constraintEqualToAnchor:trailing constant:fpsRight],
			[fps.topAnchor constraintEqualToAnchor:top constant:fpsTop],
			[fps.widthAnchor constraintEqualToConstant:fpsW],
			[fps.heightAnchor constraintEqualToConstant:fpsH],
		]];
	}
	else if (!wantFps && fps)
	{
		[fps removeFromSuperview];
		fps = nil;
	}
	if (fps)
	{
		static int fdiv;
		if ((++fdiv % 15) == 0)
			fps.text = [NSString stringWithFormat:@"%.0f", fps_v];
	}
}
