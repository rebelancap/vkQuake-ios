// VKQImmersive.h — visionOS stereoscopic "3D screen" render loop (CompositorServices).
#import <CompositorServices/CompositorServices.h>

// Entry point invoked from the SwiftUI CompositorLayer render closure on a
// dedicated thread; blocks running the frame loop until the layer is
// invalidated or vkq_immStop is set.
void VKQ_Immersive_Run (cp_layer_renderer_t layer_renderer);

// Graceful-shutdown handshake (see VKQHostViewController's VKQ_Enter3D):
// the shell sets vkq_immStop and waits for vkq_immRunning to clear BEFORE
// dismissing the immersive space, so the render thread never touches a
// layerRenderer SwiftUI is tearing down.
extern volatile int vkq_immStop;
extern volatile int vkq_immRunning;
extern int			vkq_immFrameCount;

// Live panel tuning (console cmd vkq3dtune + the Vision Pro settings section).
// halfH <= 0 leaves the panel height unchanged (console compat).
void VKQ_Set3DPanel (float dist, float halfW, float halfH);
void VKQ_Set3DHeight (float h); // POSITION height (metres above eye level)
void VKQ_Set3DDim (float dim);	// surroundings dimming 0..1 (0=passthrough, 1=void)
void VKQ_Recenter3D (void);		// re-anchor the panel to the current head pose

// Eye-tracked foveation kill switch, read at CompositorLayer config time
// (VKQVisionApp.swift). 1 = enabled (default): concentrates rasterization
// density at the gaze point, de-blurring the 3D panel; 0 = off. Persisted in
// settings — toggle with the `vkq3dfov` console command, then re-enter 3D (the
// A/B path, and the recovery path if a future OS rejects the foveated config).
int	 VKQ_Get3DFoveationWanted (void);
void VKQ_Set3DFoveation (int on);
