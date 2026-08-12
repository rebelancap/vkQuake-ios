/*
 * ios_download.m — vkquake-ios overlay 0028 (MP-DL1) shell services for the
 * missing-map downloader in Quake/cl_mapdl.c.
 *
 * THE CONTRACT, and why it is shaped like this:
 *
 *   The engine is single-threaded and its whole world (com_gamedir, cvars, the
 *   console, the menu) is frame-thread property. NSURLSession is not. So nothing
 *   here ever calls into the engine, and the engine never blocks on anything
 *   here. Every service is a JOB: start it, get an integer handle, poll the
 *   handle once per host frame, read the result, free it. Four kinds of job go
 *   through one table because they have identical lifetimes and the engine's
 *   state machine then has exactly one polling idiom to get right.
 *
 *     HEAD    — "is this URL there, and how big is it" without a body. The cheap
 *               probe that lets the consent prompt state a real size.
 *     GET     — stream a URL to a file. Progress is reported live.
 *     RESOLVE — parse the cached Quaddicted dump and find the package that
 *               contains <map>.bsp. Off the engine thread because the dump is
 *               ~18 MB of JSON and parsing it inline would drop a second of
 *               frames on a menu screen.
 *     SHA256  — hash a downloaded package. Also off-thread: a 200 MB zip is not
 *               something to hash between two presents.
 *
 * WHY RESOLUTION IS LOCAL. Quaddicted's API v1 answers fielded queries for
 * authors: and tags:, but filenames: and filenames_txt: return an empty array
 * even for files that are demonstrably present in the full dump — verified
 * repeatedly against known-present entries. "Which package contains this map"
 * therefore cannot be asked of the server, and the client keeps a cached dump
 * and answers it itself. That is the whole reason an 18 MB index exists in this
 * feature at all.
 */
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>

// ---------------------------------------------------------------------------
// job table
// ---------------------------------------------------------------------------
typedef NS_ENUM (int, VKQDLState) {
	VKQDL_RUNNING = 0,
	VKQDL_DONE = 1,
	VKQDL_FAILED = 2,
};

@interface VKQDLJob : NSObject <NSURLSessionDataDelegate>
@property (nonatomic) int				 handle;
@property (nonatomic) VKQDLState		 state;
@property (nonatomic) long long			 got, total;
@property (nonatomic) int				 status;
@property (nonatomic, copy) NSString	*error;
@property (nonatomic, copy) NSString	*destPath;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *result;
@property (nonatomic, strong) NSURLSessionTask *task;
@property (nonatomic, strong) NSURLSession	   *session;
@property (nonatomic) FILE					   *out;
@end

@implementation VKQDLJob
@end

// The table is touched from the engine thread (start/poll/free) and from
// NSURLSession's delegate queue (progress/completion), so every field crossing
// that line is written and read under this one lock. A job's `result` dictionary
// is only ever mutated before state flips to DONE, and only ever read after —
// the state word is the handoff.
static NSMutableDictionary<NSNumber *, VKQDLJob *> *vkq_dl_jobs;
static NSLock									   *vkq_dl_lock;
static int											vkq_dl_next_handle = 1;

static void vkq_dl_init_once (void)
{
	static dispatch_once_t once;
	dispatch_once (&once, ^{
		vkq_dl_jobs = [NSMutableDictionary dictionary];
		vkq_dl_lock = [NSLock new];
	});
}

static VKQDLJob *vkq_dl_get (int handle)
{
	VKQDLJob *j;
	vkq_dl_init_once ();
	[vkq_dl_lock lock];
	j = vkq_dl_jobs[@(handle)];
	[vkq_dl_lock unlock];
	return j;
}

static int vkq_dl_add (VKQDLJob *j)
{
	vkq_dl_init_once ();
	[vkq_dl_lock lock];
	j.handle = vkq_dl_next_handle++;
	vkq_dl_jobs[@(j.handle)] = j;
	[vkq_dl_lock unlock];
	return j.handle;
}

static void vkq_dl_finish (VKQDLJob *j, VKQDLState st, NSString *err)
{
	[vkq_dl_lock lock];
	if (j.out)
	{
		fclose (j.out);
		j.out = NULL;
	}
	if (err)
		j.error = err;
	j.state = st;
	[vkq_dl_lock unlock];
}

// ---------------------------------------------------------------------------
// HTTP jobs
// ---------------------------------------------------------------------------
// One configuration for every request. `waitsForConnectivity` is off on purpose:
// a player on a dead network must see a failure on the download screen, not a
// spinner that never resolves.
static NSURLSessionConfiguration *vkq_dl_config (void)
{
	NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
	cfg.timeoutIntervalForRequest = 30.0;
	cfg.timeoutIntervalForResource = 600.0;
	cfg.waitsForConnectivity = NO;
	cfg.HTTPShouldSetCookies = NO;
	cfg.HTTPAdditionalHeaders = @{@"User-Agent" : @"vkQuake-iOS/1.1 (map downloader)"};
	return cfg;
}

