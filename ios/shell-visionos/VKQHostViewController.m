// VKQHostViewController.m — boots the SDL/vkQuake engine under the SwiftUI app
// entry (visionOS only) and owns the 2D<->3D transition sequencing.
//
// Why a SwiftUI entry at all: an ImmersiveSpace (stereoscopic rendering) can only
// be declared by a SwiftUI App. SDL3's own UIApplicationMain wrapper is therefore
// bypassed on visionOS (engine built with VKQ_SWIFT_MAIN): this VC calls the
// engine's renamed main once the SwiftUI window scene is live. SDL3 then creates
// its UIWindow against the active window scene (UIKit_GetActiveWindowScene) and
// everything downstream — display link, touch overlay, console bridge — works
// exactly as on the SDL-main path. SDL's lifecycle observation is delegate-free
// (NSNotification based), so it keeps working without SDL's app delegate.
//
// 2D->3D sequencing (order is load-bearing; see quake3e D-019):
//   enter: VKQ_Set3DMode(1) FIRST (engine stops touching the window swapchain —
//          the hidden window's drawable acquire would stall MoltenVK forever),
//          THEN open the immersive space (SwiftUI, hides the 2D window).
//   exit:  stop the immersive render thread and WAIT for it (it must never touch
//          a layerRenderer SwiftUI is tearing down), dismiss the space, and only
//          when the window scene reactivates does ios_touch.m clear 3D mode —
//          the engine never acquires a drawable from a still-hidden window.

#import "VKQHostViewController.h"
#import "VKQImmersive.h"
#import <Metal/Metal.h>

// SDL3 (statically linked; the shell has no SDL header search path — plain C decl).
extern void SDL_SetMainReady (void);

extern int	vkq_engine_main (int argc, char *argv[]); // main_sdl.c (VKQ_SWIFT_MAIN)
extern int	vkq3d_immersive_on;						  // ios_touch.m (gates render pause)
extern void VKQ_SetImmersiveMode (bool on);			  // VKQVisionApp.swift (@_cdecl)
extern void VKQ_Set3DMode (int on);					  // engine overlay patch 0010
extern void VKQ_Set3DParams (float sep, float conv);
extern int	VKQ_Get3DMode (void);
extern void VKQ_GetWindowSize (int *w, int *h); // engine overlay patch 0010
extern void VKQ_SetWindowSize (int w, int h);
extern float vkq_setting_f (const char *key, float def); // ios_settings.m

// Engine console plumbing (linked from libvkquake-xros.a). Cmd_AddCommand is a
// macro over Cmd_AddCommand2(name, func, src_command) in cmd.h; src_command=1.
typedef void (*xcommand_t) (void);
extern void		  *Cmd_AddCommand2 (const char *cmd_name, xcommand_t function, int srctype);
#define VKQ_CMD_SRC_COMMAND 1
extern int		   Cmd_Argc (void);
extern const char *Cmd_Argv (int arg);
extern void		   Con_Printf (const char *fmt, ...);

static BOOL vkq_booted = NO;
static int	vkq_pre3d_w = 0, vkq_pre3d_h = 0; // window size to restore after 3D
static void VKQ_SetCurtain (bool show);		  // defined below
static void VKQ_3DSmallWindow (void);		  // defined below
static void VKQ_Enter3DCommit (void);
static void VKQ_Enter3DPhase2 (int triesLeft, int initialWidth);

// Flip the engine to offscreen stereo + open the space. Only called when the
// render target is stable (no vid restart in flight).
static void VKQ_Enter3DCommit (void)
{
	// mode/curtain/override were set by VKQ_Enter3D before the size poll — this
	// only opens the space once the render target is stable.
	VKQ_SetImmersiveMode (true);
	NSLog (@"[vkquake] 3D entry committed");
	// Park the 2D window AFTER entry settles: a window resize ANIMATION
	// concurrent with a vid restart wedges swapchain recreation (the surface
	// geometry moves under it) — sim-proven. By now the restart is done and no
	// other restart is scheduled, so the animation is harmless.
	dispatch_after (dispatch_time (DISPATCH_TIME_NOW, (int64_t) (1.5 * NSEC_PER_SEC)), dispatch_get_main_queue (), ^{
		if (vkq3d_immersive_on)
		{
			VKQ_3DSmallWindow ();
			VKQ_SetCurtain (true); // re-assert on top once the park is underway
			// …and once the park ANIMATION has fully settled (belt & suspenders
			// for the device-only animated-layout path the sim can't reproduce).
			dispatch_after (dispatch_time (DISPATCH_TIME_NOW, (int64_t) (1.5 * NSEC_PER_SEC)), dispatch_get_main_queue (), ^{
				if (vkq3d_immersive_on)
					VKQ_SetCurtain (true);
			});
		}
	});
}

