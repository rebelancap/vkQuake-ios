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
#import "VKQVR.h"
#import "VKQSenseController.h"
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
extern float	   Cvar_VariableValue (const char *var_name); // cvar.c
extern void		   Cvar_SetValue (const char *var_name, const float value);
extern int		   q_strcasecmp (const char *s1, const char *s2); // common.c
extern void		   vkq_setting_set_f (const char *key, float val); // ios_settings.m

static BOOL vkq_booted = NO;
static int	vkq_pre3d_w = 0, vkq_pre3d_h = 0; // window size to restore after 3D
static void VKQ_SetCurtain (bool show);		  // defined below
static void VKQ_3DSmallWindow (void);		  // defined below
static void VKQ_Enter3DCommit (void);
static void VKQ_Enter3DPhase2 (int triesLeft, int initialWidth);
static void VKQ_Enter3DInternal (bool on); // the 3D half of VKQ_EnterMode

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
static UIView  *vkq_curtain;
static UILabel *vkq_curtainLabel;

// What the parked card says. R1.1: it read "Playing in 3D" during a VR session,
// because the curtain goes up in VKQ_EnterVRNow — BEFORE VKQ_EnterVRCommit sets
// the mode — and the label was only ever set at creation. In the round whose
// whole complaint was "I can't tell VR from 3D", the one label on screen must
// not be lying about which one you are in.
static void VKQ_CurtainRefreshText (void)
{
	vkq_curtainLabel.text = (VKQ_GetMode () == VKQ_MODE_VR) ? @"Playing in VR" : @"Playing in 3D";
}

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
			VKQ_CurtainRefreshText ();
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
		vkq_curtainLabel = l;
		VKQ_CurtainRefreshText ();
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
		vkq_curtainLabel = nil;
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
/*
 * vkqsettings [open|close] -- R6.1 item 4.
 *
 * `vkqsettings` alone still opens, exactly as it always has (the harness and
 * every note in this repo type it that way). `vkqsettings close` is the new half,
 * and it exists because of a specific dead end in the user's 1.0.7.9 round: the
 * settings sheet was up, the console bridge was answering, and there was still no
 * way to dismiss it from a laptop — the bridge reaches Cbuf, and Cbuf could not
 * reach UIKit. He had to take the headset's Done button himself. A remote round
 * must never be blocked on a hand.
 */
static void VKQ_Cmd_Settings (void)
{
	extern void VKQ_OpenSettingsSheet (void);
	extern void VKQ_iOS_DismissSettings (void);
	extern int	VKQ_iOS_SettingsSheetOpen (void);
	const char *arg = (Cmd_Argc () > 1) ? Cmd_Argv (1) : "";
	if (!q_strcasecmp (arg, "close") || !strcmp (arg, "0"))
	{
		// Reported, not silent: "I sent close and nothing happened" and "it was
		// already shut" are the same picture over a bridge otherwise.
		Con_Printf ("vkqsettings: closing (sheet was %s)\n", VKQ_iOS_SettingsSheetOpen () ? "OPEN" : "already closed");
		VKQ_iOS_DismissSettings ();
		return;
	}
	if (arg[0] && q_strcasecmp (arg, "open") && strcmp (arg, "1"))
	{
		Con_Printf ("usage: vkqsettings [open|close]   (sheet is currently %s)\n", VKQ_iOS_SettingsSheetOpen () ? "OPEN" : "closed");
		return;
	}
	VKQ_OpenSettingsSheet ();
}

/*
 * vkqvrmsg <text> -- R6.1 item 2's trigger, and a device-round instrument.
 *
 * Hands a string to SCR_CenterPrint, which is the EXACT function cl_parse.c
 * calls on svc_centerprint / svc_finale / svc_cutscene — so everything
 * downstream (the centre-string state, scr_centertime, the console echo, and the
 * new VR message panel) is driven by the same code a real server message drives.
 * The one link it does not exercise is the network byte parse itself.
 *
 * It exists because a centerprint is otherwise unscriptable: there is no console
 * command in stock Quake that produces one, and the QuakeC that does (a locked
 * door, a trigger with a message, a secret) needs a player walked into it. The
 * simulator asserts the panel's PIXELS through this, and the notify half of the
 * feature is asserted through a genuine server round trip instead (`say`), so
 * between the two the whole path is covered.
 */
static void VKQ_Cmd_VRMsg (void)
{
	extern void SCR_CenterPrint (const char *str);
	char		buf[1024];
	int			i;
	if (Cmd_Argc () < 2)
	{
		Con_Printf ("usage: vkqvrmsg <text>   (\\n for a line break)\n");
		return;
	}
	buf[0] = 0;
	for (i = 1; i < Cmd_Argc (); i++)
	{
		const size_t used = strlen (buf);
		if (used + 2 >= sizeof (buf))
			break;
		snprintf (buf + used, sizeof (buf) - used, "%s%s", (i > 1) ? " " : "", Cmd_Argv (i));
	}
	// The console tokenizer will not carry a real newline through, and a
	// multi-line centerprint is the case that exercises the wrap and the line
	// budget. Two characters in, one line break out.
	{
		char *r = buf, *w = buf;
		while (*r)
		{
			if (r[0] == '\\' && r[1] == 'n')
			{
				*w++ = '\n';
				r += 2;
			}
			else
				*w++ = *r++;
		}
		*w = 0;
	}
	SCR_CenterPrint (buf);
	Con_Printf ("vkqvrmsg: centerprint issued (%d chars)\n", (int)strlen (buf));
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

// Public entry point (ornament button, `vkq3d`, Swift error rollback): now a thin
// wrapper over the tri-state switch so 3D and VR share one sequencer.
void VKQ_Enter3D (bool on)
{
	VKQ_EnterMode (on ? VKQ_MODE_3D : VKQ_MODE_2D);
}

static void VKQ_Enter3DInternal (bool on)
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
		extern void VKQ_ModeReset2D (void);
		vkq3d_immersive_on = 0;
		VKQ_ModeReset2D ();
		VKQ_SetImmersiveMode (false); // sync the SwiftUI model (no-op if already closed)
		VKQ_Exit3DFinalize ();
	});
}

// ============================================================================
// VR mode (docs/VR-CHARTER.md R1). The third mode beside the 2D window and the
// 3D panel, in its own ImmersiveSpace with its own render loop (VKQVR.m).
// VKQ3D's declaration and loop are never touched — VR reuses the PANEL as its
// menu/console surface instead (charter A9).
// ============================================================================
extern void VKQ_SetVRSpace (int on);		 // VKQVisionApp.swift (@_cdecl)
extern void VKQ_SetVRHandsSwift (bool show); // upper-limb visibility in the full space
extern void VKQ_VR_SetActive (int on); // engine overlay patch 0018