@interface VKQDLHTTP : VKQDLJob
@end

@implementation VKQDLHTTP

- (void)URLSession:(NSURLSession *)session
				  dataTask:(NSURLSessionDataTask *)dataTask
		didReceiveResponse:(NSURLResponse *)response
		 completionHandler:(void (^) (NSURLSessionResponseDisposition))completionHandler
{
	NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
	[vkq_dl_lock lock];
	self.status = http ? (int)http.statusCode : 0;
	// expectedContentLength is -1 for a chunked response; the engine treats a
	// non-positive total as "unknown size" and draws bytes-so-far instead of a
	// percentage, which is honest rather than a fabricated denominator.
	self.total = response.expectedContentLength;
	[vkq_dl_lock unlock];
	completionHandler (NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data
{
	[vkq_dl_lock lock];
	if (self.out)
		[data enumerateByteRangesUsingBlock:^(const void *bytes, NSRange range, BOOL *stop) {
			if (fwrite (bytes, 1, range.length, self.out) != range.length)
				*stop = YES;
		}];
	self.got += (long long)data.length;
	[vkq_dl_lock unlock];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
	if (error)
	{
		vkq_dl_finish (self, VKQDL_FAILED, error.localizedDescription);
		return;
	}
	// A 404 is a COMPLETED transfer as far as NSURLSession is concerned. The
	// engine reads the status code separately and treats anything but 200 as "not
	// here" — which for the bare-BSP probe is a normal, expected answer that sends
	// it to the second source rather than an error.
	vkq_dl_finish (self, VKQDL_DONE, nil);
}

// Redirects are FOLLOWED and that is required, not incidental: quaddicted.com
// filebase download URLs answer 301 to their storage host. The only thing
// enforced across a redirect is the scheme — an https URL must not be walked
// down to http by a redirect we did not choose.
- (void)URLSession:(NSURLSession *)session
						  task:(NSURLSessionTask *)task
	willPerformHTTPRedirection:(NSHTTPURLResponse *)response
					newRequest:(NSURLRequest *)request
			 completionHandler:(void (^) (NSURLRequest *))completionHandler
{
	NSString *from = task.originalRequest.URL.scheme.lowercaseString;
	NSString *to = request.URL.scheme.lowercaseString;
	if ([from isEqualToString:@"https"] && ![to isEqualToString:@"https"])
	{
		NSLog (@"[vkquake] mapdl: refusing https -> %@ redirect", to);
		completionHandler (nil);
		return;
	}
	completionHandler (request);
}
@end

static int vkq_dl_start_http (const char *url, const char *destpath, BOOL headOnly)
{
	@autoreleasepool
	{
		if (!url || !*url)
			return 0;
		NSURL *u = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
		if (!u || !u.scheme)
			return 0;

		VKQDLHTTP *j = [VKQDLHTTP new];
		j.state = VKQDL_RUNNING;
		j.result = [NSMutableDictionary dictionary];
		j.total = -1;

		if (destpath && *destpath)
		{
			j.destPath = [NSString stringWithUTF8String:destpath];
			j.out = fopen (destpath, "wb");
			if (!j.out)
			{
				NSLog (@"[vkquake] mapdl: cannot create %s", destpath);
				return 0;
			}
		}

		NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
		req.HTTPMethod = headOnly ? @"HEAD" : @"GET";
		req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

		int handle = vkq_dl_add (j);
		NSOperationQueue *q = [NSOperationQueue new];
		q.maxConcurrentOperationCount = 1;
		j.session = [NSURLSession sessionWithConfiguration:vkq_dl_config () delegate:j delegateQueue:q];
		j.task = [j.session dataTaskWithRequest:req];
		[j.task resume];
		return handle;
	}
}

int VKQ_DL_StartHead (const char *url) { return vkq_dl_start_http (url, NULL, YES); }
int VKQ_DL_StartGet (const char *url, const char *destpath) { return vkq_dl_start_http (url, destpath, NO); }

// ---------------------------------------------------------------------------
// RESOLVE — find the archive package that contains <map>.bsp
// ---------------------------------------------------------------------------
/*
 * Defensive about the record shape on purpose. metadata.files is an OBJECT keyed
 * by path in live responses, but an older fixture of the same endpoint carries an
 * ARRAY of paths; both are accepted here, and anything else is skipped rather
 * than trusted. Likewise metadata.urls may be absent, empty, or carry mirrors —
 * a www.quaddicted.com entry is preferred when one exists, otherwise the first
 * https entry wins, and a record with no https URL at all resolves to nothing
 * (the engine then reports "no usable https download" instead of downloading
 * over cleartext).
 */
static BOOL vkq_dl_basename_matches (NSString *path, NSString *wantLower)
{
	NSString *base = path.lastPathComponent.lowercaseString;
	return [base isEqualToString:wantLower];
}

static NSString *vkq_dl_pick_url (NSArray *urls)
{
	NSString *first = nil;
	for (id o in urls)
	{
		if (![o isKindOfClass:NSString.class])
			continue;
		NSString *s = (NSString *)o;
		if (![s.lowercaseString hasPrefix:@"https://"])
			continue;
		if (!first)
			first = s;
		if ([s.lowercaseString containsString:@"quaddicted.com"])
			return s;
	}
	return first;
}

int VKQ_DL_StartResolve (const char *indexpath, const char *mapname)
{
	@autoreleasepool
	{
		if (!indexpath || !*indexpath || !mapname || !*mapname)
			return 0;
		NSString *path = [NSString stringWithUTF8String:indexpath];
		NSString *want = [[NSString stringWithUTF8String:mapname] stringByAppendingString:@".bsp"].lowercaseString;

		VKQDLJob *j = [VKQDLJob new];
		j.state = VKQDL_RUNNING;
		j.result = [NSMutableDictionary dictionary];
		int handle = vkq_dl_add (j);

		dispatch_async (dispatch_get_global_queue (QOS_CLASS_UTILITY, 0), ^{
			@autoreleasepool
			{
				NSError *err = nil;
				NSData	*data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&err];
				if (!data)
				{
					vkq_dl_finish (j, VKQDL_FAILED, err.localizedDescription ?: @"index unreadable");
					return;
				}
				id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
				if (![root isKindOfClass:NSArray.class])
				{
					vkq_dl_finish (j, VKQDL_FAILED, @"archive index is not a JSON array");
					return;
				}
				for (id rec in (NSArray *)root)
				{
					if (![rec isKindOfClass:NSDictionary.class])
						continue;
					NSDictionary *d = (NSDictionary *)rec;
					NSDictionary *meta = [d[@"metadata"] isKindOfClass:NSDictionary.class] ? d[@"metadata"] : nil;
					if (!meta)
						continue;
					id	 files = meta[@"files"];
					BOOL hit = NO;
					if ([files isKindOfClass:NSDictionary.class])
					{
						for (NSString *k in (NSDictionary *)files)
							if ([k isKindOfClass:NSString.class] && vkq_dl_basename_matches (k, want))
							{
								hit = YES;
								break;
							}
					}
					else if ([files isKindOfClass:NSArray.class])
					{
						for (id k in (NSArray *)files)
						{
							if ([k isKindOfClass:NSString.class] && vkq_dl_basename_matches (k, want))
							{
								hit = YES;
								break;
							}
							if ([k isKindOfClass:NSDictionary.class])
							{
								id nm = ((NSDictionary *)k)[@"path"] ?: ((NSDictionary *)k)[@"name"];
								if ([nm isKindOfClass:NSString.class] && vkq_dl_basename_matches (nm, want))
								{
									hit = YES;
									break;
								}
							}
						}
					}
					if (!hit)
						continue;

					NSString *url = [meta[@"urls"] isKindOfClass:NSArray.class] ? vkq_dl_pick_url (meta[@"urls"]) : nil;
					if (!url)
						continue; // a record we cannot fetch is not a match

					NSString	 *sha = [d[@"sha256"] isKindOfClass:NSString.class] ? d[@"sha256"] : @"";
					NSDictionary *install = [meta[@"install"] isKindOfClass:NSDictionary.class] ? meta[@"install"] : nil;
					NSString	 *extract = [install[@"extract"] isKindOfClass:NSString.class] ? install[@"extract"] : @"";
					NSString	 *title = [meta[@"title"] isKindOfClass:NSString.class] ? meta[@"title"] : @"";
					id			  bytes = meta[@"bytes"];
					NSString	 *bytestr = [bytes respondsToSelector:@selector (stringValue)] ? [bytes stringValue] : @"0";

					[vkq_dl_lock lock];
					j.result[@"url"] = url;
					j.result[@"sha256"] = sha;
					j.result[@"extract"] = extract;
					j.result[@"title"] = title;
					j.result[@"bytes"] = bytestr;
					[vkq_dl_lock unlock];
					vkq_dl_finish (j, VKQDL_DONE, nil);
					return;
				}
				vkq_dl_finish (j, VKQDL_FAILED, @"no archive package contains that map");
			}
		});
		return handle;
	}
}

// ---------------------------------------------------------------------------
// SHA256
// ---------------------------------------------------------------------------
int VKQ_DL_StartSha256 (const char *path)
{
	@autoreleasepool
	{
		if (!path || !*path)
			return 0;
		NSString *p = [NSString stringWithUTF8String:path];
		VKQDLJob *j = [VKQDLJob new];
		j.state = VKQDL_RUNNING;
		j.result = [NSMutableDictionary dictionary];
		int handle = vkq_dl_add (j);

		dispatch_async (dispatch_get_global_queue (QOS_CLASS_UTILITY, 0), ^{
			@autoreleasepool
			{
				FILE *f = fopen (p.fileSystemRepresentation, "rb");
				if (!f)
				{
					vkq_dl_finish (j, VKQDL_FAILED, @"cannot read the package");
					return;
				}
				CC_SHA256_CTX ctx;
				CC_SHA256_Init (&ctx);
				// Streamed in 1 MB blocks: a package can be hundreds of megabytes and
				// mapping the whole thing to hash it would be gratuitous on a phone.
				unsigned char *buf = malloc (1 << 20);
				size_t		   n;
				while ((n = fread (buf, 1, 1 << 20, f)) > 0)
					CC_SHA256_Update (&ctx, buf, (CC_LONG)n);
				free (buf);
				fclose (f);
				unsigned char digest[CC_SHA256_DIGEST_LENGTH];
				CC_SHA256_Final (digest, &ctx);
				NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
				for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
					[hex appendFormat:@"%02x", digest[i]];
				[vkq_dl_lock lock];
				j.result[@"sha256"] = hex;
				[vkq_dl_lock unlock];
				vkq_dl_finish (j, VKQDL_DONE, nil);
			}
		});
		return handle;
	}
}

// ---------------------------------------------------------------------------
// polling / teardown
// ---------------------------------------------------------------------------
int VKQ_DL_Poll (int handle, long long *got, long long *total, int *httpstatus)
{
	VKQDLJob *j = vkq_dl_get (handle);
	int		  st;
	if (!j)
	{
		if (got)
			*got = 0;
		if (total)
			*total = 0;
		if (httpstatus)
			*httpstatus = 0;
		return VKQDL_FAILED;
	}
	[vkq_dl_lock lock];
	if (got)
		*got = j.got;
	if (total)
		*total = j.total;
	if (httpstatus)
		*httpstatus = j.status;
	st = (int)j.state;
	[vkq_dl_lock unlock];
	return st;
}

// Returns a pointer valid until the next call: the engine's failure paths pass
// this straight into a printf-style message and then free the job, so it must not
// point into anything the free touches.
const char *VKQ_DL_Error (int handle)
{
	static char buf[256];
	VKQDLJob   *j = vkq_dl_get (handle);
	buf[0] = 0;
	if (j)
	{
		[vkq_dl_lock lock];
		if (j.error)
			snprintf (buf, sizeof (buf), "%s", j.error.UTF8String);
		else if (j.status && j.status != 200)
			snprintf (buf, sizeof (buf), "http %d", j.status);
		[vkq_dl_lock unlock];
	}
	if (!buf[0])
		snprintf (buf, sizeof (buf), "no response");
	return buf;
}

const char *VKQ_DL_Result (int handle, const char *field)
{
	static char buf[1024];
	VKQDLJob   *j = vkq_dl_get (handle);
	buf[0] = 0;
	if (j && field)
	{
		[vkq_dl_lock lock];
		NSString *v = j.result[[NSString stringWithUTF8String:field]];
		if (v)
			snprintf (buf, sizeof (buf), "%s", v.UTF8String);
		[vkq_dl_lock unlock];
	}
	return buf;
}

void VKQ_DL_Free (int handle)
{
	VKQDLJob *j = vkq_dl_get (handle);
	if (!j)
		return;
	[j.task cancel];
	[j.session invalidateAndCancel];
	[vkq_dl_lock lock];
	if (j.out)
	{
		fclose (j.out);
		j.out = NULL;
	}
	[vkq_dl_jobs removeObjectForKey:@(handle)];
	[vkq_dl_lock unlock];
}

// The archive index is CACHE, not user data: it is reconstructible from the
// network and the system may evict it, which is exactly the contract we want.
// Documents is Files-visible and backed up; an 18 MB machine-readable dump has
// no business in either.
const char *VKQ_DL_CachesPath (void)
{
	static char buf[1024];
	@autoreleasepool
	{
		NSString *c = [NSSearchPathForDirectoriesInDomains (NSCachesDirectory, NSUserDomainMask, YES) firstObject];
		if (c)
			snprintf (buf, sizeof (buf), "%s", c.fileSystemRepresentation);
		else
			buf[0] = 0;
	}
	return buf;
}