// Wait for the high-res vid restart to finish: the present image is destroyed
// and recreated at the NEW size — commit only after its width CHANGED from the
// pre-resize value (absolute checks race: the old texture still reports the old
// size until the restart lands). On timeout, re-request the original size (a
// no-op if the resize never happened) so a late restart can't land mid-3D.
static void VKQ_Enter3DPhase2 (int triesLeft, int initialWidth)
{
	extern void VKQ_Get3DPresentSize (int *w, int *h); // actual live image extent
	int pw = 0, ph = 0;
	VKQ_Get3DPresentSize (&pw, &ph);
	if (pw > 0 && pw != initialWidth)
	{
		NSLog (@"[vkquake] 3D high-res target ready (%dx%d)", pw, ph);
		VKQ_Enter3DCommit ();
		return;
	}
	if (triesLeft <= 0)
	{
		// Enter anyway — the override restart will still land (offscreen mode is
		// already active, so a late restart is safe now; unlike the old
		// window-resize scheme there is nothing to revert).
		NSLog (@"[vkquake] 3D render-size restart slow — entering; it will land offscreen");
		VKQ_Enter3DCommit ();
		return;
	}
	dispatch_after (dispatch_time (DISPATCH_TIME_NOW, (int64_t) (0.1 * NSEC_PER_SEC)), dispatch_get_main_queue (),
					^{ VKQ_Enter3DPhase2 (triesLeft - 1, initialWidth); });
}

// Push the persisted Vision Pro 3D settings into the panel/stereo state
// (ios_settings.m owns the storage; this is also called live from its sliders).
void VKQ_iOS_Apply3DSettings (void)
{
	extern void VKQ_Set3DBothEyes (int on);
	VKQ_Set3DPanel (vkq_setting_f ("vp3dDist", 3.6f), vkq_setting_f ("vp3dHalfW", 2.75f), vkq_setting_f ("vp3dSizeH", 1.55f));
	VKQ_Set3DHeight (vkq_setting_f ("vp3dHeight", 0.0f));
	VKQ_Set3DParams (vkq_setting_f ("vp3dSep", 2.5f), vkq_setting_f ("vp3dConv", 240.0f)); // 240 units ≈ 20 ft
	VKQ_Set3DBothEyes (1); // always on (setting removed — it's pure upside here)
	VKQ_Set3DDim (vkq_setting_f ("vp3dDim", 0.8f));
	// Engine-drawn FPS on the panel ("FPS on Panel" setting). The UIKit FPS
	// label lives on the 2D window, which is behind the curtain in 3D — so the
	// panel needs the engine counter. Apply it on 3D ENTRY (not only when the
	// settings sheet changes) or toggling it before entering 3D silently no-ops.
	extern void VKQ_TouchCommand (const char *cmd);
	VKQ_TouchCommand (vkq_setting_f ("vp3dFps", 0.0f) > 0.5f ? "scr_showfps 1\n" : "scr_showfps 0\n");
}

// Target render size (PIXELS) for the panel's current shape: the aspect comes
// from the user's width×height sliders; area pinned to the 3840×2160 budget.
// The panel's resolution is DECOUPLED from the 2D window (engine override —
// the window is deliberately shrunk out of the way during 3D).
static void VKQ_3DTargetPixels (int *tw, int *th)
{
	float w = vkq_setting_f ("vp3dHalfW", 2.75f), h = vkq_setting_f ("vp3dSizeH", 1.55f);
	float aspect = (h > 0.01f) ? (w / h) : (16.0f / 9.0f);
	float fw = sqrtf (3840.0f * 2160.0f * aspect);
	*tw = (int)lroundf (fw);
	*th = (int)lroundf (fw / aspect);
}