/*
====================
VKQ_iOS_ApplyVRSettings -- R2

The settings store is the source of truth for VR preferences (it is crash-safe
and, unlike an archived cvar, cannot leak VR values into a 2D player's
config.cfg — charter §7). The engine reads cvars. This is the one place the two
meet, and it is called on VR entry AND on every settings change, so the grip
calibration sliders retune the weapon in the player's hand while they drag it.
That live loop is the deliverable: the ARKit held-controller frame and a Quake
.mdl's frame are two conventions that nothing guarantees agree, and discovering
the correction one OTA build at a time is how a sibling project spent several
device rounds on a pair of hands.
====================
*/
void VKQ_iOS_ApplyVRSettings (void)
{
	static const float kSnap[4] = {0.0f, 30.0f, 45.0f, 60.0f};
	// R6.1 item 3 — Smooth (index 0) is the default, here and in the row and in
	// the engine cvar. Three copies of a default is two too many, but they are
	// three different languages (settings store, UI row, cvar) and the simulator
	// asserts all three agree.
	int snapIdx = (int)lroundf (vkq_setting_f ("vrSnapTurn", 0.0f));
	if (snapIdx < 0 || snapIdx > 3)
		snapIdx = 0;
	Cvar_SetValue ("vkqvr_aimhand", vkq_setting_f ("vrAimHand", 1.0f) > 0.5f ? 1.0f : 0.0f);
	Cvar_SetValue ("vkqvr_movedir", (float)(int)lroundf (vkq_setting_f ("vrMoveDir", 0.0f)));
	Cvar_SetValue ("vkqvr_snapturn", kSnap[snapIdx]);
	// R4 part B — the laser is DELETED. vkqvr_laser is pinned to 0 from here so
	// an old config's "Beam + Dot" cannot resurrect a code path that no longer
	// exists, and vkqvr_crosshair is what the row now drives.
	Cvar_SetValue ("vkqvr_laser", 0.0f);
	Cvar_SetValue ("vkqvr_crosshair", vkq_setting_f ("vrCrosshair", 1.0f) > 0.5f ? 1.0f : 0.0f);
	Cvar_SetValue ("vkqvr_aimpitch", vkq_setting_f ("vrAimPitch", 0.0f));
	Cvar_SetValue ("vkqvr_turnspeed", vkq_setting_f ("vrTurnSpeed", 140.0f));
	// R2.1 fix 6 — the grip calibration is HARDCODED now. the user judged the R2
	// defaults right on device ("all good"), so they are constants rather than
	// six sliders a new player has to get past, and they are set here (not just
	// left at the cvar defaults) so a stale value from an R2 session cannot
	// survive the upgrade. `vkqvrgun` still moves them from the console for A/B.
	Cvar_SetValue ("vkqvr_gunpitch", -20.0f);
	Cvar_SetValue ("vkqvr_gunyaw", 0.0f);
	Cvar_SetValue ("vkqvr_gunroll", 0.0f);
	Cvar_SetValue ("vkqvr_gunfwd", 0.0f);
	Cvar_SetValue ("vkqvr_gunright", 0.0f);
	Cvar_SetValue ("vkqvr_gunup", 0.0f);
	Cvar_SetValue ("vkqvr_gunscale", vkq_setting_f ("vrGunScale", 1.0f));
	Cvar_SetValue ("vkqvr_flashscale", vkq_setting_f ("vrFlash", 0.5f));
	// R2.1 fix 5 — no "Weapon in Hand" toggle any more: hands tracked puts the
	// weapon in the hand, no hands puts it back at the face. The cvar stays as a
	// console-only force-off and is pinned on from here.
	Cvar_SetValue ("vkqvr_weapon", 1.0f);
	// R3 — holsters.
	// R6 part C4: Immersive is the default now — it is what the holsters, the
	// dual wield and the R6 fire scheduler all exist for.
	Cvar_SetValue ("vkqvr_style", vkq_setting_f ("vrStyle", 1.0f) > 0.5f ? 1.0f : 0.0f);
	// R6 part C4: holster zones are part of Immersive, not an option. The row is
	// gone and the cvar is pinned on; `vkqvrzones` still moves it for debugging.
	Cvar_SetValue ("vkqvr_zones", 1.0f);
	// R5 item 3 — the two holster sliders. Size is a fraction of the in-hand
	// size (R4 shipped a hardcoded 0.62; the default here is 0.80 because the user
	// asked for bigger), Forward moves the whole zone frame in metres and moves
	// the drawn model and the reach target together.
	Cvar_SetValue ("vkqvr_holscale", vkq_setting_f ("vrHolSize", 0.70f));
	// R6 part C4: "Holster Position", default +1.5 in (0.0381 m).
	Cvar_SetValue ("vkqvr_holfwd", vkq_setting_f ("vrHolFwd", 0.0381f));
	// R5 item 4 — the crosshair debug mode is a SETTING as well as a console
	// command, because the round it exists for is a headset round with no
	// console. It is deliberately not persisted as "on" by anything else.
	// R6 part C4: the huge-magenta debug draw has no ROW any more, but it is
	// still a console command — and `vkqvrxhair debug` works by writing this very
	// setting and calling this very function, so pinning the cvar to 0 here made
	// the command a silent no-op (caught by R5's magenta-pixel assertion, which
	// went from 21 303 pixels to 0). The stored value is force-zeroed ONCE, in the
	// R6 migration, which is what stops a stale "on" surviving the upgrade with no
	// row left to turn it off.
	Cvar_SetValue ("vkqvr_xhairdebug", vkq_setting_f ("vrXhairDebug", 0.0f) > 0.5f ? 1.0f : 0.0f);
}

static int vkq_mode = VKQ_MODE_2D;
int		   VKQ_GetMode (void) { return vkq_mode; }
void	   VKQ_ModeReset2D (void) { vkq_mode = VKQ_MODE_2D; }

// --- crash-safe cvar stash (charter A11 + §7) --------------------------------
// VR zeroes a set of ARCHIVED cvars (comfort motion, HUD, AA/scale). If the app
// dies inside VR — a crash, or a swipe-kill, which writes config.cfg from
// resign-active — those zeros would land in the player's 2D config permanently.
// So the stash is written to the SETTINGS STORE, not just a static: on the next
// launch a leftover stash is detected and restored before anything can use it.
static const char *const kVRStashCvars[] = {
	// A11 comfort: every camera motion the head does not own
	"cl_bob", "v_kicktime", "v_kickroll", "v_kickpitch", "v_idlescale", "cl_rollangle", "v_gunkick",
	// A9/A8: the eye carries the world, the panel carries the UI
	"scr_viewsize", "crosshair",
	// A5: the depth handoff needs a single-sample, unscaled render target
	"vid_fsaa", "r_scale",
	// R2/A8: cl_gun_fovscale stretches the viewmodel to compensate for a wide 2D
	// fov. In VR the gun is an object in the room held in a hand, and stretching
	// it is simply wrong — visibly so in stereo, where a squashed model reads as
	// the wrong shape rather than as a wider view.
	"cl_gun_fovscale",
};
static const float kVRStashValues[] = {
	0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 130.0f, 0.0f, 0.0f, 1.0f, 0.0f,
};
#define VKQ_VR_STASH_COUNT ((int)(sizeof (kVRStashCvars) / sizeof (kVRStashCvars[0])))

static NSString *vkq_vr_stash_key (int i) { return [NSString stringWithFormat:@"vrStash_%s", kVRStashCvars[i]]; }

static void VKQ_VR_StashComfort (void)
{
	if (vkq_setting_f ("vrStashActive", 0.0f) > 0.5f)
		return; // already stashed (re-entry without a clean exit)
	for (int i = 0; i < VKQ_VR_STASH_COUNT; i++)
		vkq_setting_set_f (vkq_vr_stash_key (i).UTF8String, Cvar_VariableValue (kVRStashCvars[i]));
	vkq_setting_set_f ("vrStashActive", 1.0f);
	for (int i = 0; i < VKQ_VR_STASH_COUNT; i++)
		Cvar_SetValue (kVRStashCvars[i], kVRStashValues[i]);
	NSLog (@"[vkquake] vr: stashed %d cvars (crash-safe, in the settings store)", VKQ_VR_STASH_COUNT);
}

static void VKQ_VR_RestoreComfort (void)
{
	if (vkq_setting_f ("vrStashActive", 0.0f) < 0.5f)
		return;
	for (int i = 0; i < VKQ_VR_STASH_COUNT; i++)
		Cvar_SetValue (kVRStashCvars[i], vkq_setting_f (vkq_vr_stash_key (i).UTF8String, kVRStashValues[i]));
	vkq_setting_set_f ("vrStashActive", 0.0f);
	NSLog (@"[vkquake] vr: restored %d cvars from the stash", VKQ_VR_STASH_COUNT);
}

// Called once at boot, after the engine has exec'd its config: if a stash
// survived, the last run died inside VR and the player's config is carrying VR's
// values. Put them back before the player ever sees them.
void VKQ_VR_RecoverStashOnLaunch (void)
{
	if (vkq_setting_f ("vrStashActive", 0.0f) < 0.5f)
		return;
	NSLog (@"[vkquake] vr: stale cvar stash found — the last run ended inside VR; restoring");
	VKQ_VR_RestoreComfort ();
	{
		// Make the repair stick even if THIS run is killed before it writes: the
		// archived cvars are already back, so flush them to config.cfg now.
		extern void Host_WriteConfiguration (void);
		Host_WriteConfiguration ();
	}
}

// --- entry / exit ------------------------------------------------------------

