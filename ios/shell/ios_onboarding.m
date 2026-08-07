/*
 * ios_onboarding.m — first-run game-data import.
 *
 * The app ships with no game data. vkQuake's main() (SDL_main) calls
 * VKQ_iOS_EnsureGameData() BEFORE Host_Init: if no data is present it puts up a
 * full-screen card with a Files folder picker, copies the chosen data into
 * Documents following the Steam layout, and blocks (pumping the run loop) until
 * data lands — then the engine proceeds with data in place. Adapted from
 * q2repro-ios's onboarding.
 */
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

typedef int qboolean;

static NSString *VKQ_Docs (void)
{
	return NSSearchPathForDirectoriesInDomains (NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

qboolean VKQ_iOS_HasGameData (void)
{
	NSFileManager *fm = NSFileManager.defaultManager;
	NSString	  *d = VKQ_Docs ();
	// lowercase pak on the case-sensitive container; accept classic or rerelease id1
	for (NSString *rel in @[ @"rerelease/id1/pak0.pak", @"id1/pak0.pak", @"id1/PAK0.PAK" ])
		if ([fm fileExistsAtPath:[d stringByAppendingPathComponent:rel]])
			return 1;
	return 0;
}

// ---------------------------------------------------------------------------

@interface VKQOnboard : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIView   *card;
@end

static VKQOnboard   *g_onboard;
static volatile BOOL g_onboard_done;

@implementation VKQOnboard

- (UIWindowScene *)scene
{
	for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
		if ([s isKindOfClass:UIWindowScene.class] && s.activationState != UISceneActivationStateUnattached)
			return (UIWindowScene *)s;
	for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
		if ([s isKindOfClass:UIWindowScene.class])
			return (UIWindowScene *)s;
	return nil;
}

- (void)present
{
	UIWindowScene *scene = [self scene];
	if (!scene)
		return;
	self.window = [[UIWindow alloc] initWithWindowScene:scene];
	self.window.windowLevel = UIWindowLevelAlert + 1;
	UIViewController *vc = [UIViewController new];
	self.window.rootViewController = vc;

	UIView *card = vc.view;
	card.backgroundColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.06 alpha:1];
	self.card = card;

	UILabel *title = [UILabel new];
	title.text = @"QUAKE";
	title.font = [UIFont fontWithName:@"Copperplate-Bold" size:56] ?: [UIFont boldSystemFontOfSize:52];
	title.textColor = [UIColor colorWithRed:0.72 green:0.14 blue:0.06 alpha:1];
	title.textAlignment = NSTextAlignmentCenter;

	UILabel *body = [UILabel new];
	body.numberOfLines = 0;
	body.text = @"Game data required.\n\nChoose the folder holding your Quake data — an original “id1”, "
				@"the 2021 rerelease set, or a full Quake directory. Files are copied to this device; "
				@"you can add mission packs and mods later.\n\nOr copy your Quake files into "
				@"“On My iPhone → vkQuake” in the Files app and tap Check Again.";
	body.font = [UIFont systemFontOfSize:16];
	body.textColor = [UIColor colorWithWhite:0.80 alpha:1];
	body.textAlignment = NSTextAlignmentCenter;

	UIButton *pick = [UIButton buttonWithType:UIButtonTypeSystem];
	[pick setTitle:@"  Select Game Data Folder…  " forState:UIControlStateNormal];
	pick.titleLabel.font = [UIFont boldSystemFontOfSize:19];
	[pick setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
	pick.backgroundColor = [UIColor colorWithRed:0.72 green:0.14 blue:0.06 alpha:1];
	pick.layer.cornerRadius = 10;
	pick.contentEdgeInsets = UIEdgeInsetsMake (14, 22, 14, 22);
	[pick addTarget:self action:@selector (pickFolder) forControlEvents:UIControlEventTouchUpInside];

	UIButton *again = [UIButton buttonWithType:UIButtonTypeSystem];
	[again setTitle:@"Check Again" forState:UIControlStateNormal];
	again.titleLabel.font = [UIFont systemFontOfSize:16];
	[again setTitleColor:[UIColor colorWithWhite:0.65 alpha:1] forState:UIControlStateNormal];
	[again addTarget:self action:@selector (recheck) forControlEvents:UIControlEventTouchUpInside];

	UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ title, body, pick, again ]];
	stack.axis = UILayoutConstraintAxisVertical;
	stack.alignment = UIStackViewAlignmentCenter;
	stack.spacing = 24;
	stack.translatesAutoresizingMaskIntoConstraints = NO;
	[card addSubview:stack];
	[NSLayoutConstraint activateConstraints:@[
		[stack.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
		[stack.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
		[body.widthAnchor constraintLessThanOrEqualToConstant:560],
	]];

	[self.window makeKeyAndVisible];
}

// Swap the card to a static "Loading…" screen. It stays up (frozen, since
// Host_Init blocks the main thread) until the first game frame renders, then the
// frame driver calls VKQ_iOS_OnboardingDismiss — so no black flash.
- (void)showLoading
{
	for (UIView *v in self.card.subviews)
		[v removeFromSuperview];
	self.card.userInteractionEnabled = NO;
	UILabel *t = [UILabel new];
	t.text = @"QUAKE";
	t.font = [UIFont fontWithName:@"Copperplate-Bold" size:52] ?: [UIFont boldSystemFontOfSize:48];
	t.textColor = [UIColor colorWithRed:0.72 green:0.14 blue:0.06 alpha:1];
	UILabel *l = [UILabel new];
	l.text = @"Loading…";
	l.font = [UIFont systemFontOfSize:18];
	l.textColor = [UIColor colorWithWhite:0.80 alpha:1];
	UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:@[ t, l ]];
	s.axis = UILayoutConstraintAxisVertical;
	s.alignment = UIStackViewAlignmentCenter;
	s.spacing = 18;
	s.translatesAutoresizingMaskIntoConstraints = NO;
	[self.card addSubview:s];
	[NSLayoutConstraint activateConstraints:@[
		[s.centerXAnchor constraintEqualToAnchor:self.card.centerXAnchor],
		[s.centerYAnchor constraintEqualToAnchor:self.card.centerYAnchor],
	]];
	[self.card layoutIfNeeded];
}

- (void)pickFolder
{
	UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeFolder ]];
	p.delegate = self;
	p.allowsMultipleSelection = NO;
	[self.window.rootViewController presentViewController:p animated:YES completion:nil];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
	// data is required — the card stays up so the user can pick again
}