// Shrink the 2D window to a small pill-sized card during 3D (it only exists as
// the control surface — ornament buttons + curtain). Matches the panel aspect
// for looks. visionOS offers no API to MOVE windows, so position is the user's:
// park it above the panel once and the system keeps it there.
static void VKQ_3DSmallWindow (void)
{
	float w = vkq_setting_f ("vp3dHalfW", 2.75f), h = vkq_setting_f ("vp3dSizeH", 1.55f);
	float aspect = (h > 0.01f) ? (w / h) : (16.0f / 9.0f);
	VKQ_SetWindowSize (480, (int)lroundf (480.0f / aspect));
}

// Re-sync the render target to the panel's aspect (slider release / reset while
// in 3D). The restart is safe mid-3D: teardown NULLs the present handles and
// re-gates the per-eye accessors, and the compositor keeps sampling its own
// per-eye copies until fresh frames arrive.
void VKQ_iOS_Sync3DAspect (void)
{
	extern void VKQ_Set3DRenderSize (int w, int h);
	extern void VKQ_Get3DPresentSize (int *w, int *h);
	if (!vkq3d_immersive_on)
		return;
	int tw = 0, th = 0, cw = 0, ch = 0;
	VKQ_3DTargetPixels (&tw, &th);
	VKQ_Get3DPresentSize (&cw, &ch);
	if (abs (tw - cw) > 16 || abs (th - ch) > 16)
	{
		NSLog (@"[vkquake] 3D: panel render resync %dx%d -> %dx%d px", cw, ch, tw, th);
		VKQ_Set3DRenderSize (tw, th);
		// deliberately NOT re-shaping the parked card here: a window animation
		// concurrent with this restart wedges swapchain recreation
	}
}

// Runs on the main thread after SwiftUI's dismissImmersiveSpace completes (the
// Exit button / vkq3d 0 path) — and from the scene-activate fallback. With
// MIXED immersion the 2D window never deactivates, so the original
// activate-only trigger never fired and the window stayed frozen (the
// exit-freeze report): the engine was still in offscreen 3D mode.
void VKQ_Exit3DFinalize (void)
{
	// Panel FPS off back in 2D — the UIKit "FPS Counter" label takes over there,
	// and leaving the engine counter on would double it up on the window.
	extern void VKQ_TouchCommand (const char *cmd);
	VKQ_TouchCommand ("scr_showfps 0\n");
	dispatch_async (dispatch_get_main_queue (), ^{
		// Restore the window FIRST and let its animation finish before the
		// back-to-2D restart (restart + geometry animation = swapchain wedge).
		// The engine stays safely offscreen (mode still on) during the gap; the
		// curtain stays up so the mid-restore window isn't a frozen game frame.
		if (vkq_pre3d_w > 0 && vkq_pre3d_h > 0)
		{
			VKQ_SetWindowSize (vkq_pre3d_w, vkq_pre3d_h);
			vkq_pre3d_w = vkq_pre3d_h = 0;
		}
		dispatch_after (dispatch_time (DISPATCH_TIME_NOW, (int64_t) (0.8 * NSEC_PER_SEC)), dispatch_get_main_queue (), ^{
			extern void VKQ_Set3DRenderSize (int w, int h);
			VKQ_SetCurtain (false);
			if (VKQ_Get3DMode ())
			{
				VKQ_Set3DMode (0);			// back to the window swapchain
				VKQ_Set3DRenderSize (0, 0); // follow the window again (+ restart)
				NSLog (@"[vkquake] 3D exit finalized — window rendering resumes");
			}
		});
	});
}

// --- "3D mode" curtain over the frozen 2D window --------------------------------
// In 3D the engine stops presenting to the window swapchain, so the 2D window
// freezes on its last frame — a confusing duplicate floating in front of the
// panel. Cover it with a labeled curtain; the window (and its ornament with the
// Exit 3D button) stays interactive.
static UIView *vkq_curtain;

