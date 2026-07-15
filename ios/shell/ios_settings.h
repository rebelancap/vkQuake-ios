#pragma once
#import <UIKit/UIKit.h>

// NSUserDefaults-backed settings (read live by the touch overlay every frame).
float vkq_setting_f (const char *key, float def);
void  vkq_setting_set_f (const char *key, float val);

// Native settings panel, presented over the key window (long-press the ≡ button).
void VKQ_iOS_PresentSettings (void);

// Push cvar-/engine-backed settings (menu size, always-run) into the engine.
// Call at boot and whenever a relevant setting changes.
void VKQ_iOS_ApplySettingsToEngine (void);