static void VKQ_EnterVRCommit (void)
{
	vkq_mode = VKQ_MODE_VR;
	// NOTE: the engine's VR branch is armed by the RENDER LOOP (VKQ_VR_Run), not
	// here. Arming it before the loop exists would make every engine frame wait out
	// the full rendezvous timeout for a pose nobody is publishing yet.
	VKQ_SetVRSpace (1);
	NSLog (@"[vkquake] vr: entry committed");
	// Park the 2D window AFTER entry settles — same rule as 3D: a window resize
	// ANIMATION concurrent with a vid restart wedges swapchain recreation.
	dispatch_after (dispatch_time (DISPATCH_TIME_NOW, (int64_t) (1.5 * NSEC_PER_SEC)), dispatch_get_main_queue (), ^{
		if (vkq_mode == VKQ_MODE_VR)
		{
			VKQ_3DSmallWindow ();
			VKQ_SetCurtain (true);
		}
	});
}

// The same two-phase entry the 3D panel uses (VKQHostViewController.m:87-110):
// the render-target resize destroys and recreates the present images, and
// committing mid-restart blits a dying texture. Poll until the width CHANGED.
static void VKQ_EnterVRPhase2 (int triesLeft, int initialWidth)
{
	extern void VKQ_Get3DPresentSize (int *w, int *h);
	int			pw = 0, ph = 0;
	VKQ_Get3DPresentSize (&pw, &ph);
	if (pw > 0 && pw != initialWidth)
	{
		NSLog (@"[vkquake] vr: provisional eye target ready (%dx%d)", pw, ph);
		VKQ_EnterVRCommit ();
		return;
	}
	if (triesLeft <= 0)
	{
		NSLog (@"[vkquake] vr: render-size restart slow — entering; it will land offscreen");
		VKQ_EnterVRCommit ();
		return;
	}
	dispatch_after (dispatch_time (DISPATCH_TIME_NOW, (int64_t) (0.1 * NSEC_PER_SEC)), dispatch_get_main_queue (),
					^{ VKQ_EnterVRPhase2 (triesLeft - 1, initialWidth); });
}

// Runs on the main thread after SwiftUI's dismissImmersiveSpace completes.
void VKQ_ExitVRFinalize (void)
{
	VKQ_VR_RestoreComfort ();
	VKQ_VR_WriteDiagnosticsNow (); // unthrottled: this is the last chance to record the session
	// R6.4 item 4: UNCONDITIONAL. This used to be gated on VKQ_Get3DMode(), which
	// is the flag Exit3DFinalize itself clears — so whichever of two racing
	// finalizes arrived second did nothing, and if the no-op arrived FIRST the
	// window stayed a parked card behind a curtain with the engine still
	// rendering offscreen. Exit3DFinalize is internally idempotent (it re-checks
	// the mode before the restart), so calling it always is both safe and the
	// only version that cannot leave the window parked.
	VKQ_Exit3DFinalize (); // window size, curtain, back to the window swapchain
	NSLog (@"[vkquake] vr: exit finalized (mode=%d, 3D=%d)", vkq_mode, VKQ_Get3DMode ());
}

static void VKQ_EnterVRNow (void)
{
	// Offscreen both-eyes mode, exactly as the 3D panel drives it. The real
	// per-eye size is read from the FIRST DRAWABLE inside the loop (charter A1 —
	// ~1920x1824 on device, not 16:9, so hardcoding would squash the world); this
	// provisional size only gets the present images off the parked window.
	extern void VKQ_Set3DRenderSize (int w, int h);
	extern void VKQ_Get3DPresentSize (int *w, int *h);
	extern void VKQ_Set3DBothEyes (int on);
	int			w0 = 0, h0 = 0;
	VKQ_iOS_Apply3DSettings ();
	VKQ_VR_StashComfort ();
	VKQ_Set3DBothEyes (1);
	// Comfort settings that live outside the engine's cvars.
	vkq_vrWorldScale = vkq_setting_f ("vrScale", 34.0f); // R6 C3: hardcoded, no row
	vkq_vrHeightOffset = vkq_setting_f ("vrHeight", 0.0f);
	vkq_vrRenderScale = vkq_setting_f ("vrRenderScale", 1.25f); // R6 C4
	VKQ_VR_SetShowHands (vkq_setting_f ("vrHands", 0.0f) > 0.5f);
	VKQ_iOS_ApplyVRSettings (); // R2: aim hand, snap turn, grip calibration, laser
	VKQ_Get3DPresentSize (&w0, &h0);
	VKQ_GetWindowSize (&vkq_pre3d_w, &vkq_pre3d_h);
	vkq3d_immersive_on = 1; // gates the render pause + enables the override path
	VKQ_Set3DMode (1);
	VKQ_Set3DRenderSize (2048, 2048);
	VKQ_SetCurtain (true);
	NSLog (@"[vkquake] vr: entry — render override %dx%d -> 2048x2048 (provisional)", w0, h0);
	if (w0 != 2048)
	{
		VKQ_EnterVRPhase2 (30, w0);
		return;
	}
	VKQ_EnterVRCommit ();
}

static void VKQ_ExitVRNow (void)
{
	// Exit order is load-bearing (charter §7): stop the render thread and WAIT,
	// THEN dismiss; the engine mode reset happens in the finalize callback.
	vkq_vrStop = 1;
	for (int i = 0; i < 200 && vkq_vrRunning; i++) // <= 2 s
		usleep (10 * 1000);
	NSLog (@"[vkquake] vr: exit — render thread stopped=%d (frames=%d)", !vkq_vrRunning, vkq_vrFrameCount);
	VKQ_VR_SetActive (0);
	vkq_mode = VKQ_MODE_2D;
	vkq3d_immersive_on = 0;
	VKQ_SetVRSpace (0); // dismiss; VKQ_ExitVRFinalize runs once it completes
}

// The tri-state switch (charter A1/A2). visionOS allows ONE immersive space at a
// time, so a direct 3D<->VR switch is sequenced as dismiss-then-open with the
// engine running throughout — the same shape sm64coopdx shipped.
void VKQ_EnterMode (int mode)
{
	if (!vkq_booted)
	{
		NSLog (@"[vkquake] EnterMode(%d) ignored pre-boot", mode);
		return;
	}
	if (mode < VKQ_MODE_2D || mode > VKQ_MODE_VR)
		return;
	if (mode == vkq_mode)
		return;

	if (vkq_mode != VKQ_MODE_2D && mode != VKQ_MODE_2D)
	{
		const int want = mode;
		NSLog (@"[vkquake] mode %d -> %d: dismiss first, then open", vkq_mode, want);
		VKQ_EnterMode (VKQ_MODE_2D);
		dispatch_after (dispatch_time (DISPATCH_TIME_NOW, (int64_t) (1.6 * NSEC_PER_SEC)), dispatch_get_main_queue (), ^{ VKQ_EnterMode (want); });
		return;
	}

	if (mode == VKQ_MODE_VR)
	{
		VKQ_EnterVRNow ();
		return;
	}
	if (mode == VKQ_MODE_3D)
	{
		vkq_mode = VKQ_MODE_3D;
		VKQ_Enter3DInternal (true);
		return;
	}
	// -> 2D
	if (vkq_mode == VKQ_MODE_VR)
	{
		VKQ_ExitVRNow ();
		return;
	}
	vkq_mode = VKQ_MODE_2D;
	VKQ_Enter3DInternal (false);
}

/*
 * VKQ_VR_Ended — the SYSTEM took the space away (Digital Crown, a system alert,
 * an app switch). R6.4 item 4.
 *
 * the user: pressing the crown in VR left him with the 2D window AND the parked
 * "Playing in VR" card, the engine still presenting to the VR target — "a
 * confused, stuck state... i found myself just needing to force quit".
 *
 * Three things were wrong here, and only the first is the famous one:
 *
 * 1. THE EXIT COULD SIMPLY NOT RUN. This is reached from the render loop's tail,
 *    and only when the loop exits — which needed the layer to report
 *    `invalidated`. A crown press that parks the layer in `paused` left the
 *    thread blocked inside wait_until_running forever (fixed in VKQVR.m; that
 *    branch is bounded now).
 *
 * 2. IT FINALIZED TWICE. Setting model.vr = false makes SwiftUI dismiss and then
 *    call VKQ_ExitVRFinalize itself, so the old code's own immediate call raced
 *    a second one — two window restores and two render-target restarts, 0.8 s
 *    apart, over a swapchain that was already being rebuilt.
 *
 * 3. THE UN-PARK WAS CONDITIONAL. VKQ_ExitVRFinalize only restores the window
 *    and drops the curtain `if (VKQ_Get3DMode())`. Whichever finalize lost the
 *    race found that already cleared and did nothing — and if the ordering put
 *    the no-op first, the window stayed a parked card behind a curtain with the
 *    engine still offscreen. That is the exact state he described.
 *
 * So: idempotent, ordered like the deliberate exit, and the dismissal is left to
 * SwiftUI's completion — the one path that knows when the space is actually gone.
 */