static void VKQ_SetCurtain (bool show)
{
	if (show)
	{
		if (vkq_curtain)
		{
			// Re-assert: the parked-window animation/layout (or a view added
			// later, e.g. the FPS label) can displace or cover the curtain —
			// put it back on top of whatever the window holds now.
			NSLog (@"[vkquake] curtain re-assert (superview=%p)", vkq_curtain.superview);
			[vkq_curtain.superview bringSubviewToFront:vkq_curtain];
			return;
		}
		// Land on the GAME window explicitly — "the key window" can be a SwiftUI
		// ornament/sheet hosting window right after a button tap on visionOS.
		extern UIWindow *VKQ_iOS_GameWindow (void);
		UIWindow *win = VKQ_iOS_GameWindow ();
		NSLog (@"[vkquake] curtain: gameWindow=%p", win);
		if (!win)
			for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
				if ([s isKindOfClass:UIWindowScene.class])
					for (UIWindow *w in ((UIWindowScene *)s).windows)
						if (w.isKeyWindow || win == nil)
							win = w;
		if (!win)
		{
			NSLog (@"[vkquake] curtain: NO WINDOW FOUND — curtain skipped");
			return;
		}
		vkq_curtain = [[UIView alloc] init];
		vkq_curtain.backgroundColor = UIColor.blackColor;
		// EDGE CONSTRAINTS, not frame+autoresizing: once anything constraint-
		// based lives on the window (the FPS label), the window lays out with
		// Auto Layout, and on-device the ANIMATED park left an autoresizing
		// curtain at stale pre-park geometry (regression: parked card showed the
		// frozen game frame, no "Playing in 3D"). Constraints track any window
		// geometry, animated or not.
		vkq_curtain.translatesAutoresizingMaskIntoConstraints = NO;
		UILabel *l = [UILabel new];
		l.text = @"Playing in 3D";
		l.numberOfLines = 0;
		l.textAlignment = NSTextAlignmentCenter;
		l.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
		l.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium]; // window is a small parked card in 3D
		l.translatesAutoresizingMaskIntoConstraints = NO;
		[vkq_curtain addSubview:l];
		[NSLayoutConstraint activateConstraints:@[
			[l.centerXAnchor constraintEqualToAnchor:vkq_curtain.centerXAnchor],
			[l.centerYAnchor constraintEqualToAnchor:vkq_curtain.centerYAnchor],
			[l.widthAnchor constraintLessThanOrEqualToAnchor:vkq_curtain.widthAnchor multiplier:0.8],
		]];
		[win addSubview:vkq_curtain];
		[NSLayoutConstraint activateConstraints:@[
			[vkq_curtain.leadingAnchor constraintEqualToAnchor:win.leadingAnchor],
			[vkq_curtain.trailingAnchor constraintEqualToAnchor:win.trailingAnchor],
			[vkq_curtain.topAnchor constraintEqualToAnchor:win.topAnchor],
			[vkq_curtain.bottomAnchor constraintEqualToAnchor:win.bottomAnchor],
		]];
		NSLog (@"[vkquake] curtain up on %p (%.0fx%.0f)", win, win.bounds.size.width, win.bounds.size.height);
	}
	else
	{
		[vkq_curtain removeFromSuperview];
		vkq_curtain = nil;
	}
}

// --- console commands (drive 3D from the console bridge / configs) -----------

// vkq3d 1|0 — enter/exit stereoscopic 3D
static void VKQ_Cmd_3D (void)
{
	int on = (Cmd_Argc () > 1) ? atoi (Cmd_Argv (1)) : !vkq3d_immersive_on;
	Con_Printf ("vkq3d: %s\n", on ? "entering 3D" : "exiting 3D");
	dispatch_async (dispatch_get_main_queue (), ^{ VKQ_Enter3D (on != 0); });
}

// vkqsettings — open the settings sheet (works in 2D and over the 3D panel)
static void VKQ_Cmd_Settings (void)
{
	extern void VKQ_OpenSettingsSheet (void);
	VKQ_OpenSettingsSheet ();
}

