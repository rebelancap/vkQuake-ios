/*
 * ios_shell.m — minimal iOS shell glue for the vkQuake substrate spike.
 * SDL3 provides the app delegate, window, Metal view, input and audio; the
 * engine's main() (via SDL_main) drives everything through the display-link
 * callback (overlay patch 0002). This file only supplies the game-data path.
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

// C-callable: the app's Documents directory (Files-visible via
// UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace). Game data (id1/…)
// is imported/pushed here; the engine mounts it via -basedir (patch 0002).
const char *VKQ_iOS_DocumentsPath (void)
{
	static char buf[1024];
	NSString   *docs = [NSSearchPathForDirectoriesInDomains (NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
	if (docs)
		strncpy (buf, docs.UTF8String, sizeof (buf) - 1);
	else
		buf[0] = '\0';
	buf[sizeof (buf) - 1] = '\0';
	return buf;
}

// Which game-data sets are on disk. Classic id1 is accepted in either case
// (onboarding normalises to lowercase, but a Files-app drop may not be).
static BOOL vkq_has_pak (NSString *dir)
{
	NSFileManager *fm = NSFileManager.defaultManager;
	return [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"pak0.pak"]] ||
		   [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"PAK0.PAK"]];
}
int VKQ_iOS_HasRereleaseData (void)
{
	NSString *docs = [NSSearchPathForDirectoriesInDomains (NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
	return docs && vkq_has_pak ([docs stringByAppendingPathComponent:@"rerelease/id1"]) ? 1 : 0;
}
int VKQ_iOS_HasClassicData (void)
{
	NSString *docs = [NSSearchPathForDirectoriesInDomains (NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
	return docs && vkq_has_pak ([docs stringByAppendingPathComponent:@"id1"]) ? 1 : 0;
}

// C-callable: the engine basedir (read ONCE, at engine startup — main_sdl.c).
// Default: prefer the rerelease (KEX) data when present — Documents/rerelease/
// id1/pak0.pak — so the enhanced models/maps load; else the original Documents
// (id1/…). Mirrors the Steam rerelease layout.
// Issue #5: a player with BOTH sets picks one in iOS Settings → Game Data
// (`gameData`: 0 = 2021 re-release, 1 = classic). A choice whose data is missing
// falls back to whichever set exists, so a stale preference never strands the
// player on a basedir with no pak0.
const char *VKQ_iOS_BasedirPath (void)
{
	extern float vkq_setting_f (const char *key, float def);
	static char	 buf[1024];
	NSString	*docs = [NSSearchPathForDirectoriesInDomains (NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
	if (!docs)
	{
		buf[0] = '\0';
		return buf;
	}
	BOOL	  hasRer = VKQ_iOS_HasRereleaseData () != 0;
	BOOL	  hasCls = VKQ_iOS_HasClassicData () != 0;
	BOOL	  wantCls = vkq_setting_f ("gameData", 0.0f) > 0.5f;
	BOOL	  useRer = hasRer && !(wantCls && hasCls);
	NSString *base = useRer ? [docs stringByAppendingPathComponent:@"rerelease"] : docs;
	strncpy (buf, base.UTF8String, sizeof (buf) - 1);
	buf[sizeof (buf) - 1] = '\0';
	static BOOL logged;
	if (!logged)
	{
		logged = YES;
		// stdout too: this runs before the console tee exists, and NSLog alone
		// reaches only the unified log there. stdout, not stderr: boot.log is
		// opened separately for each, and the engine's stdout writes from offset
		// 0 overwrite anything stderr put there first.
		NSString *line = [NSString stringWithFormat:@"[vkquake] game data: %s (setting=%s, rerelease=%d classic=%d) basedir=%@",
													useRer ? "2021 re-release" : "classic", wantCls ? "classic" : "2021", hasRer, hasCls, base];
		NSLog (@"%@", line);
		fprintf (stdout, "%s\n", line.UTF8String);
		fflush (stdout);
	}
	return buf;
}

// Engine command buffer (cmd.c) + key binding table (keys.c), linked from libvkquake.a.
extern void	 Cbuf_AddText (const char *text);
extern char *keybindings[];
#define VKQ_K_ABUTTON	211 // keys.h enum values
#define VKQ_K_RSHOULDER 210

// vkQuake ships NO default gamepad button binds — a fresh install has ABUTTON
// etc. unbound, so a controller does nothing even once SDL opens it. Apply a sane
// console layout whenever A is unbound (fresh install, OR a config.cfg that was
// never saved with gamepad binds). Gating on the live keybinding — not a sentinel
// file — means it self-heals AND a real user rebind (A -> anything) is never
// clobbered. START->menu, BACK->scores(TAB), D-pad->move/turn are already
// automatic (in_sdl.c IN_KeyForControllerButton).
void VKQ_iOS_ApplyDefaultGamepadBinds (void)
{
	// Migrate the old RB=next-weapon default to the new weapon wheel (only if it's
	// still at that exact default, so a user rebind is preserved). Runs every launch,
	// independent of the fresh-install gate below.
	if (keybindings[VKQ_K_RSHOULDER] && !strcmp (keybindings[VKQ_K_RSHOULDER], "impulse 10"))
		Cbuf_AddText ("bind RSHOULDER \"+weaponwheel\"\n");

	if (keybindings[VKQ_K_ABUTTON] && keybindings[VKQ_K_ABUTTON][0])
		return; // A is already bound to something — leave the user's layout alone

	static const char *binds =
		"bind ABUTTON \"+jump\"\n"		  // A = jump (Quake console standard)
		"bind BBUTTON \"+movedown\"\n"	  // B = swim/crouch down
		"bind YBUTTON \"impulse 10\"\n"	  // Y = next weapon
		"bind XBUTTON \"+attack\"\n"	  // X = fire (alt)
		"bind RTRIGGER \"+attack\"\n"	  // RT = fire
		"bind LTRIGGER \"+jump\"\n"		  // LT = jump (alt)
		"bind RSHOULDER \"+weaponwheel\"\n" // RB = weapon wheel (hold)
		"bind LSHOULDER \"impulse 12\"\n"	// LB = previous weapon (inventory wheel later)
		"bind LTHUMB \"+speed\"\n"		  // L3 = run
		"bind RTHUMB \"+movedown\"\n"	  // R3 = crouch
		"echo \"vkQuake: applied default controller bindings\"\n";
	Cbuf_AddText (binds);
}