void VKQ_VR_Ended (void)
{
	NSLog (@"[vkquake] vr: space ended by the system (Crown or equivalent)");
	dispatch_async (dispatch_get_main_queue (), ^{
		static int inEnded = 0;
		if (inEnded || vkq_mode != VKQ_MODE_VR)
		{
			// Already handled — a deliberate exit that raced the system, or a
			// second notification for the same dismissal. Doing it twice is what
			// produced the two-window state.
			NSLog (@"[vkquake] vr: system-dismissal notice ignored (mode=%d, already handling=%d)", vkq_mode, inEnded);
			return;
		}
		extern void VKQ_TouchCommand (const char *cmd);
		inEnded = 1;
		VKQ_VR_SetActive (0);
		vkq_mode = VKQ_MODE_2D;
		vkq3d_immersive_on = 0;
		// Pause the game, so a player yanked out of VR mid-fight is not being
		// shot at by a world they cannot see. the user's ask was "safely exit to 2d
		// mode to save THAT state" — this is the half of it the engine owns.
		//
		// R6.5 item 2b: via the engine's own helper rather than a raw `pause`
		// command. `pause` is a TOGGLE — issuing it blindly unpaused a game the
		// player had already paused — and the helper is also what arms the
		// auto-resume, so the pause can never become the trap he hit ("no way to
		// unpause... i'd have to start or load a new game").
		{
			extern void VKQ_VR_AutoPause (void);
			VKQ_VR_AutoPause ();
		}
		// Config write NOW: a system dismissal is frequently the first half of a
		// swipe-kill, and swipe-kill is SIGKILL (charter Phase 1). This is the
		// same call the resign-active path makes, not a console command —
		// `savecfg` does not exist in this engine.
		{
			extern void Host_WriteConfiguration (void);
			Host_WriteConfiguration ();
		}
		// Tell SwiftUI the space is gone. Its onChange runs the dismiss (a no-op
		// for an already-dismissed space) and then VKQ_ExitVRFinalize, which is
		// the ONE place the window, curtain and render target come back.
		VKQ_SetVRSpace (0);
		// Belt and braces: if SwiftUI's completion never arrives (the space was
		// taken from under it, so its await may not fire), finalize anyway. The
		// finalize is idempotent — it no-ops when 3D mode is already cleared.
		dispatch_after (dispatch_time (DISPATCH_TIME_NOW, (int64_t) (1.2 * NSEC_PER_SEC)), dispatch_get_main_queue (), ^{
			VKQ_ExitVRFinalize ();
			inEnded = 0;
		});
	});
}

// Show/hide the player's real hands inside the full-immersion VR space. VR is
// always FULL immersion now (the user, 2026-08-10) so there is no surroundings
// switch any more — the only passthrough question left is the limbs, and the
// answer defaults to "hidden" because a player holding Sense controllers sees
// ghost hands where the weapon belongs.
void VKQ_VR_SetShowHands (bool show)
{
	vkq_setting_set_f ("vrHands", show ? 1.0f : 0.0f);
	VKQ_SetVRHandsSwift (show);
}

// --- console commands ---------------------------------------------------------

// vkqvr 1|0 — enter/leave VR (mirrors vkq3d, for the bridge and for configs)
static void VKQ_Cmd_VR (void)
{
	int on = (Cmd_Argc () > 1) ? atoi (Cmd_Argv (1)) : (VKQ_GetMode () != VKQ_MODE_VR);
	Con_Printf ("vkqvr: %s\n", on ? "entering VR" : "leaving VR");
	dispatch_async (dispatch_get_main_queue (), ^{ VKQ_EnterMode (on ? VKQ_MODE_VR : VKQ_MODE_2D); });
}

// vkqvrhands 0|1 — show the player's real hands inside the full VR space
static void VKQ_Cmd_VRHands (void)
{
	int show = (Cmd_Argc () > 1) ? atoi (Cmd_Argv (1)) : (vkq_setting_f ("vrHands", 0.0f) < 0.5f);
	VKQ_VR_SetShowHands (show != 0);
	Con_Printf ("vkqvrhands: %s\n", show ? "hands visible" : "hands hidden");
}

// vkqvrrenderscale <1.0-2.0> — supersample the eye target above the drawable's
// physical texture size. 1.0 (default) matches the memory that actually exists;
// higher buys back the sharpness the eye-tracked fovea can resolve, at a cost
// measured in presented Hz. Applies on the NEXT VR entry (the render target is
// sized once, on the loop's first drawable).
static void VKQ_Cmd_VRRenderScale (void)
{
	if (Cmd_Argc () > 1)
	{
		float s = atof (Cmd_Argv (1));
		if (s >= 1.0f && s <= 2.0f)
		{
			vkq_vrRenderScale = s;
			vkq_setting_set_f ("vrRenderScale", s);
		}
	}
	Con_Printf ("vkqvrrenderscale: %.2fx (applies on the next VR entry)\n", vkq_vrRenderScale);
}

// vkqvrscale <units-per-metre> — charter A3 world scale (default 39.37)
static void VKQ_Cmd_VRScale (void)
{
	if (Cmd_Argc () > 1)
	{
		float s = atof (Cmd_Argv (1));
		if (s >= 10.0f && s <= 200.0f)
		{
			vkq_vrWorldScale = s;
			vkq_setting_set_f ("vrScale", s);
		}
	}
	Con_Printf ("vkqvrscale: %.2f units/m\n", vkq_vrWorldScale);
}

// vkqvrheight <metres> — eye-height trim (+ = taller)
static void VKQ_Cmd_VRHeight (void)
{
	if (Cmd_Argc () > 1)
	{
		float h = atof (Cmd_Argv (1));
		if (h >= -1.5f && h <= 1.5f)
		{
			vkq_vrHeightOffset = h;
			vkq_setting_set_f ("vrHeight", h);
		}
	}
	Con_Printf ("vkqvrheight: %+.2f m\n", vkq_vrHeightOffset);
}

// vkqvrrecenter — re-derive the tracking alignment from the current head pose
static void VKQ_Cmd_VRRecenter (void)
{
	VKQ_VR_Recenter ();
	Con_Printf ("vkqvrrecenter: alignment will re-capture on the next tracked frame\n");
}

// vkqvrdiag — flush the diagnostics file NOW (it is also written automatically)
static void VKQ_Cmd_VRDiag (void)
{
	VKQ_VR_WriteDiagnosticsNow ();
	Con_Printf ("vkqvrdiag: Documents/vr-diagnostics.log written\n");
	for (int i = 0; i < VKQ_VR_STATUS_ROWS; i++)
		Con_Printf ("  [%d] %s\n", i, VKQ_VR_StatusLine (i));
}

// vkqvrpose [yaw pitch x y z] — synthetic head pose (no args = off). The
// simulator's own anchor is the identity, which makes eyeFromPlayer the identity
// and leaves charter A3's composition untested; a KNOWN pose makes every sign
// falsifiable on the sim (+yaw turns left, +pitch looks up, -z walks forward).
/*
 * VKQ_VR_NowSeq -- R6.1: A FRESHNESS STAMP THE ROLLING TAIL CANNOT EAT.
 *
 * zone_assert's freshness rule (R4's, and the reason this suite cannot report a
 * stale line as a fresh one) was implemented as "the count of ^PREFIX lines in
 * the file grew". That is sound only while the file is append-only, and it is
 * not: the diagnostics writer spends a 96 KB pinned budget and then sends
 * everything to a 120 KB rolling tail that, when full, DELETES ITS FIRST 60 KB.
 * A trim drops dozens of matching lines at once, so `after <= before` with the
 * app perfectly healthy — and zone_assert's verdict for that is "the app is up
 * but stopped writing lines", which is a hard die.
 *
 * The R6 artifacts show both halves of that: 2026-08-11's shipping log carries
 * the "pinned budget spent" marker AND zero surviving ZONENOW lines, i.e. the
 * roll had already trimmed inside a normal run. It is therefore a live candidate
 * explanation for the §7b intermittent "wedge", which only ever appeared at the
 * very end of a 45-minute session — exactly when the roll first fills. THAT IS A
 * HYPOTHESIS, NOT A FINDING: this round did not reproduce §7b and did not
 * investigate it (docs/VR-R6-NOTES.md §R6.1). What it did do is make the
 * instrument immune, so a later round measures the engine and not the logger.
 *
 * A monotone counter, written LAST, is never the part a front-trim removes.
 */
