/*
 * ios_audio.m — AVAudioSession policy + the engine's master mix gain.
 *
 * Two knobs live here, both surfaced in the iOS Settings "Audio" section:
 *
 *   audioMode   what happens when another app is already playing (Music, a
 *               podcast, ...). Three of the five modes are pure session
 *               category/option choices that iOS enforces for us; the other two
 *               ("lower/mute Quake") need the engine to attenuate its own mix,
 *               which overlay patch 0014 exposes as VKQ_SetSoundGain().
 *   gameVolume  a plain master volume, multiplied into the same gain.
 *
 * Who owns the session: SDL does, nominally. SDL_coreaudio.m's
 * UpdateAudioSession() sets the category when it opens/closes an audio device
 * and whenever ITS idea of category/options changes, and it always adds
 * DuckOthers to Playback. So we cannot set the category once and walk away — we
 * re-assert on every route change / interruption / foreground, and the 4 Hz poll
 * in VKQ_iOS_AudioTick() heals anything SDL resets in between. The one thing we
 * cannot fix after the fact is the FIRST activation (that is what interrupts
 * other apps' audio), so VKQ_iOS_AudioBoot() steers SDL with SDL_AUDIO_CATEGORY
 * before Host_Init.
 */
#import "ios_audio.h"
#import "ios_settings.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <math.h>
#include <stdlib.h>

extern void VKQ_SetSoundGain (float g); // engine: snd_dma.c, overlay patch 0014

// How far "Lower Game Audio" pulls the game down: -13 dB. Loud enough to still
// hear the shambler behind you, quiet enough to follow a podcast over it.
#define VKQ_DUCK_GAIN 0.22f
// Gain ramp time constant. A hard cut on "music started" is audible as a click
// on a sustained ambient loop; ~0.2 s of exponential glide is not.
#define VKQ_GAIN_TAU 0.20f

NSArray<NSString *> *VKQ_iOS_AudioModeTitles (void)
{
	return @[ @"Stop Other Audio", @"Play Both", @"Lower Other Audio", @"Lower Game Audio", @"Mute Game Audio" ];
}

NSArray<NSString *> *VKQ_iOS_AudioModeDetails (void)
{
	return @[
		@"Music and podcasts stop when vkQuake starts.",
		@"Both play together, neither one quieter.",
		@"Music and podcasts drop to the background; game audio stays full.",
		@"Game audio drops to the background while another app is playing.",
		@"Game audio goes silent while another app is playing.",
	];
}

static VKQAudioMode vkq_audio_mode (void)
{
	int m = (int)lroundf (vkq_setting_f ("audioMode", (float)VKQ_AUDIO_DUCK_OTHERS));
	if (m < 0 || m >= VKQ_AUDIO_MODE_COUNT)
		m = VKQ_AUDIO_DUCK_OTHERS;
	return (VKQAudioMode)m;
}

// The category/options this mode wants. Playback throughout (a game should keep
// playing with the ring switch off, which is what Playback buys over Ambient);
// only the mixability bits differ.
static NSUInteger vkq_audio_options (VKQAudioMode m)
{
	switch (m)
	{
	case VKQ_AUDIO_STOP_OTHERS:
		return 0; // non-mixable: activating the session interrupts the other app
	case VKQ_AUDIO_DUCK_OTHERS:
		return AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionDuckOthers;
	default:
		return AVAudioSessionCategoryOptionMixWithOthers; // we do our own attenuating, if any
	}
}

// ---------------------------------------------------------------------------
static BOOL	  vkq_other_playing;   // cached: another app is producing audio
static float  vkq_gain_target = 1; // where the mix gain is heading
static float  vkq_gain_cur = -1;   // what the engine currently has (-1 = never set)
static double vkq_poll_last;

static BOOL vkq_query_other_playing (AVAudioSession *s)
{
	// isOtherAudioPlaying is the broad "someone else has sound out" answer;
	// secondaryAudioShouldBeSilencedHint is the narrower "another app is playing
	// PRIMARY audio (Music, a podcast)". Either one means the user is listening
	// to something that is not us.
	return s.isOtherAudioPlaying || s.secondaryAudioShouldBeSilencedHint;
}

static void vkq_audio_recompute_target (void)
{
	VKQAudioMode m = vkq_audio_mode ();
	float		 duck = 1.0f;
	if (vkq_other_playing)
	{
		if (m == VKQ_AUDIO_DUCK_GAME)
			duck = VKQ_DUCK_GAIN;
		else if (m == VKQ_AUDIO_MUTE_GAME)
			duck = 0.0f;
	}
	float master = vkq_setting_f ("gameVolume", 1.0f);
	master = fmaxf (0.0f, fminf (1.0f, master));
	float t = master * duck;
	if (fabsf (t - vkq_gain_target) > 0.0005f)
		NSLog (@"[vkquake] audio: mix gain -> %.2f (volume %.2f, duck %.2f, other %s)", t, master, duck, vkq_other_playing ? "yes" : "no");
	vkq_gain_target = t;
}

