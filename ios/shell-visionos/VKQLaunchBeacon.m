// VKQLaunchBeacon.m — pre-main launch forensics for remote (OTA-only) debugging.
//
// The 3D build died silently on-device with boot.log untouched (D-027 follow-up),
// i.e. before the engine's own early logging exists. This beacon brackets the
// death point: a dyld constructor proves the process spawned at all, and
// VKQ_BeaconMark() calls (Swift App.init, host VC lifecycle) show how far launch
// got. Pure POSIX in the constructor — Foundation/UIKit are not safe that early.
// Appends (never truncates) so a crash loop leaves a visible trail.

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void vkq_beacon_write (const char *msg)
{
	const char *home = getenv ("HOME");
	if (!home)
		return;
	char path[1024];
	snprintf (path, sizeof path, "%s/Documents/launch-beacon.log", home);
	int fd = open (path, O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (fd < 0)
		return;
	time_t	  t = time (NULL);
	struct tm tmv;
	localtime_r (&t, &tmv);
	char line[320];
	int	 n = snprintf (line, sizeof line, "%04d-%02d-%02d %02d:%02d:%02d  %s\n", tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday, tmv.tm_hour,
					   tmv.tm_min, tmv.tm_sec, msg);
	if (n > 0)
		write (fd, line, (size_t)n);
	close (fd);
}

__attribute__ ((constructor)) static void vkq_launch_beacon (void)
{
	vkq_beacon_write ("beacon: dyld image init (pre-main) — process spawned");
}

// Callable from Swift/ObjC at launch milestones.
void VKQ_BeaconMark (const char *stage)
{
	vkq_beacon_write (stage);
}
