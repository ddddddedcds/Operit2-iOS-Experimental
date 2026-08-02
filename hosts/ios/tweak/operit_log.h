// operit_log.h — shared lightweight file logging for the operit tweaks.
// Included by BOTH tweak targets. oc_log is `static` (internal linkage) so each
// .dylib gets its own private copy. operit-app overrides g_oc_logpath in its
// constructor to split per-app logs; operit-sb keeps the default tweak.log.
#ifndef OPERIT_LOG_H
#define OPERIT_LOG_H

#import <Foundation/Foundation.h>
#import "roothide_compat.h"
#include <stdio.h>
#include <stdarg.h>
#include <time.h>

static NSString *g_oc_logpath = jbroot(@"/var/jb/var/mobile/.operit/logs/tweak.log");

static void oc_log(const char *fmt, ...) {
    NSString *dir = jbroot(@"/var/jb/var/mobile/.operit/logs");
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                               withIntermediateDirectories:YES attributes:nil error:nil];
    FILE *f = fopen([g_oc_logpath UTF8String], "a");
    if (!f) return;
    time_t now = time(NULL);
    struct tm tbuf;
    localtime_r(&now, &tbuf);
    fprintf(f, "%04d-%02d-%02d %02d:%02d:%02d ", tbuf.tm_year+1900, tbuf.tm_mon+1, tbuf.tm_mday,
            tbuf.tm_hour, tbuf.tm_min, tbuf.tm_sec);
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fprintf(f, "\n");
    fclose(f);
}

#endif
