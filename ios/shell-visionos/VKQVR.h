// VKQVR.h — first-person VR mode for visionOS (docs/VR-CHARTER.md R1).
//
// The third mode beside the 2D window and the 3D panel: a fully immersive space
// where the Quake world surrounds the player at life scale. The compositor loop
// in VKQVR.m owns the head pose and the per-eye matrices; the engine renders both
// eyes through them (overlay patch 0018) and this loop blits each eye into its
// drawable view.
//
// The 3D panel (VKQImmersive.m) is deliberately untouched — VR reuses it as its
// menu/console surface (charter A9) by drawing the same world-locked quad
// whenever the engine reports a non-gameplay frame.
#import <CompositorServices/CompositorServices.h>

// Render-loop entry, invoked from the SwiftUI CompositorLayer closure on a
// dedicated thread (mirrors VKQ_Immersive_Run). Blocks until the layer is
// invalidated or vkq_vrStop is set.
void VKQ_VR_Run (cp_layer_renderer_t layer_renderer);

// Graceful-shutdown handshake, identical in shape to the 3D panel's: the shell
// sets vkq_vrStop and waits for vkq_vrRunning to clear BEFORE dismissing the
// space, so the render thread never touches a layerRenderer SwiftUI is tearing
// down.
extern volatile int vkq_vrStop;
extern volatile int vkq_vrRunning;
extern int			vkq_vrFrameCount;

// Charter A3 world scale: Quake units per metre (1 unit ~ 1 inch). Settings
// slider + `vkqvrscale`.
extern float vkq_vrWorldScale;

// Eye-height calibration: metres added to the player's eye point. "Calibrate
// Height" captures the current HMD height into it; the slider trims it.
extern float vkq_vrHeightOffset;

// R1.1 — eye render supersampling. The engine target is the view's PHYSICAL
// drawable texture times this (1.0 default, 1.0-2.0). The physical size is the
// memory that actually exists, but it slightly under-supplies what the
// eye-tracked fovea can resolve; this is the knob that buys sharpness back once
// the frame budget allows it. Read once per VR entry — the render target is
// sized on the loop's first drawable.
extern float vkq_vrRenderScale;

// Re-derive the tracking-space alignment from the CURRENT head pose, carrying
// the head's yaw into the body yaw so the view does not jump (charter A6).
void VKQ_VR_Recenter (void);

// Capture the current HMD height as "standing height" — the calibration action.
void VKQ_VR_CalibrateHeight (void);

// --- simulator coverage for the A3 chain -------------------------------------
// The Vision Pro SIMULATOR vends ONE view with an identity eye transform and a
// device anchor at the origin, so eyeFromPlayer comes out as the IDENTITY there:
// the world would render correctly even if every sign in the composition were
// wrong. These overrides substitute a KNOWN head pose / eye pair so the chain is
// falsifiable on the simulator instead of only in the headset (R0 finding 2).
extern int	 vkq_vrSynthPose;	// 1 = use the synthetic head pose below
extern float vkq_vrSynthYaw;	// degrees, +ve = turn LEFT (ARKit +Y rotation)
extern float vkq_vrSynthPitch;	// degrees, +ve = look UP
extern float vkq_vrSynthPos[3]; // metres, ARKit convention (x right, y up, z back)
extern int	 vkq_vrSynthEyes;	// 1 = synthesise a stereo pair on a mono drawable
extern float vkq_vrSynthIPD;	// metres between the synthetic eyes

// --- diagnostics (charter standing rule) -------------------------------------
// EVERY device-round number lands in Documents/vr-diagnostics.log, readable
// in-headset through Files over OTA. A console-only diagnostic is a defect: the
// R0 headset round lost its contract and IPD numbers exactly that way.
void  VKQ_VR_WriteDiagnostics (void);
// Unthrottled flush (loop exit, `vkqvrdiag`, the settings action). The throttled
// one above coalesces to 1 Hz — R1 rewrote a 200 KB file at up to 90 Hz.
void  VKQ_VR_WriteDiagnosticsNow (void);
// One-line status strings for the Vision Pro settings rows (row 0..N-1):
//   0 drawable  1 IPD check  2 pacing  3 eye height  4 mode  5 render target
//   6 depth  7 controllers  8 hand tracking  9 aim  10 holsters
//   11 crosshair  12 holster geometry
// 7-9 are R2's: the device round must be able to answer "did the SpatialGamepad
// declaration work" from the settings sheet, without a console. 10 is R3's, and
// row 3 now carries the whole standing-height derivation rather than one number.
// 11 and 12 are R5's, and both exist for the same reason: the crosshair and the
// holster placement were verified as NUMBERS for two rounds while being wrong as
// PIXELS and as CENTIMETRES, and a row that says "0.0 px" or "err 6.1u" is the
// difference between a device round that reports a symptom and one that reports
// a measurement.
#define VKQ_VR_STATUS_ROWS 13
const char *VKQ_VR_StatusLine (int idx);

// Diagnostics sinks shared with VKQSenseController.m, so controller facts land
// in the same pinned section as the drawable contract and the IPD check.
void VKQ_VR_DiagPin (const char *line);
void VKQ_VR_DiagRoll (const char *line);

// Mode plumbing (VKQHostViewController.m). 0 = 2D window, 1 = 3D panel, 2 = VR.
#define VKQ_MODE_2D 0
#define VKQ_MODE_3D 1
#define VKQ_MODE_VR 2
void VKQ_EnterMode (int mode);
int	 VKQ_GetMode (void);
void VKQ_VR_Ended (void);		 // system/Crown dismissal reconcile
void VKQ_ExitVRFinalize (void);	 // post-dismiss cleanup (main thread)
// VR is always FULL immersion (the user, 2026-08-10) — the passthrough/Full switch
// is gone. The only passthrough question left is whether the player's own hands
// show through; default hidden.
void VKQ_VR_SetShowHands (bool show);
