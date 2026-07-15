#import <Foundation/Foundation.h>

// Remote console over TCP, opt-in via the VKQ_CONSOLE_BRIDGE=1 launch env var.
// A Mac-side `nc <phone> 27999` gets: every engine console line (tee'd from
// stdout) streamed out, and every line typed in fed to the engine's command
// buffer on the frame thread. See scripts/ios-console.sh.
void VKQ_iOS_ConsoleBridgeStart (void); // call once at launch (checks the env var itself)
void VKQ_iOS_ConsoleBridgeDrain (void); // call once per frame on the frame thread