static void VKQ_VR_NowSeq (void)
{
	static unsigned seq = 0;
	char			line[32];
	snprintf (line, sizeof (line), "NOWSEQ %u", ++seq);
	Con_Printf ("%s\n", line);
	VKQ_VR_DiagPin (line);
}

// R6 part A — the fire scheduler, as a line. Ownership, the weapon-match gate's
// block count, handoffs and the per-hand shot tallies: everything the
// dual-wield assertions need, and everything a device round needs to say "my
// other gun jammed" as a number.
static void VKQ_Cmd_VRFire (void)
{
	char		buf[256], line[320];
	extern void VKQ_VR_FireDebugString (char *out, int len);
	extern void VKQ_VR_DiagPin (const char *line);
	VKQ_VR_FireDebugString (buf, (int)sizeof (buf));
	snprintf (line, sizeof (line), "FIRENOW %s", buf);
	Con_Printf ("%s\n", line);
	VKQ_VR_DiagPin (line);
	VKQ_VR_WriteDiagnosticsNow ();
}

// R6 part B1 — the holster body frame: where the head is in the player frame,
// where the torso estimate has got to, and how far it is lagging the head.
static void VKQ_Cmd_VRBody (void)
{
	char		buf[256], zones[512], line[832];
	extern void VKQ_VR_BodyFrameString (char *out, int len);
	extern void VKQ_VR_ZoneLayoutString (char *out, int len);
	extern void VKQ_VR_DiagPin (const char *line);
	VKQ_VR_BodyFrameString (buf, (int)sizeof (buf));
	VKQ_VR_ZoneLayoutString (zones, (int)sizeof (zones));
	snprintf (line, sizeof (line), "BODYNOW %s | zones %s", buf, zones);
	Con_Printf ("%s\n", line);
	VKQ_VR_DiagPin (line);
	VKQ_VR_WriteDiagnosticsNow ();
}

// R6 part D — the settings sheet's own row model, dumped. Section titles, row
// keys and the value each row would show, straight out of the builder the sheet
// runs on every open.
static void VKQ_Cmd_VRReset (void)
{
	extern void VKQ_iOS_ResetVRSettings (void);
	VKQ_iOS_ResetVRSettings ();
	Con_Printf ("vkqvrreset: VR settings back to the R6 defaults, height baseline cleared\n");
}

static void VKQ_Cmd_SettingsDump (void)
{
	extern const char *VKQ_iOS_SettingsDumpText (void);
	extern void		   VKQ_VR_DiagPin (const char *line);
	char			   line[8320];
	snprintf (line, sizeof (line), "SETTINGSNOW %s", VKQ_iOS_SettingsDumpText ());
	Con_Printf ("%s\n", line);
	VKQ_VR_DiagPin (line);
	VKQ_VR_WriteDiagnosticsNow ();
}

static void VKQ_Cmd_VRPose (void)
{
	if (Cmd_Argc () < 2)
	{
		vkq_vrSynthPose = 0;
		VKQ_VR_Recenter ();
		Con_Printf ("vkqvrpose: synthetic pose OFF (using the real device anchor)\n");
		return;
	}
	vkq_vrSynthPose = 1;
	vkq_vrSynthYaw = atof (Cmd_Argv (1));
	vkq_vrSynthPitch = (Cmd_Argc () > 2) ? atof (Cmd_Argv (2)) : 0.0f;
	vkq_vrSynthPos[0] = (Cmd_Argc () > 3) ? atof (Cmd_Argv (3)) : 0.0f;
	vkq_vrSynthPos[1] = (Cmd_Argc () > 4) ? atof (Cmd_Argv (4)) : 0.0f;
	vkq_vrSynthPos[2] = (Cmd_Argc () > 5) ? atof (Cmd_Argv (5)) : 0.0f;
	Con_Printf ("vkqvrpose: yaw=%.1f pitch=%.1f pos=(%.2f,%.2f,%.2f) m\n", vkq_vrSynthYaw, vkq_vrSynthPitch, vkq_vrSynthPos[0], vkq_vrSynthPos[1],
				vkq_vrSynthPos[2]);
}

// vkqvripd [metres] — synthesise a stereo eye pair on a MONO drawable (the
// simulator), so the A3 IPD arithmetic is checkable without the headset. 0 = off.
static void VKQ_Cmd_VRIPD (void)
{
	float m = (Cmd_Argc () > 1) ? atof (Cmd_Argv (1)) : 0.063f;
	vkq_vrSynthEyes = (m > 0.0001f) ? 1 : 0;
	if (vkq_vrSynthEyes)
		vkq_vrSynthIPD = m;
	Con_Printf ("vkqvripd: synthetic eyes %s (%.4f m) — re-enter VR to re-check\n", vkq_vrSynthEyes ? "ON" : "off", vkq_vrSynthIPD);
}

// --- R2: Sense controllers ----------------------------------------------------

static int VKQ_VR_ParseHand (const char *s)
{
	if (!s || !*s)
		return -1;
	if (*s == 'l' || *s == 'L' || *s == '0')
		return VKQ_SENSE_LEFT;
	if (*s == 'r' || *s == 'R' || *s == '1')
		return VKQ_SENSE_RIGHT;
	return -1;
}

// vkqvrhand <l|r> off | <l|r> <yaw> <pitch> <roll> <x> <y> <z>
//
// A synthetic hand pose, in TRACKING SPACE (ARKit metres: +x right, +y up, +z
// back; yaw +ve turns left, pitch +ve looks up) — the exact space and the exact
// boundary a real accessory anchor arrives at. Everything downstream is
// therefore the shipping code: the alignment chain, the player-frame transform,
// the aim angles, the weapon placement, the laser trace and the movement
// rotation. Without this the simulator, which has no controllers at all, could
// not falsify any of it.
static void VKQ_Cmd_VRHand (void)
{
	int hand = (Cmd_Argc () > 1) ? VKQ_VR_ParseHand (Cmd_Argv (1)) : -1;
	if (hand < 0)
	{
		Con_Printf ("usage: vkqvrhand <l|r> off\n       vkqvrhand <l|r> <yaw> <pitch> <roll> <x> <y> <z>   (degrees, metres)\n");
		return;
	}
	if (Cmd_Argc () < 3 || !q_strcasecmp (Cmd_Argv (2), "off"))
	{
		VKQ_Sense_SetSynthHand (hand, 0, 0, 0, 0, 0, 0, 0);
		Con_Printf ("vkqvrhand: %s synthetic hand OFF\n", hand ? "right" : "left");
		return;
	}
	{
		float yaw = atof (Cmd_Argv (2));
		float pitch = (Cmd_Argc () > 3) ? atof (Cmd_Argv (3)) : 0.0f;
		float roll = (Cmd_Argc () > 4) ? atof (Cmd_Argv (4)) : 0.0f;
		// A plausible resting hand if no position is given: 25 cm to the side,
		// 45 cm below eye level, 35 cm forward.
		float x = (Cmd_Argc () > 5) ? atof (Cmd_Argv (5)) : (hand ? 0.25f : -0.25f);
		float y = (Cmd_Argc () > 6) ? atof (Cmd_Argv (6)) : -0.45f;
		float z = (Cmd_Argc () > 7) ? atof (Cmd_Argv (7)) : -0.35f;
		VKQ_Sense_SetSynthHand (hand, 1, yaw, pitch, roll, x, y, z);
		Con_Printf ("vkqvrhand: %s yaw=%.1f pitch=%.1f roll=%.1f pos=(%.2f,%.2f,%.2f) m\n", hand ? "right" : "left", yaw, pitch, roll, x, y, z);
	}
}