void VKQ_iOS_AudioApply (void)
{
	AVAudioSession *s = AVAudioSession.sharedInstance;
	VKQAudioMode	m = vkq_audio_mode ();
	NSUInteger		want = vkq_audio_options (m);
	NSError		   *err = nil;

	if (![s.category isEqualToString:AVAudioSessionCategoryPlayback] || s.categoryOptions != want)
	{
		if (![s setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:want error:&err])
			NSLog (@"[vkquake] audio: setCategory(mode %d, opts %lu) failed: %@", (int)m, (unsigned long)want, err);
		else
			NSLog (@"[vkquake] audio: session -> Playback opts %lu (mode %d)", (unsigned long)want, (int)m);
	}

	// Switching TO the non-mixable mode mid-session only interrupts the other app
	// when the session (re)activates. setActive:YES on an already-active session
	// is a no-op, so if the other app is still going, bounce it once. Losing that
	// race is not fatal — the boot hint makes the next launch correct regardless.
	if (m == VKQ_AUDIO_STOP_OTHERS)
	{
		[s setActive:YES error:nil];
		if (vkq_query_other_playing (s))
		{
			[s setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
			if (![s setActive:YES error:&err])
				NSLog (@"[vkquake] audio: reactivate to interrupt other audio failed: %@", err);
		}
	}

	// Keep SDL pointed at the same category, so its next UpdateAudioSession (a
	// route change, a device re-open) does not undo the choice above. The
	// environment variable outranks SDL_SetHint, which is exactly what we want.
	if (m == VKQ_AUDIO_STOP_OTHERS)
		setenv ("SDL_AUDIO_CATEGORY", "playback", 1); // SDL clears MixWithOthers for this one
	else
		unsetenv ("SDL_AUDIO_CATEGORY"); // SDL's default is Playback + MixWithOthers

	vkq_other_playing = vkq_query_other_playing (s);
	vkq_audio_recompute_target ();
}

void VKQ_iOS_AudioBoot (void)
{
	// Before SDL opens the audio device: its first setActive:YES is the moment
	// other apps get interrupted, and only a non-mixable category does that.
	if (vkq_audio_mode () == VKQ_AUDIO_STOP_OTHERS)
		setenv ("SDL_AUDIO_CATEGORY", "playback", 1);
	else
		unsetenv ("SDL_AUDIO_CATEGORY");

	NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
	// Every one of these is a moment SDL may have re-set the category behind us,
	// or the "is anyone else playing" answer may have changed.
	for (NSNotificationName n in @[
			 AVAudioSessionRouteChangeNotification, AVAudioSessionInterruptionNotification,
			 AVAudioSessionSilenceSecondaryAudioHintNotification, UIApplicationDidBecomeActiveNotification
		 ])
		[nc addObserverForName:n
						object:nil
						 queue:NSOperationQueue.mainQueue
					usingBlock:^(NSNotification *note) { VKQ_iOS_AudioApply (); }];

	NSLog (@"[vkquake] audio: boot mode %d", (int)vkq_audio_mode ());
}

void VKQ_iOS_AudioTick (void)
{
	double now = CACurrentMediaTime ();
	static double last_frame;
	double		  dt = last_frame ? now - last_frame : 0;
	last_frame = now;

	// Poll at 4 Hz: the notifications above cover the common cases, but nothing
	// posts when the user merely hits play in another app while we are frontmost,
	// and SDL can quietly re-add DuckOthers on a device re-open.
	if (now - vkq_poll_last >= 0.25)
	{
		vkq_poll_last = now;
		AVAudioSession *s = AVAudioSession.sharedInstance;
		BOOL			other = vkq_query_other_playing (s);
		VKQAudioMode	m = vkq_audio_mode ();
		if (other != vkq_other_playing)
		{
			vkq_other_playing = other;
			NSLog (@"[vkquake] audio: other app audio %s", other ? "started" : "stopped");
		}
		if (s.categoryOptions != vkq_audio_options (m) || ![s.category isEqualToString:AVAudioSessionCategoryPlayback])
			VKQ_iOS_AudioApply (); // SDL (or iOS) changed it under us — put it back
		vkq_audio_recompute_target ();
	}

	// Glide toward the target so duck/unduck and slider drags are not a step.
	if (vkq_gain_cur < 0.0f)
		vkq_gain_cur = vkq_gain_target; // first frame: no ramp from silence
	else if (dt > 0 && dt < 0.5)
	{
		float a = 1.0f - expf (-(float)dt / VKQ_GAIN_TAU);
		vkq_gain_cur += (vkq_gain_target - vkq_gain_cur) * a;
		if (fabsf (vkq_gain_target - vkq_gain_cur) < 0.001f)
			vkq_gain_cur = vkq_gain_target;
	}
	else
		vkq_gain_cur = vkq_gain_target;

	static float applied = -1;
	if (vkq_gain_cur != applied)
	{
		applied = vkq_gain_cur;
		VKQ_SetSoundGain (vkq_gain_cur);
	}
}
