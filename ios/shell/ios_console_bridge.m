#import "ios_console_bridge.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

#define BRIDGE_PORT 27999

// Engine command buffer (linked from libvkquake.a, cmd.c). Drain runs on the
// frame thread, so calling this directly is safe.
extern void Cbuf_AddText (const char *text);
// Documents dir (ios_shell.m)
extern const char *VKQ_iOS_DocumentsPath (void);

static dispatch_queue_t bridge_queue;
static int				listen_fd = -1;
static int				client_fd = -1;
static dispatch_source_t listen_src, client_src;
static NSMutableData	*inbuf;

static NSLock					 *cmd_lock;
static NSMutableArray<NSString *> *cmd_queue;

static NSString *log_path;
static int		 log_fd = -1;
static off_t	 log_offset = -1;

// ---- stdout tee: keep devicectl --console working AND feed the bridge tail ----
static void setup_stdout_tee (const char *logpath)
{
	int lf = open (logpath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (lf < 0)
		return;
	int pfd[2];
	if (pipe (pfd) != 0)
	{
		close (lf);
		return;
	}
	int real_out = dup (STDOUT_FILENO); // the fd devicectl --console is capturing
	dup2 (pfd[1], STDOUT_FILENO);
	dup2 (pfd[1], STDERR_FILENO);
	close (pfd[1]);
	setvbuf (stdout, NULL, _IOLBF, 0);
	int rfd = pfd[0];
	dispatch_queue_t q = dispatch_queue_create ("vkq.stdout.tee", DISPATCH_QUEUE_SERIAL);
	dispatch_async (q, ^{
		char	buf[4096];
		ssize_t n;
		while ((n = read (rfd, buf, sizeof (buf))) > 0)
		{
			(void)write (real_out, buf, n); // still visible to --console
			(void)write (lf, buf, n);		// tailed by the bridge
		}
	});
}

static void client_close (void)
{
	if (client_src)
	{
		dispatch_source_cancel (client_src);
		client_src = nil;
	}
	if (client_fd >= 0)
	{
		close (client_fd);
		client_fd = -1;
	}
}

static void client_readable (void)
{
	char	buf[2048];
	ssize_t n = read (client_fd, buf, sizeof (buf));
	if (n <= 0)
	{
		NSLog (@"[vkquake] console bridge: client disconnected");
		client_close ();
		return;
	}
	[inbuf appendBytes:buf length:n];

	const char *bytes = inbuf.bytes;
	NSUInteger	start = 0;
	for (NSUInteger i = 0; i < inbuf.length; i++)
	{
		if (bytes[i] == '\n')
		{
			NSUInteger len = i - start;
			while (len && (bytes[start + len - 1] == '\r'))
				len--;
			if (len)
			{
				NSString *line = [[NSString alloc] initWithBytes:bytes + start length:len encoding:NSUTF8StringEncoding];
				if (line)
				{
					[cmd_lock lock];
					[cmd_queue addObject:line];
					[cmd_lock unlock];
				}
			}
			start = i + 1;
		}
	}
	if (start)
		[inbuf replaceBytesInRange:NSMakeRange (0, start) withBytes:NULL length:0];
}

static void accept_client (void)
{
	int fd = accept (listen_fd, NULL, NULL);
	if (fd < 0)
		return;
	client_close (); // one client at a time; newest wins
	int one = 1;
	setsockopt (fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof (one));
	client_fd = fd;
	inbuf = [NSMutableData data];
	NSLog (@"[vkquake] console bridge: client connected");

	const char *hello = "] vkQuake remote console — engine output follows; type commands.\n";
	(void)write (fd, hello, strlen (hello));
	if (log_fd >= 0) // stream only fresh output
	{
		struct stat st;
		if (fstat (log_fd, &st) == 0)
			log_offset = st.st_size;
	}

	client_src = dispatch_source_create (DISPATCH_SOURCE_TYPE_READ, fd, 0, bridge_queue);
	dispatch_source_set_event_handler (client_src, ^{ client_readable (); });
	dispatch_resume (client_src);
}

// Redirect stdout/stderr to Documents/boot.log BEFORE Host_Init so a renderer /
// SDL / MoltenVK init failure (which happens before the console bridge starts)
// leaves a diagnosable trace on disk. Called from VKQ_iOS_EnsureGameData.
void VKQ_iOS_EarlyLog (void)
{
	const char *docs = VKQ_iOS_DocumentsPath ();
	if (!docs)
		return;
	char path[1024];
	snprintf (path, sizeof (path), "%s/boot.log", docs);
	freopen (path, "w", stdout);
	freopen (path, "a", stderr);
	setvbuf (stdout, NULL, _IONBF, 0);
	setvbuf (stderr, NULL, _IONBF, 0);
	fprintf (stderr, "[vkquake] early log start (pre-Host_Init)\n");
}

void VKQ_iOS_ConsoleBridgeStart (void)
{
	const char *env = getenv ("VKQ_CONSOLE_BRIDGE");
	if (!env || env[0] != '1')
		return;

	const char *docs = VKQ_iOS_DocumentsPath ();
	log_path = [NSString stringWithFormat:@"%s/console.log", docs ? docs : "/tmp"];
	setup_stdout_tee (log_path.fileSystemRepresentation);

	bridge_queue = dispatch_queue_create ("vkq.console.bridge", DISPATCH_QUEUE_SERIAL);
	cmd_lock = [NSLock new];
	cmd_queue = [NSMutableArray array];

	// A dying prior instance can still hold the port (REUSEADDR does not permit
	// rebinding an active listener), so retry for a few seconds off-main.
	dispatch_async (bridge_queue, ^{
		int				   one = 1;
		struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons (BRIDGE_PORT), .sin_addr.s_addr = htonl (INADDR_ANY)};
		for (int attempt = 0; attempt < 60; attempt++)
		{
			listen_fd = socket (AF_INET, SOCK_STREAM, 0);
			setsockopt (listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof (one));
			if (bind (listen_fd, (struct sockaddr *)&addr, sizeof (addr)) == 0 && listen (listen_fd, 1) == 0)
			{
				listen_src = dispatch_source_create (DISPATCH_SOURCE_TYPE_READ, listen_fd, 0, bridge_queue);
				dispatch_source_set_event_handler (listen_src, ^{ accept_client (); });
				dispatch_resume (listen_src);
				NSLog (@"[vkquake] console bridge listening on port %d (attempt %d)", BRIDGE_PORT, attempt + 1);
				return;
			}
			close (listen_fd);
			listen_fd = -1;
			usleep (500 * 1000);
		}
		NSLog (@"[vkquake] console bridge: gave up binding port %d", BRIDGE_PORT);
	});
}