// vkqvrhandbtn <l|r> <trigger|grip|a|b|stick|menu|none> [0|1]
static void VKQ_Cmd_VRHandButton (void)
{
	static unsigned held[2];
	int				hand = (Cmd_Argc () > 1) ? VKQ_VR_ParseHand (Cmd_Argv (1)) : -1;
	unsigned		bit = 0;
	int				down;
	if (hand < 0 || Cmd_Argc () < 3)
	{
		Con_Printf ("usage: vkqvrhandbtn <l|r> <trigger|grip|a|b|stick|menu|none> [0|1]\n");
		return;
	}
	if (!q_strcasecmp (Cmd_Argv (2), "trigger"))
		bit = VKQ_SENSE_TRIGGER;
	else if (!q_strcasecmp (Cmd_Argv (2), "grip"))
		bit = VKQ_SENSE_GRIP;
	else if (!q_strcasecmp (Cmd_Argv (2), "a"))
		bit = VKQ_SENSE_A;
	else if (!q_strcasecmp (Cmd_Argv (2), "b"))
		bit = VKQ_SENSE_B;
	else if (!q_strcasecmp (Cmd_Argv (2), "stick"))
		bit = VKQ_SENSE_STICK;
	else if (!q_strcasecmp (Cmd_Argv (2), "menu"))
		bit = VKQ_SENSE_MENU;
	down = (Cmd_Argc () > 3) ? atoi (Cmd_Argv (3)) : 1;
	if (!bit)
		held[hand] = 0;
	else if (down)
		held[hand] |= bit;
	else
		held[hand] &= ~bit;
	VKQ_Sense_SetSynthButtons (hand, held[hand]);
	Con_Printf ("vkqvrhandbtn: %s buttons = 0x%02x\n", hand ? "right" : "left", held[hand]);
}

// vkqvrhandstick <l|r> <x> <y> — hold a synthetic stick (move, turn, cycle).
static void VKQ_Cmd_VRHandStick (void)
{
	int hand = (Cmd_Argc () > 1) ? VKQ_VR_ParseHand (Cmd_Argv (1)) : -1;
	if (hand < 0 || Cmd_Argc () < 3)
	{
		Con_Printf ("usage: vkqvrhandstick <l|r> <x> <y>\n");
		return;
	}
	{
		float x = atof (Cmd_Argv (2));
		float y = (Cmd_Argc () > 3) ? atof (Cmd_Argv (3)) : 0.0f;
		VKQ_Sense_SetSynthStick (hand, x, y);
		Con_Printf ("vkqvrhandstick: %s = (%.2f, %.2f)\n", hand ? "right" : "left", x, y);
	}
}

// vkqvraim — the aim decoupling, as numbers, right now. Also written to the
// diagnostics file so a device round has it without a console, and so the
// simulator harness can assert on one line after each injected pose instead of
// waiting for the 5-second pacing window.
static void VKQ_Cmd_VRAim (void)
{
	extern void VKQ_VR_AimDebugString (char *out, int len);
	extern void VKQ_VR_DiagPin (const char *line);
	char		buf[384], line[448];
	VKQ_VR_AimDebugString (buf, (int)sizeof (buf));
	// AIMNOW, not AIM: the periodic AIM line lives in the rolling tail and can be
	// up to five seconds stale, so a harness reading "the last AIM line" could
	// easily read one from BEFORE the pose it just injected. This one is pinned,
	// distinct, and written on demand — an explicit measurement, never a sample.
	snprintf (line, sizeof (line), "AIMNOW %s", buf);
	Con_Printf ("%s\n", line);
	VKQ_VR_DiagPin (line);
	VKQ_VR_WriteDiagnosticsNow ();
}

// vkqvrzones — R3's holster layout and grip state, right now, pinned. Same rule
// as AIMNOW: the periodic HOLSTER line can be five seconds stale, so a harness
// (or a device round) that wants to know what a gesture just did asks for a
// measurement rather than reading a sample.
static void VKQ_Cmd_VRZones (void)
{
	extern void VKQ_VR_ZoneLayoutString (char *out, int len);
	extern void VKQ_VR_HolsterDebugString (char *out, int len);
	extern void VKQ_VR_EyeHeightDebugString (char *out, int len);
	extern void VKQ_VR_DiagPin (const char *line);
	char		zones[512], hol[384], eye[384], line[576];
	VKQ_VR_ZoneLayoutString (zones, (int)sizeof (zones));
	VKQ_VR_HolsterDebugString (hol, (int)sizeof (hol));
	VKQ_VR_EyeHeightDebugString (eye, (int)sizeof (eye));
	snprintf (line, sizeof (line), "ZONESNOW %s", zones);
	Con_Printf ("%s\n", line);
	VKQ_VR_DiagPin (line);
	snprintf (line, sizeof (line), "HOLSTERNOW %s", hol);
	Con_Printf ("%s\n", line);
	VKQ_VR_DiagPin (line);
	snprintf (line, sizeof (line), "EYENOW %s", eye);
	Con_Printf ("%s\n", line);
	VKQ_VR_DiagPin (line);
	// R5 item 3: the render/detection coincidence, measured, in the same
	// on-demand pinned family. R4's claim that these "cannot disagree" was a
	// comment; this is the number.
	{
		extern void VKQ_VR_HolsterGeomString (char *out, int len);
		char		hg[448];
		VKQ_VR_HolsterGeomString (hg, (int)sizeof (hg));
		snprintf (line, sizeof (line), "HOLGEOMNOW %s", hg);
		Con_Printf ("%s\n", line);
		VKQ_VR_DiagPin (line);
	}
	// R6 part C6: the cheats' ground truth, in the same family — so "what does
	// the God Mode switch show" is answerable without opening the sheet.
	{
		extern int VKQ_iOS_CheatsAvailable (void);
		extern int VKQ_iOS_GodModeActive (void);
		snprintf (line, sizeof (line), "GODNOW god=%s cheats=%s", VKQ_iOS_GodModeActive () ? "on" : "off",
				  VKQ_iOS_CheatsAvailable () ? "available" : "unavailable");
		Con_Printf ("%s\n", line);
		VKQ_VR_DiagPin (line);
	}
	// R6: the fire scheduler and the holster body frame join the same on-demand
	// family, so one command still answers everything the harness asserts on and
	// zone_assert's freshness rule covers the new lines too.
	{
		extern void VKQ_VR_FireDebugString (char *out, int len);
		extern void VKQ_VR_BodyFrameString (char *out, int len);
		// R6.1: the fixed layout joins the same on-demand family, so one command
		// still answers everything the harness asserts on and zone_assert's
		// freshness rule covers the new line too.
		extern void VKQ_VR_InputDebugString (char *out, int len);
		char		fire[256], body[256], input[256];
		VKQ_VR_FireDebugString (fire, (int)sizeof (fire));
		VKQ_VR_BodyFrameString (body, (int)sizeof (body));
		VKQ_VR_InputDebugString (input, (int)sizeof (input));
		snprintf (line, sizeof (line), "FIRENOW %s", fire);
		Con_Printf ("%s\n", line);
		VKQ_VR_DiagPin (line);
		snprintf (line, sizeof (line), "BODYNOW %s", body);
		Con_Printf ("%s\n", line);
		VKQ_VR_DiagPin (line);
		snprintf (line, sizeof (line), "MOVENOW %s", input);
		Con_Printf ("%s\n", line);
		VKQ_VR_DiagPin (line);
	}
	// R6.5 item 1: per-hand RENDERED model identity. HOLSTERNOW's hold=impN is
	// intent and stayed correct all through the dual-wield mirage; this is the line
	// that can actually see two hands drawing the same gun.
	{
		extern const char *VKQ_VR_ViewmodelDebugString (char *out, size_t len);
		char			   vm[320];
		VKQ_VR_ViewmodelDebugString (vm, sizeof (vm));
		snprintf (line, sizeof (line), "VIEWMODELNOW %s", vm);
		Con_Printf ("%s\n", line);
		VKQ_VR_DiagPin (line);
	}
	/*
	 * R6.1 — A FRESHNESS STAMP THE ROLLING TAIL CANNOT EAT.
	 *
	 * zone_assert's freshness rule (R4's, and the reason this suite cannot report
	 * a stale line as a fresh one) was implemented as "the count of ^PREFIX lines
	 * in the file grew". That is sound only while the file is append-only, and it
	 * is not: the diagnostics writer spends a 96 KB pinned budget and then sends
	 * everything to a 120 KB rolling tail that, when full, DELETES ITS FIRST
	 * 60 KB. A trim drops dozens of matching lines at once, so `after <= before`
	 * with the app perfectly healthy — and zone_assert's verdict for that is
	 * "the app is up but stopped writing lines", which is a hard die.
	 *
	 * The R6 artifacts show both halves of that: 2026-08-11's shipping log has the
	 * "pinned budget spent" marker AND zero surviving ZONENOW lines, i.e. the roll
	 * had already trimmed. It is therefore a live candidate explanation for the
	 * §7b intermittent "wedge", which only ever appeared at the very end of a
	 * 45-minute session — which is exactly when the roll first fills. THAT IS A
	 * HYPOTHESIS, NOT A FINDING: this round did not reproduce §7b and did not
	 * investigate it (see docs/VR-R6-NOTES.md §R6.1). What it did do is make the
	 * instrument immune, so a later round measures the engine and not the logger.
	 *
	 * A monotone counter, written LAST, is never the part a front-trim removes.
	 */
	VKQ_VR_NowSeq ();
	VKQ_VR_WriteDiagnosticsNow ();
}

