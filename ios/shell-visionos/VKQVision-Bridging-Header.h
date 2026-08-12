// VKQVision-Bridging-Header.h — ObjC/C surface exposed to VKQVisionApp.swift.
#import "VKQHostViewController.h"
#import "VKQImmersive.h"
#import "VKQVR.h" // first-person VR mode (docs/VR-CHARTER.md R1)

void VKQ_BeaconMark (const char *stage);	 // VKQLaunchBeacon.m — launch forensics
void VKQ_iOS_PresentSettings (void);		 // ios_settings.m — UIKit modal (2D path)
UIViewController *VKQ_iOS_MakeSettingsNav (void); // ios_settings.m — sheet content
