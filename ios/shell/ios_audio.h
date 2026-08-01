#pragma once
#import <Foundation/Foundation.h>

// How vkQuake's sound behaves when another app (Music, a podcast, ...) is
// already playing. Stored in the "audioMode" setting; see ios_audio.m.
typedef enum
{
	VKQ_AUDIO_STOP_OTHERS = 0, // non-mixable session: the other app is interrupted
	VKQ_AUDIO_MIX = 1,		   // both at full volume
	VKQ_AUDIO_DUCK_OTHERS = 2, // the other app is lowered by iOS (default)
	VKQ_AUDIO_DUCK_GAME = 3,   // WE lower ourselves while the other app plays
	VKQ_AUDIO_MUTE_GAME = 4,   // WE go silent while the other app plays
	VKQ_AUDIO_MODE_COUNT
} VKQAudioMode;

// Row titles / one-line explanations for the settings picker (index = mode).
NSArray<NSString *> *VKQ_iOS_AudioModeTitles (void);
NSArray<NSString *> *VKQ_iOS_AudioModeDetails (void);

// Called from the engine's main() BEFORE Host_Init opens SDL's audio device.
void VKQ_iOS_AudioBoot (void);
// Re-assert the session category/options and recompute the mix gain. Called
// from VKQ_iOS_ApplySettingsToEngine and whenever the audio route changes.
void VKQ_iOS_AudioApply (void);
// Per-frame: polls "is another app playing" and ramps the engine's mix gain.
void VKQ_iOS_AudioTick (void);