// Frame thread, once per frame: feed queued commands in; stream new log out.
void VKQ_iOS_ConsoleBridgeDrain (void)
{
	if (!cmd_lock)
		return;

	NSArray<NSString *> *cmds = nil;
	[cmd_lock lock];
	if (cmd_queue.count)
	{
		cmds = [cmd_queue copy];
		[cmd_queue removeAllObjects];
	}
	[cmd_lock unlock];
	for (NSString *c in cmds)
	{
		Cbuf_AddText (c.UTF8String);
		Cbuf_AddText ("\n");
	}

	if (client_fd < 0)
		return;
	if (log_fd < 0 && log_path)
	{
		log_fd = open (log_path.fileSystemRepresentation, O_RDONLY);
		if (log_fd >= 0 && log_offset < 0)
		{
			struct stat st;
			log_offset = (fstat (log_fd, &st) == 0) ? st.st_size : 0;
		}
	}
	if (log_fd >= 0)
	{
		struct stat st;
		if (fstat (log_fd, &st) == 0 && st.st_size > log_offset)
		{
			char buf[4096];
			lseek (log_fd, log_offset, SEEK_SET);
			ssize_t n;
			while ((n = read (log_fd, buf, sizeof (buf))) > 0)
			{
				log_offset += n;
				if (client_fd >= 0)
					(void)write (client_fd, buf, n);
			}
		}
	}
}
