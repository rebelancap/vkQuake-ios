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
// overlay 0034: a hard byte ceiling for a GET (0 = none). Enforced against the
// advertised Content-Length AND against the bytes actually received, because a
// chunked response has no length to check up front and a hostile one can lie.
@property (nonatomic) long long				   maxBytes;
@property (nonatomic) BOOL					   overCap;
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
	cfg.HTTPAdditionalHeaders = @{@"User-Agent" : @"vkQuake-iOS/1.2 (content downloader)"};
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
	BOOL tooBig = self.maxBytes > 0 && response.expectedContentLength > self.maxBytes;
	if (tooBig)
		self.overCap = YES;
	[vkq_dl_lock unlock];
	completionHandler (tooBig ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
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
	BOOL tooBig = self.maxBytes > 0 && self.got > self.maxBytes;
	if (tooBig)
		self.overCap = YES;
	[vkq_dl_lock unlock];
	if (tooBig)
		[dataTask cancel];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
	if (self.overCap)
	{
		// overlay 0034: our own cancel, so say why instead of "cancelled".
		vkq_dl_finish (self, VKQDL_FAILED, @"larger than the size limit");
		return;
	}
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

static int vkq_dl_start_http_max (const char *url, const char *destpath, BOOL headOnly, long long maxBytes);
static int vkq_dl_start_http (const char *url, const char *destpath, BOOL headOnly)
{
	return vkq_dl_start_http_max (url, destpath, headOnly, 0);
}

static int vkq_dl_start_http_max (const char *url, const char *destpath, BOOL headOnly, long long maxBytes)
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
		j.maxBytes = maxBytes;

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
// overlay 0034: GET with a byte ceiling (the mod-content downloader's files are
// chosen by a server or a remote table, so every one of them is capped).
int VKQ_DL_StartGetMax (const char *url, const char *destpath, long long maxbytes)
{
	return vkq_dl_start_http_max (url, destpath, NO, maxbytes);
}

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

/*
 * Pick the download URL out of a record's mirror list: https on quaddicted.com
 * first, then any https, then anything left.
 *
 * SCHEME POLICY IS NOT DECIDED HERE, and that is deliberate. This used to drop
 * every non-https entry, which quietly made the whole record unmatchable — the
 * engine then reported "not found in community archives" for a package that was
 * sitting right there in the index, and the local http fixture the simulator run
 * is built on could never resolve at all. Whether a scheme is acceptable is
 * cl_mapdl_url_ok's judgement (it reads cl_mapdownload_allowhttp), and it is
 * applied to whatever comes back from here — one place, one rule, one message.
 * Preferring https here only decides WHICH mirror is offered, never whether it
 * is allowed.
 */
static NSString *vkq_dl_pick_url (NSArray *urls)
{
	NSString *firstHttps = nil, *firstAny = nil;
	for (id o in urls)
	{
		if (![o isKindOfClass:NSString.class])
			continue;
		NSString *s = (NSString *)o;
		NSString *low = s.lowercaseString;
		BOOL	  https = [low hasPrefix:@"https://"];
		if (!https && ![low hasPrefix:@"http://"])
			continue; // not a web download at all (ftp, magnet, a bare note)
		if (https && [low containsString:@"quaddicted.com"])
			return s;
		if (https && !firstHttps)
			firstHttps = s;
		if (!firstAny)
			firstAny = s;
	}
	return firstHttps ?: firstAny;
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

// ===========================================================================
// overlay 0034 (MOD-DL) — services for Quake/cl_moddl.c, the missing MOD
// CONTENT downloader. Same job contract as everything above: start, poll, read,
// free; nothing here touches engine state.
// ===========================================================================
#include <netdb.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

// ---------------------------------------------------------------------------
// STATUS — one connectionless `getstatus` to the game server we were just
// dropped from, read back as key/value pairs.
//
// WHY THIS IS HOW THE SERVER'S DOWNLOAD URL IS READ. FTE advertises it as the
// serverinfo key sv_dlURL (registered as an alias of DarkPlaces' cvar name
// sv_curl_defaulturl, flagged CVAR_SERVERINFO; fteqw engine/common/fs.c). A
// NetQuake client only sees serverinfo in-band through FTE's `fullserverinfo`
// stufftext, and FTE sends that during PRESPAWN — after svc_serverinfo, which is
// where the precache list is checked and the connection dies. So in-band it
// always arrives one message too late. The status reply carries the same
// serverinfo out of band, from the same address, before we ever rejoin.
// ---------------------------------------------------------------------------
static BOOL vkq_dl_split_target (NSString *target, int defport, NSString **host, int *port)
{
	NSString *t = [target stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
	if ([t hasPrefix:@"udp:"])
		t = [t substringFromIndex:4];
	if (!t.length)
		return NO;
	*port = defport;
	if ([t hasPrefix:@"["]) // [v6]:port
	{
		NSRange close = [t rangeOfString:@"]"];
		if (close.location == NSNotFound)
			return NO;
		*host = [t substringWithRange:NSMakeRange (1, close.location - 1)];
		NSString *rest = [t substringFromIndex:close.location + 1];
		if ([rest hasPrefix:@":"])
			*port = [rest substringFromIndex:1].intValue;
	}
	else
	{
		NSRange c = [t rangeOfString:@":" options:NSBackwardsSearch];
		NSRange first = [t rangeOfString:@":"];
		if (c.location != NSNotFound && c.location == first.location) // exactly one colon: host:port
		{
			*host = [t substringToIndex:c.location];
			*port = [t substringFromIndex:c.location + 1].intValue;
		}
		else
			*host = t; // a name, a v4 literal, or a bare v6 literal
	}
	return (*host).length > 0 && *port > 0 && *port < 65536;
}

int VKQ_DL_StartStatus (const char *target, int defaultport)
{
	@autoreleasepool
	{
		if (!target || !*target)
			return 0;
		NSString *host = nil;
		int		  port = 0;
		if (!vkq_dl_split_target ([NSString stringWithUTF8String:target], defaultport, &host, &port))
			return 0;

		VKQDLJob *j = [VKQDLJob new];
		j.state = VKQDL_RUNNING;
		j.result = [NSMutableDictionary dictionary];
		int handle = vkq_dl_add (j);

		dispatch_async (dispatch_get_global_queue (QOS_CLASS_UTILITY, 0), ^{
			@autoreleasepool
			{
				struct addrinfo hints, *res = NULL;
				memset (&hints, 0, sizeof (hints));
				hints.ai_family = AF_UNSPEC;
				hints.ai_socktype = SOCK_DGRAM;
				char portstr[16];
				snprintf (portstr, sizeof (portstr), "%d", port);
				if (getaddrinfo (host.UTF8String, portstr, &hints, &res) != 0 || !res)
				{
					vkq_dl_finish (j, VKQDL_FAILED, @"cannot resolve the server address");
					return;
				}
				int s = socket (res->ai_family, res->ai_socktype, res->ai_protocol);
				if (s < 0)
				{
					freeaddrinfo (res);
					vkq_dl_finish (j, VKQDL_FAILED, @"no socket");
					return;
				}
				static const char req[] = "\xff\xff\xff\xffgetstatus vkqmoddl";
				char			  buf[8192];
				ssize_t			  n = -1;
				// Two tries, 1.5 s each: UDP to a server that just dropped us is
				// normally instant, and a dead one must not hold the screen long.
				for (int attempt = 0; attempt < 2 && n <= 0; attempt++)
				{
					sendto (s, req, sizeof (req) - 1, 0, res->ai_addr, res->ai_addrlen);
					struct pollfd pfd = {s, POLLIN, 0};
					double		  until = CFAbsoluteTimeGetCurrent () + 1.5;
					while (CFAbsoluteTimeGetCurrent () < until)
					{
						int ms = (int)((until - CFAbsoluteTimeGetCurrent ()) * 1000.0);
						if (poll (&pfd, 1, ms > 0 ? ms : 1) <= 0)
							continue;
						n = recv (s, buf, sizeof (buf) - 1, 0);
						if (n > 4 && !memcmp (buf, "\xff\xff\xff\xff", 4) && n > 18 && !strncmp (buf + 4, "statusResponse", 14))
							break;
						n = -1; // something else (a stray reply): keep listening
					}
				}
				close (s);
				freeaddrinfo (res);
				if (n <= 0)
				{
					vkq_dl_finish (j, VKQDL_FAILED, @"the server did not answer a status query");
					return;
				}
				buf[n] = 0;
				// "\xff\xff\xff\xffstatusResponse\n\\k\\v\\k\\v\n<players...>"
				char *info = strchr (buf + 4, '\n');
				if (!info)
				{
					vkq_dl_finish (j, VKQDL_FAILED, @"malformed status reply");
					return;
				}
				info++;
				char *end = strchr (info, '\n');
				if (end)
					*end = 0;
				NSString *line = [[NSString alloc] initWithBytes:info length:strlen (info) encoding:NSISOLatin1StringEncoding];
				NSArray	 *parts = [line componentsSeparatedByString:@"\\"];
				[vkq_dl_lock lock];
				// parts[0] is the empty string before the leading backslash.
				for (NSUInteger i = 1; i + 1 < parts.count; i += 2)
					if ([parts[i] length] && [parts[i] length] < 64)
						j.result[[parts[i] lowercaseString]] = parts[i + 1];
				[vkq_dl_lock unlock];
				vkq_dl_finish (j, VKQDL_DONE, nil);
			}
		});
		return handle;
	}
}

// ---------------------------------------------------------------------------
// MOD RESOLVE — pick the curated package (mods/mod-sources.json) that covers
// every missing MODEL the server asked for.
//
// Coverage, not names, decides. A table entry is offered only if the package
// provably contains every missing non-map model (its `files` list was taken
// from the real archive when the entry was written). An entry whose `gamedirs`
// names the server's game directory is preferred; with no usable gamedir (many
// NetQuake servers never send one) a pure coverage match is accepted, because a
// package that contains progs/plane1.mdl, progs/helo1.mdl and 60 other specific
// files is not an accident. Missing sounds and maps never decide a match — a
// missing sound does not stop a join, and maps have their own source (0028).
//
// When no single entry has every missing model but the server names its game
// directory, entries for THAT directory may be combined: greedily, the one that
// covers the most of what is still missing first, until everything is covered
// (or the plan is refused). This is how a mod's main pak and a separately
// hosted map model (FortressOne's pak + 2nuke2's progs/tpad.mdl) make one plan.
// Entries are never combined across game directories, nor without a gamedir.
//
// Two copies of the table, tried in order: the one fetched from the repository
// (so a dead link is fixed without a release) and the one in the app bundle.
// A cached copy that does not parse, or has the wrong schema, is ignored rather
// than trusted.
// ---------------------------------------------------------------------------
static NSArray *vkq_dl_load_modtable (NSString *path, NSString **why)
{
	if (!path.length)
		return nil;
	NSData *data = [NSData dataWithContentsOfFile:path];
	if (!data)
		return nil;
	id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
	if (![root isKindOfClass:NSDictionary.class] || ![root[@"schema"] respondsToSelector:@selector (intValue)] || [root[@"schema"] intValue] != 1 ||
		![root[@"mods"] isKindOfClass:NSArray.class])
	{
		if (why)
			*why = @"table did not parse or has an unknown schema";
		return nil;
	}
	return root[@"mods"];
}

int VKQ_DL_StartModResolve (const char *cachedpath, const char *bundledpath, const char *missing, const char *gamedir)
{
	@autoreleasepool
	{
		NSString *cached = cachedpath ? [NSString stringWithUTF8String:cachedpath] : @"";
		NSString *bundled = bundledpath ? [NSString stringWithUTF8String:bundledpath] : @"";
		NSString *miss = missing ? [NSString stringWithUTF8String:missing] : @"";
		NSString *gd = gamedir ? [NSString stringWithUTF8String:gamedir].lowercaseString : @"";

		VKQDLJob *j = [VKQDLJob new];
		j.state = VKQDL_RUNNING;
		j.result = [NSMutableDictionary dictionary];
		int handle = vkq_dl_add (j);

		dispatch_async (dispatch_get_global_queue (QOS_CLASS_UTILITY, 0), ^{
			@autoreleasepool
			{
				NSString *why = nil, *which = @"downloaded";
				NSArray	 *mods = vkq_dl_load_modtable (cached, &why);
				if (!mods)
				{
					if (why)
						NSLog (@"[vkquake] moddl: cached mod table ignored: %@", why);
					mods = vkq_dl_load_modtable (bundled, &why);
					which = @"bundled";
				}
				if (!mods)
				{
					vkq_dl_finish (j, VKQDL_FAILED, @"no usable mod table");
					return;
				}
				NSMutableSet *need = [NSMutableSet set];
				for (NSString *l in [miss componentsSeparatedByString:@"\n"])
				{
					NSString *p = l.lowercaseString;
					if (!p.length || [p hasPrefix:@"sound/"] || [p hasPrefix:@"maps/"])
						continue;
					[need addObject:p];
				}
				if (!need.count)
				{
					vkq_dl_finish (j, VKQDL_FAILED, @"nothing to resolve");
					return;
				}
				NSDictionary *best = nil;
				int			  bestRank = 0;					   // 2 = gamedir + coverage, 1 = coverage only
				NSMutableArray *gdEntries = [NSMutableArray array]; // valid entries naming the server's gamedir
				NSMutableArray *gdHave = [NSMutableArray array];	   // ... and the files each provides
				for (id o in mods)
				{
					if (![o isKindOfClass:NSDictionary.class])
						continue;
					NSDictionary *m = o;
					if (![m[@"files"] isKindOfClass:NSArray.class] || ![m[@"url"] isKindOfClass:NSString.class] ||
						![m[@"gamedir"] isKindOfClass:NSString.class])
						continue;
					NSMutableSet *have = [NSMutableSet set];
					for (id f in m[@"files"])
						if ([f isKindOfClass:NSString.class])
							[have addObject:[f lowercaseString]];
					int rank = 1;
					if (gd.length && [m[@"gamedirs"] isKindOfClass:NSArray.class])
						for (id g in m[@"gamedirs"])
							if ([g isKindOfClass:NSString.class] && [[g lowercaseString] isEqualToString:gd])
								rank = 2;
					if (rank == 2)
					{
						[gdEntries addObject:m];
						[gdHave addObject:have];
					}
					if (![need isSubsetOfSet:have])
						continue;
					if (rank > bestRank)
					{
						best = m;
						bestRank = rank;
					}
				}
				NSMutableArray *chosen = [NSMutableArray array];
				if (best)
					[chosen addObject:best];
				else if (gdEntries.count)
				{
					// Greedy cover over this gamedir's entries (see the comment above).
					NSMutableSet *left = [need mutableCopy];
					while (left.count && chosen.count < 8)
					{
						NSUInteger pick = NSNotFound, pickN = 0;
						for (NSUInteger k = 0; k < gdEntries.count; k++)
						{
							if ([chosen containsObject:gdEntries[k]])
								continue;
							NSMutableSet *hit = [left mutableCopy];
							[hit intersectSet:gdHave[k]];
							if (hit.count > pickN)
							{
								pick = k;
								pickN = hit.count;
							}
						}
						if (pick == NSNotFound)
							break;
						[chosen addObject:gdEntries[pick]];
						[left minusSet:gdHave[pick]];
					}
					if (left.count)
						[chosen removeAllObjects];
					else
						bestRank = 2;
				}
				if (!chosen.count)
				{
					vkq_dl_finish (j, VKQDL_FAILED, [NSString stringWithFormat:@"no package in the %@ mod table has all %lu missing models", which, (unsigned long)need.count]);
					return;
				}
				[vkq_dl_lock lock];
				j.result[@"count"] = [NSString stringWithFormat:@"%lu", (unsigned long)chosen.count];
				j.result[@"gamedir"] = ((NSDictionary *)chosen[0])[@"gamedir"];
				j.result[@"table"] = which;
				j.result[@"rank"] = bestRank == 2 ? @"gamedir" : @"files";
				[vkq_dl_lock unlock];
				for (NSUInteger k = 0; k < chosen.count; k++)
				{
					NSDictionary *pk = chosen[k];
					NSString	 *sfx = k ? [NSString stringWithFormat:@".%lu", (unsigned long)k] : @"";
					// install rules flattened to "from>as;from>as" (from may be empty:
					// the download itself is the file). Anything malformed is dropped
					// here and the engine validates every path again before using it.
					NSMutableArray *rules = [NSMutableArray array];
					if ([pk[@"install"] isKindOfClass:NSArray.class])
						for (id r in pk[@"install"])
						{
							if (![r isKindOfClass:NSDictionary.class])
								continue;
							NSString *from = [r[@"from"] isKindOfClass:NSString.class] ? r[@"from"] : @"";
							NSString *as = [r[@"as"] isKindOfClass:NSString.class] ? r[@"as"] : @"";
							if (!as.length || [from containsString:@">"] || [from containsString:@";"] || [as containsString:@">"] || [as containsString:@";"])
								continue;
							[rules addObject:[NSString stringWithFormat:@"%@>%@", from, as]];
						}
					id		  bytes = pk[@"bytes"];
					NSString *name = [pk[@"name"] isKindOfClass:NSString.class] ? pk[@"name"] : pk[@"gamedir"];
					[vkq_dl_lock lock];
					j.result[[@"name" stringByAppendingString:sfx]] = name;
					j.result[[@"url" stringByAppendingString:sfx]] = pk[@"url"];
					j.result[[@"sha256" stringByAppendingString:sfx]] = [pk[@"sha256"] isKindOfClass:NSString.class] ? pk[@"sha256"] : @"";
					j.result[[@"type" stringByAppendingString:sfx]] = [pk[@"type"] isKindOfClass:NSString.class] ? pk[@"type"] : @"zip";
					j.result[[@"bytes" stringByAppendingString:sfx]] = [bytes respondsToSelector:@selector (stringValue)] ? [bytes stringValue] : @"0";
					j.result[[@"install" stringByAppendingString:sfx]] = [rules componentsJoinedByString:@";"];
					[vkq_dl_lock unlock];
				}
				vkq_dl_finish (j, VKQDL_DONE, nil);
			}
		});
		return handle;
	}
}

// The table that ships in the app (Resources/mod-sources.json).
const char *VKQ_DL_BundledModTablePath (void)
{
	static char buf[1024];
	@autoreleasepool
	{
		NSString *p = [NSBundle.mainBundle pathForResource:@"mod-sources" ofType:@"json"];
		snprintf (buf, sizeof (buf), "%s", p ? p.fileSystemRepresentation : "");
	}
	return buf;
}

// Remove the mod downloader's staging tree. Refuses anything that is not a
// directory literally named ".moddl" — this is a recursive delete, and the only
// tree it is ever allowed to delete is the one cl_moddl.c created.
void VKQ_DL_RemoveStaging (const char *path)
{
	@autoreleasepool
	{
		if (!path || !*path)
			return;
		NSString *p = [NSString stringWithUTF8String:path];
		if (![p.lastPathComponent isEqualToString:@".moddl"])
		{
			NSLog (@"[vkquake] moddl: refusing to remove %@", p);
			return;
		}
		[NSFileManager.defaultManager removeItemAtPath:p error:NULL];
	}
}