// For providers that can't fold-pick (OneDrive/Google Drive): the user copies
// data into the app's Files folder, then taps this to proceed.
- (void)recheck
{
	if (VKQ_iOS_HasGameData ())
	{
		[self showLoading];
		g_onboard_done = YES;
	}
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
	NSURL					*src = urls.firstObject;
	UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
	spin.color = UIColor.whiteColor;
	spin.translatesAutoresizingMaskIntoConstraints = NO;
	[self.card addSubview:spin];
	[NSLayoutConstraint activateConstraints:@[
		[spin.centerXAnchor constraintEqualToAnchor:self.card.centerXAnchor],
		[spin.bottomAnchor constraintEqualToAnchor:self.card.bottomAnchor constant:-80],
	]];
	[spin startAnimating];
	self.card.userInteractionEnabled = NO;

	dispatch_async (dispatch_get_global_queue (QOS_CLASS_USER_INITIATED, 0), ^{
		BOOL importedRerelease = NO, kpfPresent = NO;
		[self importFrom:src rerelease:&importedRerelease kpf:&kpfPresent];
		dispatch_async (dispatch_get_main_queue (), ^{
			[spin stopAnimating];
			[spin removeFromSuperview];
			self.card.userInteractionEnabled = YES;
			if (!VKQ_iOS_HasGameData ())
			{
				// nothing usable landed — let the user try again
				return;
			}
			// rerelease-only note: QuakeEX.kpf drives localization + KEX fonts
			if (importedRerelease && !kpfPresent)
				[self showKpfNote];
			else
			{
				[self showLoading];
				g_onboard_done = YES; // engine proceeds
			}
		});
	});
}

