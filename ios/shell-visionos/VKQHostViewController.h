// VKQHostViewController.h — UIKit host for the engine inside the SwiftUI shell.
#import <UIKit/UIKit.h>

@interface VKQHostViewController : UIViewController
@end

// Enter/leave the stereoscopic immersive space (safe from any thread; hops to
// main). Called by the ornament button (Swift) and the `vkq3d` console command.
void VKQ_Enter3D (bool on);

// Called by the immersive render loop when the space is dismissed by the
// system/Digital Crown (not by our own button path).
void VKQ_Immersive_Ended (void);

// Called (main thread) once dismissImmersiveSpace has completed — returns the
// engine to the window swapchain, drops the curtain, restores window size.
void VKQ_Exit3DFinalize (void);

// Push the persisted Vision Pro panel/stereo settings (also called live by the
// settings sliders).
void VKQ_iOS_Apply3DSettings (void);