// vkqvrstyle <0|1> — Convenience / Immersive, from a config or the bridge.
static void VKQ_Cmd_VRStyle (void)
{
	int v = (Cmd_Argc () > 1) ? atoi (Cmd_Argv (1)) : (vkq_setting_f ("vrStyle", 1.0f) < 0.5f);
	vkq_setting_set_f ("vrStyle", v ? 1.0f : 0.0f);
	VKQ_iOS_ApplyVRSettings ();
	Con_Printf ("vkqvrstyle: %s\n", v ? "IMMERSIVE (grip holds the weapon)" : "convenience (weapon always in hand)");
}

// vkqvrhud <0|1|2> — HUD High / Low / Off (R4 part D). The row is a setting
// rather than a cvar because the shell draws the HUD, so this is the only way a
// bridge-driven simulator round can screenshot High against Low.
static void VKQ_Cmd_VRHud (void)
{
	int v = (Cmd_Argc () > 1) ? atoi (Cmd_Argv (1)) : 0;
	if (v < 0 || v > 2)
		v = 0;
	vkq_setting_set_f ("vrHud", (float)v);
	Con_Printf ("vkqvrhud: %s\n", v == 0 ? "High" : (v == 1 ? "Low" : "Off"));
}

// vkqvrsharpen <0.0-1.0> — contrast-adaptive sharpening STRENGTH in the world
// blit (R5 item 6). R4 shipped a toggle at what is now 0.5; the top of the range
// is stronger than anything R4 could produce, and the user found that end "tough
// on the eyes while turning", which is exactly why it is a slider.
static void VKQ_Cmd_VRSharpen (void)
{
	float v = vkq_setting_f ("vrSharpen", 0.5f);
	if (Cmd_Argc () > 1)
	{
		v = atof (Cmd_Argv (1));
		if (v < 0.0f)
			v = 0.0f;
		if (v > 1.0f)
			v = 1.0f;
		vkq_setting_set_f ("vrSharpen", v);
	}
	Con_Printf ("vkqvrsharpen: %.0f%%%s\n", v * 100.0f, v < 0.001f ? " (off — the pass is skipped entirely)" : "");
}

// vkqvrxhair [on|off|debug] — the VR crosshair, and the mode that makes it
// falsifiable. DEBUG draws it huge, magenta and pinned 2 m along the aim ray
// whether or not the trace hits anything, so "is it drawn at all" can be
// answered by grepping a screenshot for magenta pixels (R5 item 4).
static void VKQ_Cmd_VRXhair (void)
{
	char buf[512];
	extern void VKQ_VR_CrosshairDebugString (char *out, int len);
	extern void VKQ_VR_DiagPin (const char *line);
	char		line[576];
	if (Cmd_Argc () > 1)
	{
		const char *a = Cmd_Argv (1);
		if (!q_strcasecmp (a, "debug"))
		{
			vkq_setting_set_f ("vrCrosshair", 1.0f);
			vkq_setting_set_f ("vrXhairDebug", 1.0f);
		}
		else if (!q_strcasecmp (a, "off") || !q_strcasecmp (a, "0"))
		{
			vkq_setting_set_f ("vrCrosshair", 0.0f);
			vkq_setting_set_f ("vrXhairDebug", 0.0f);
		}
		else
		{
			vkq_setting_set_f ("vrCrosshair", 1.0f);
			vkq_setting_set_f ("vrXhairDebug", 0.0f);
		}
		VKQ_iOS_ApplyVRSettings ();
	}
	VKQ_VR_CrosshairDebugString (buf, (int)sizeof (buf));
	// XHAIRNOW, pinned and on demand — the same rule AIMNOW and HOLSTERNOW
	// established: a harness asking what the reticle is doing must get a fresh
	// measurement, never a sample from up to five seconds ago.
	snprintf (line, sizeof (line), "XHAIRNOW %s", buf);
	Con_Printf ("%s\n", line);
	VKQ_VR_DiagPin (line);
	VKQ_VR_NowSeq (); // R6.1: xhair_assert's freshness rule, on the same stamp
	VKQ_VR_WriteDiagnosticsNow ();
}

// vkqvrhol [size] [forward-metres] — the two holster sliders, from the console.
static void VKQ_Cmd_VRHolster (void)
{
	char		buf[512], line[576];
	extern void VKQ_VR_HolsterGeomString (char *out, int len);
	extern void VKQ_VR_DiagPin (const char *line);
	if (Cmd_Argc () > 1)
		vkq_setting_set_f ("vrHolSize", atof (Cmd_Argv (1)));
	if (Cmd_Argc () > 2)
		vkq_setting_set_f ("vrHolFwd", atof (Cmd_Argv (2)));
	if (Cmd_Argc () > 1)
		VKQ_iOS_ApplyVRSettings ();
	VKQ_VR_HolsterGeomString (buf, (int)sizeof (buf));
	snprintf (line, sizeof (line), "HOLGEOMNOW %s", buf);
	Con_Printf ("%s\n", line);
	VKQ_VR_DiagPin (line);
	VKQ_VR_WriteDiagnosticsNow ();
}

// vkqvrsense — everything known about the controllers, in one place.
static void VKQ_Cmd_VRSense (void)
{
	VKQ_Sense_Start ();
	Con_Printf ("controllers : %s\n", VKQ_Sense_StatusControllers ());
	Con_Printf ("tracking    : %s\n", VKQ_Sense_StatusTracking ());
	Con_Printf ("inventory   :\n%s\n", VKQ_Sense_InventoryText ());
	VKQ_VR_WriteDiagnosticsNow ();
}

// vkqvrgun [fwd right up pitch yaw roll scale] — the grip calibration.
//
// R2.1 fix 6 removed the six sliders (the user judged the defaults right), so this
// is now the ONLY way to move them: a console/bridge A/B tool, writing the cvars
// DIRECTLY rather than through the settings store. Going through the store would
// be a no-op, because VKQ_iOS_ApplyVRSettings pins these to the shipped constants
// on every settings change — which is exactly what makes them constants.
static void VKQ_Cmd_VRGun (void)
{
	if (Cmd_Argc () >= 7)
	{
		Cvar_SetValue ("vkqvr_gunfwd", atof (Cmd_Argv (1)));
		Cvar_SetValue ("vkqvr_gunright", atof (Cmd_Argv (2)));
		Cvar_SetValue ("vkqvr_gunup", atof (Cmd_Argv (3)));
		Cvar_SetValue ("vkqvr_gunpitch", atof (Cmd_Argv (4)));
		Cvar_SetValue ("vkqvr_gunyaw", atof (Cmd_Argv (5)));
		Cvar_SetValue ("vkqvr_gunroll", atof (Cmd_Argv (6)));
		if (Cmd_Argc () > 7)
		{
			vkq_setting_set_f ("vrGunScale", atof (Cmd_Argv (7)));
			Cvar_SetValue ("vkqvr_gunscale", atof (Cmd_Argv (7)));
		}
	}
	else if (Cmd_Argc () > 1 && !q_strcasecmp (Cmd_Argv (1), "reset"))
	{
		vkq_setting_set_f ("vrGunScale", 1.0f);
		VKQ_iOS_ApplyVRSettings (); // puts every one of them back to the constant
	}
	Con_Printf ("vkqvrgun: offset fwd %.1f right %.1f up %.1f | rot pitch %.1f yaw %.1f roll %.1f | scale %.2f\n", Cvar_VariableValue ("vkqvr_gunfwd"),
				Cvar_VariableValue ("vkqvr_gunright"), Cvar_VariableValue ("vkqvr_gunup"), Cvar_VariableValue ("vkqvr_gunpitch"),
				Cvar_VariableValue ("vkqvr_gunyaw"), Cvar_VariableValue ("vkqvr_gunroll"), Cvar_VariableValue ("vkqvr_gunscale"));
}