- (void)showKpfNote
{
	// Copy note: as of the 2026 30th-anniversary update the kpf no longer carries
	// the localized text — its loc_*.txt are placeholders and the strings live in
	// id1/pak0.pak. So the kpf is fonts-only for 2026+ data, and text-plus-fonts
	// for pre-2026 data. Word it so it is true of both, and point at the folder
	// rather than at the one file, because a partial copy is the failure mode that
	// actually bites (stale paks + new kpf = no strings anywhere; the engine warns
	// "localized text is UNAVAILABLE" on the console when it sees that).
	UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Rerelease data imported"
															   message:@"QuakeEX.kpf wasn't included. It supplies the enhanced KEX "
																	   @"fonts (and, with pre-2026 game data, the localized text). "
																	   @"Continuing without it is fine — the game plays normally.\n\n"
																	   @"Tip: import the whole rerelease folder rather than picking "
																	   @"files. A mix of old and new rerelease data is the one "
																	   @"combination that loses all localized text."
														preferredStyle:UIAlertControllerStyleAlert];
	[a addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
		[self showLoading];
		g_onboard_done = YES;
	}]];
	[self.window.rootViewController presentViewController:a animated:YES completion:nil];
}

// Copy the picked Quake folder into Documents following the Steam layout:
//   a rerelease set (id1 + QuakeEX.kpf) -> Documents/rerelease intact
//   a full Quake root -> route rerelease/ + classic id1/hipnotic/rogue + mods
//   a bare id1 (loose paks) -> Documents/id1
- (void)importFrom:(NSURL *)folder rerelease:(BOOL *)outRer kpf:(BOOL *)outKpf
{
	BOOL		   scoped = [folder startAccessingSecurityScopedResource];
	NSFileManager *fm = NSFileManager.defaultManager;
	NSString	  *docs = VKQ_Docs ();

	void (^copyItem) (NSString *, NSString *) = ^(NSString *from, NSString *to) {
		[fm removeItemAtPath:to error:NULL];
		[fm createDirectoryAtPath:[to stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL];
		NSError *e = nil;
		if (![fm copyItemAtPath:from toPath:to error:&e])
			NSLog (@"[vkquake] import copy %@ -> %@ failed: %@", from.lastPathComponent, to, e);
		else
			NSLog (@"[vkquake] imported %@", to.lastPathComponent);
	};
	BOOL (^isDir) (NSString *) = ^BOOL (NSString *p) {
		BOOL d = NO;
		[fm fileExistsAtPath:p isDirectory:&d];
		return d;
	};
	BOOL (^hasPak) (NSString *) = ^BOOL (NSString *dir) {
		for (NSString *g in [fm contentsOfDirectoryAtPath:dir error:nil])
			if ([g.lowercaseString hasPrefix:@"pak"] && [g.lowercaseString hasSuffix:@".pak"])
				return YES;
		return NO;
	};

	NSString *root = folder.path;
	NSArray	 *top = [fm contentsOfDirectoryAtPath:root error:nil];

	BOOL rootHasKpf = NO, rootHasId1 = NO, rootHasRerelease = NO, rootHasLoosePak = NO;
	for (NSString *f in top)
	{
		NSString *low = f.lowercaseString;
		if ([low isEqualToString:@"quakeex.kpf"])
			rootHasKpf = YES;
		else if ([low isEqualToString:@"id1"] && isDir ([root stringByAppendingPathComponent:f]))
			rootHasId1 = YES;
		else if ([low isEqualToString:@"rerelease"] && isDir ([root stringByAppendingPathComponent:f]))
			rootHasRerelease = YES;
		else if ([low hasPrefix:@"pak"] && [low hasSuffix:@".pak"])
			rootHasLoosePak = YES;
	}

	BOOL rer = NO, kpf = NO;

	if (rootHasLoosePak && !rootHasId1) // the folder itself is an id1
	{
		copyItem (root, [docs stringByAppendingPathComponent:@"id1"]);
	}
	else if (rootHasId1 && rootHasKpf && !rootHasRerelease) // the folder IS a rerelease set
	{
		copyItem (root, [docs stringByAppendingPathComponent:@"rerelease"]);
		rer = YES;
		kpf = YES;
	}
	else // a full Quake root: route each top-level item
	{
		for (NSString *name in top)
		{
			NSString *from = [root stringByAppendingPathComponent:name];
			NSString *low = name.lowercaseString;
			if ([low isEqualToString:@"quakeex.kpf"])
			{
				copyItem (from, [docs stringByAppendingPathComponent:@"rerelease/QuakeEX.kpf"]);
				kpf = YES;
			}
			else if ([low isEqualToString:@"rerelease"] && isDir (from))
			{
				copyItem (from, [docs stringByAppendingPathComponent:@"rerelease"]);
				rer = YES;
				if ([fm fileExistsAtPath:[from stringByAppendingPathComponent:@"QuakeEX.kpf"]])
					kpf = YES;
			}
			else if (isDir (from) && hasPak (from)) // id1 / hipnotic / rogue / a mod
			{
				copyItem (from, [docs stringByAppendingPathComponent:name]);
			}
		}
	}

	// if a rerelease set landed under Documents/rerelease, confirm the kpf state there
	if ([fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"rerelease/id1/pak0.pak"]])
	{
		rer = YES;
		if ([fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"rerelease/QuakeEX.kpf"]])
			kpf = YES;
	}

	if (scoped)
		[folder stopAccessingSecurityScopedResource];
	if (outRer)
		*outRer = rer;
	if (outKpf)
		*outKpf = kpf;
}