// vkq3dtune <sep> <conv> [dist] [halfW] [posH] [halfH] — live stereo/panel tuning
static void VKQ_Cmd_3DTune (void)
{
	extern void VKQ_iOS_Sync3DAspect (void);
	if (Cmd_Argc () < 3)
	{
		Con_Printf ("usage: vkq3dtune <sep-units> <conv-units> [dist-m] [halfW-m] [posH-m] [halfH-m]\n");
		return;
	}
	VKQ_Set3DParams (atof (Cmd_Argv (1)), atof (Cmd_Argv (2)));
	if (Cmd_Argc () > 4)
		VKQ_Set3DPanel (atof (Cmd_Argv (3)), atof (Cmd_Argv (4)), (Cmd_Argc () > 6) ? atof (Cmd_Argv (6)) : 0.0f);
	if (Cmd_Argc () > 5)
		VKQ_Set3DHeight (atof (Cmd_Argv (5)));
	if (Cmd_Argc () > 6)
	{
		// keep the persisted settings + render aspect in step with the console value
		extern void vkq_setting_set_f (const char *key, float val);
		vkq_setting_set_f ("vp3dHalfW", atof (Cmd_Argv (4)));
		vkq_setting_set_f ("vp3dSizeH", atof (Cmd_Argv (6)));
		dispatch_async (dispatch_get_main_queue (), ^{ VKQ_iOS_Sync3DAspect (); });
	}
	Con_Printf ("vkq3dtune: sep=%s conv=%s\n", Cmd_Argv (1), Cmd_Argv (2));
}

// vkq3dfov [0|1] — eye-tracked foveation (the 3D-panel de-blur). No arg flips.
// Persisted; read at CompositorLayer config time, so re-enter 3D to apply — the
// A/B toggle and the recovery path if a future OS rejects the foveated config.
static void VKQ_Cmd_3DFov (void)
{
	int on = (Cmd_Argc () > 1) ? atoi (Cmd_Argv (1)) : !VKQ_Get3DFoveationWanted ();
	VKQ_Set3DFoveation (on);
	Con_Printf ("vkq3dfov: foveation %s — re-enter 3D to apply\n", on ? "ON" : "off");
}

// --- 2D <-> 3D transitions ----------------------------------------------------

void VKQ_Enter3D (bool on)
{
	if (!vkq_booted)
	{
		NSLog (@"[vkquake] Enter3D(%d) ignored pre-boot", on);
		return;
	}
	if (on == (bool)vkq3d_immersive_on)
		return;

	if (on)
	{
		// Push the saved panel/stereo settings BEFORE the first stereo frame.
		VKQ_iOS_Apply3DSettings ();
		// High-res panel: the panel texture IS the window drawable, so raise the
		// render target to ~4K while in 3D (M5 has huge headroom) and restore the
		// user's window size on exit. Points; drawable is 2x. TWO-PHASE: the
		// resize triggers a vid restart that destroys/recreates the present
		// image — entering 3D concurrently let the immersive thread blit from a
		// dying texture (instant crash). Resize FIRST while still safely 2D,
		// poll until the new present image exists, THEN open the space.
		// Size the render target to the PANEL's shape (user width×height sliders
		// set the aspect) at the 3840×2160 pixel budget — via the engine's
		// render-size override, fully decoupled from the 2D window, which
		// shrinks to a small parked card instead.
		{
			extern void VKQ_Set3DRenderSize (int w, int h);
			extern void VKQ_Get3DPresentSize (int *w, int *h);
			int w0 = 0, h0 = 0, tw = 0, th = 0;
			VKQ_Get3DPresentSize (&w0, &h0);
			VKQ_3DTargetPixels (&tw, &th);
			VKQ_GetWindowSize (&vkq_pre3d_w, &vkq_pre3d_h); // restore on exit
			vkq3d_immersive_on = 1; // gate render pause + enable the override path
			VKQ_Set3DMode (1);		// offscreen from here (override getter is live)
			VKQ_Set3DRenderSize (tw, th); // schedules the restart at panel res
			VKQ_SetCurtain (true);		  // (window parks after entry settles)
			NSLog (@"[vkquake] 3D: render override %dx%d -> %dx%d px", w0, h0, tw, th);
			if (w0 != tw)
			{
				VKQ_Enter3DPhase2 (30, w0); // poll for the restarted target
				return;
			}
		}
		VKQ_SetImmersiveMode (true);
		NSLog (@"[vkquake] 3D entry committed (size already matched)");
	}
	else
	{
		// Stop the immersive render thread and WAIT before the space is torn down.
		vkq_immStop = 1;
		for (int i = 0; i < 200 && vkq_immRunning; i++) // <= 2 s
			usleep (10 * 1000);
		NSLog (@"[vkquake] Enter3D(0): render thread stopped=%d", !vkq_immRunning);
		vkq3d_immersive_on = 0;
		VKQ_SetImmersiveMode (false); // dismiss; VKQ_Exit3DFinalize runs after the
									  // dismiss completes (Swift), with a scene-
									  // activate fallback in ios_touch.m
	}
	NSLog (@"[vkquake] 3D -> %d", on);
}