// --- engine bootstrap ----------------------------------------------------------

@implementation VKQHostViewController

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.view.backgroundColor = UIColor.blackColor;
	/*
	 * Resilience: if the user closes the parked window (the X under it) during 3D,
	 * the app loses its only regular scene — audio dies and there is no Exit control
	 * left. Re-request the window session so the card comes back.
	 *
	 * R6.5 item 2a — THIS IS WHERE THE USER'S BLACK WINDOW CAME FROM, and it is worth
	 * writing down because the bug is in the PRECONDITION, not the action.
	 *
	 * The old test was "are we immersive, and did some window scene disconnect" —
	 * which assumes a disconnect means we lost our ONLY scene. On a Digital Crown
	 * exit that assumption is false and the timing makes it fire every time: the
	 * system tears the space down and disconnects a scene while `vkq3d_immersive_on`
	 * is still 1, because the flag is only cleared by VKQ_VR_Ended — which cannot run
	 * until the render loop notices the layer is gone, up to the two-second bound
	 * R6.4 put on it. So the handler requested a brand-new scene session on the way
	 * OUT of VR.
	 *
	 * The new scene then comes up with `vkq_booted` already YES, so viewDidAppear
	 * returns immediately and nothing ever renders into it. Its root view keeps the
	 * black background set above, forever. That is exactly the artifact he described:
	 * "another black window (no text on it)", closable by hand, next to a perfectly
	 * good 2D window.
	 *
	 * So test the actual precondition — "the app has no window scene left" — instead
	 * of inferring it. That is true when he closes the parked card by hand (the case
	 * this exists for) and false during any exit transition, with no dependence on
	 * which flag has been cleared yet.
	 */
	[NSNotificationCenter.defaultCenter addObserverForName:UISceneDidDisconnectNotification
		object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
			if (!vkq3d_immersive_on || ![n.object isKindOfClass:UIWindowScene.class])
				return;
			dispatch_after (dispatch_time (DISPATCH_TIME_NOW, (int64_t) (0.5 * NSEC_PER_SEC)), dispatch_get_main_queue (), ^{
				// Re-checked HERE, after the transition has settled, rather than at
				// notification time: during a crown exit the scene set is in flux and
				// the answer half a second later is the one that matters.
				int scenes = 0;
				for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
					if ([s isKindOfClass:UIWindowScene.class] && s.activationState != UISceneActivationStateUnattached)
						scenes++;
				if (scenes > 0)
				{
					NSLog (@"[vkquake] scene disconnected but %d window scene(s) remain — NOT reopening "
						   @"(this is the crown-exit path; reopening here is what produced the blank window)",
						   scenes);
					return;
				}
				if (!vkq3d_immersive_on)
				{
					NSLog (@"[vkquake] scene disconnected and immersive mode ended meanwhile — not reopening");
					return;
				}
				NSLog (@"[vkquake] the app has no window scene left during 3D/VR — requesting it back");
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
		Cmd_AddCommand2 ("vkqsettingsdump", VKQ_Cmd_SettingsDump, VKQ_CMD_SRC_COMMAND); // R6 D
		Cmd_AddCommand2 ("vkqvrreset", VKQ_Cmd_VRReset, VKQ_CMD_SRC_COMMAND);			// R6 C2
		Cmd_AddCommand2 ("vkqvrmsg", VKQ_Cmd_VRMsg, VKQ_CMD_SRC_COMMAND);				// R6.1 item 2
		// VR mode (docs/VR-CHARTER.md R1)
		Cmd_AddCommand2 ("vkqvr", VKQ_Cmd_VR, VKQ_CMD_SRC_COMMAND);
		Cmd_AddCommand2 ("vkqvrhands", VKQ_Cmd_VRHands, VKQ_CMD_SRC_COMMAND);
		Cmd_AddCommand2 ("vkqvrrenderscale", VKQ_Cmd_VRRenderScale, VKQ_CMD_SRC_COMMAND);
		Cmd_AddCommand2 ("vkqvrscale", VKQ_Cmd_VRScale, VKQ_CMD_SRC_COMMAND);
		Cmd_AddCommand2 ("vkqvrheight", VKQ_Cmd_VRHeight, VKQ_CMD_SRC_COMMAND);
		Cmd_AddCommand2 ("vkqvrrecenter", VKQ_Cmd_VRRecenter, VKQ_CMD_SRC_COMMAND);
		Cmd_AddCommand2 ("vkqvrdiag", VKQ_Cmd_VRDiag, VKQ_CMD_SRC_COMMAND);
		Cmd_AddCommand2 ("vkqvrpose", VKQ_Cmd_VRPose, VKQ_CMD_SRC_COMMAND);
		Cmd_AddCommand2 ("vkqvripd", VKQ_Cmd_VRIPD, VKQ_CMD_SRC_COMMAND);
		// R2 — Sense controllers (docs/VR-R2-NOTES.md)
		Cmd_AddCommand2 ("vkqvrsense", VKQ_Cmd_VRSense, VKQ_CMD_SRC_COMMAND);
		Cmd_AddCommand2 ("vkqvrzones", VKQ_Cmd_VRZones, VKQ_CMD_SRC_COMMAND);
		Cmd_AddCommand2 ("vkqvrstyle", VKQ_Cmd_VRStyle, VKQ_CMD_SRC_COMMAND);
		Cmd_AddCommand2 ("vkqvrhud", VKQ_Cmd_VRHud, VKQ_CMD_SRC_COMMAND);
		Cmd_AddCommand2 ("vkqvrsharpen", VKQ_Cmd_VRSharpen, VKQ_CMD_SRC_COMMAND);
		// R5 — the crosshair's own debug mode, and the holster sliders.
		Cmd_AddCommand2 ("vkqvrxhair", VKQ_Cmd_VRXhair, VKQ_CMD_SRC_COMMAND);
		Cmd_AddCommand2 ("vkqvrhol", VKQ_Cmd_VRHolster, VKQ_CMD_SRC_COMMAND);
		// R6 — the fire scheduler and the holster body frame.
		Cmd_AddCommand2 ("vkqvrfire", VKQ_Cmd_VRFire, VKQ_CMD_SRC_COMMAND);
		Cmd_AddCommand2 ("vkqvrbody", VKQ_Cmd_VRBody, VKQ_CMD_SRC_COMMAND);
		Cmd_AddCommand2 ("vkqvraim", VKQ_Cmd_VRAim, VKQ_CMD_SRC_COMMAND);
		Cmd_AddCommand2 ("vkqvrgun", VKQ_Cmd_VRGun, VKQ_CMD_SRC_COMMAND);
		Cmd_AddCommand2 ("vkqvrhand", VKQ_Cmd_VRHand, VKQ_CMD_SRC_COMMAND);
		Cmd_AddCommand2 ("vkqvrhandbtn", VKQ_Cmd_VRHandButton, VKQ_CMD_SRC_COMMAND);
		Cmd_AddCommand2 ("vkqvrhandstick", VKQ_Cmd_VRHandStick, VKQ_CMD_SRC_COMMAND);
		// Push the stored VR preferences into the engine cvars now that they
		// exist, so a config or a bridge session sees the player's real settings
		// rather than the compiled defaults.
		VKQ_iOS_ApplyVRSettings ();
		// Bring the controller observers up at boot: the SDL filter asks this
		// backend who owns each device while IN_StartupJoystick is still running.
		VKQ_Sense_Start ();
		// A crash or swipe-kill inside VR leaves the comfort/HUD cvar stash behind;
		// repair the player's config before anything can use the VR values (A11).
		{
			extern void VKQ_VR_RecoverStashOnLaunch (void);
			VKQ_VR_RecoverStashOnLaunch ();
		}
		NSLog (@"[vkquake] SwiftUI shell: engine booted, 3D + VR commands registered");
	});
}

@end