@end

// ---------------------------------------------------------------------------

// Called from main_sdl.c (iOS) BEFORE Host_Init. Returns once game data is
// present in Documents; blocks with a folder-picker card if it isn't.
void VKQ_iOS_EnsureGameData (void)
{
	extern void VKQ_iOS_EarlyLog (void);
	VKQ_iOS_EarlyLog (); // capture Host_Init to boot.log before the console bridge exists

	if (VKQ_iOS_HasGameData ())
		return;

	// An empty Documents folder doesn't appear in Files. Write a guide file so
	// "On My iPhone -> vkQuake" shows up for the copy-in path, and tells the user
	// what layout to use.
	{
		NSString *readme = [VKQ_Docs () stringByAppendingPathComponent:@"READ ME - put Quake data here.txt"];
		if (![NSFileManager.defaultManager fileExistsAtPath:readme])
		{
			NSString *text =
				@"Put your Quake game data in this folder, then open vkQuake and tap \"Check Again\".\n\n"
				@"Examples (any one is enough to start):\n"
				@"  id1/pak0.pak                original Quake\n"
				@"  rerelease/id1/pak0.pak      2021 rerelease\n"
				@"  rerelease/QuakeEX.kpf       rerelease localized text + fonts\n"
				@"  hipnotic/   rogue/          mission packs\n";
			[text writeToFile:readme atomically:YES encoding:NSUTF8StringEncoding error:nil];
		}
	}

	g_onboard_done = NO;
	g_onboard = [VKQOnboard new];

	// Block the engine's main() here, pumping the run loop so the picker/copy
	// UIKit events are delivered, until data lands. Retry present() until a
	// window scene is available (it may not be connected on the first tick).
	while (!g_onboard_done)
	{
		@autoreleasepool
		{
			if (!g_onboard.window)
				[g_onboard present];
			[[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
		}
	}
	// Leave the window up (now showing "Loading…") over the black Host_Init gap;
	// the frame driver calls VKQ_iOS_OnboardingDismiss once the game has drawn.
}

// Called by the frame driver after the first game frame renders.
void VKQ_iOS_OnboardingDismiss (void)
{
	if (!g_onboard)
		return;
	[g_onboard.window setHidden:YES];
	g_onboard.window = nil;
	g_onboard = nil;
}