// Crown/system dismissal: the loop saw the layer invalidated and already exited.
void VKQ_Immersive_Ended (void)
{
	NSLog (@"[vkquake] immersive ended by system (Crown)");
	dispatch_async (dispatch_get_main_queue (), ^{
		vkq3d_immersive_on = 0;
		VKQ_SetImmersiveMode (false); // sync the SwiftUI model (no-op if already closed)
		VKQ_Exit3DFinalize ();
	});
}

// --- engine bootstrap ----------------------------------------------------------

@implementation VKQHostViewController

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.view.backgroundColor = UIColor.blackColor;
	// Resilience: if the user closes the parked window (the X under it) during
	// 3D, the app loses its only regular scene — audio dies and there is no
	// Exit control left. Re-request the window session so the card comes back.
	[NSNotificationCenter.defaultCenter addObserverForName:UISceneDidDisconnectNotification
		object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
			if (!vkq3d_immersive_on || ![n.object isKindOfClass:UIWindowScene.class])
				return;
			NSLog (@"[vkquake] window closed during 3D — requesting it back");
			dispatch_after (dispatch_time (DISPATCH_TIME_NOW, (int64_t) (0.5 * NSEC_PER_SEC)), dispatch_get_main_queue (), ^{
				[UIApplication.sharedApplication requestSceneSessionActivation:nil
																   userActivity:nil
																		options:nil
																   errorHandler:^(NSError *e) { NSLog (@"[vkquake] reopen failed: %@", e); }];
			});
		}];
}

- (void)viewDidAppear:(BOOL)animated
{
	[super viewDidAppear:animated];
	extern void VKQ_BeaconMark (const char *stage);
	VKQ_BeaconMark ("beacon: VKQHostViewController viewDidAppear");
	if (vkq_booted)
		return;
	vkq_booted = YES;
	// One runloop hop so the window scene is fully active before SDL_CreateWindow
	// goes looking for it (UIKit_GetActiveWindowScene).
	dispatch_async (dispatch_get_main_queue (), ^{
		NSLog (@"[vkquake] SwiftUI shell: booting engine (vkq_engine_main)");
		SDL_SetMainReady ();
		static char	 arg0[] = "vkquake";
		static char *argv[] = {arg0, NULL};
		vkq_engine_main (1, argv); // returns after Host_Init + display-link start
		Cmd_AddCommand2 ("vkq3d", VKQ_Cmd_3D, VKQ_CMD_SRC_COMMAND);
		Cmd_AddCommand2 ("vkq3dtune", VKQ_Cmd_3DTune, VKQ_CMD_SRC_COMMAND);
		Cmd_AddCommand2 ("vkq3dfov", VKQ_Cmd_3DFov, VKQ_CMD_SRC_COMMAND);
		Cmd_AddCommand2 ("vkqsettings", VKQ_Cmd_Settings, VKQ_CMD_SRC_COMMAND);
		NSLog (@"[vkquake] SwiftUI shell: engine booted, 3D commands registered");
	});
}

@end
