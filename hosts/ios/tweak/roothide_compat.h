// roothide_compat.h — portable jbroot() for rootless + roothide builds.
//
// roothide ships <roothide.h> whose jbroot() maps a jbroot-based path
// (e.g. "/var/jb/var/mobile/.operit/foo") to the real rootfs path. On rootless
// the very same "/var/jb/..." string is ALREADY the real path, so an identity
// stub is correct there. We compile the real API only when building under
// roothide/theos (pass -DUSE_ROOTHIDE_API via the Makefile); plain theos /
// rootless builds use the stub. This lets one source tree build for both
// environments with no behavioural change on rootless.
//
// Usage in source:
//   #import "roothide_compat.h"
//   NSString *p = jbroot(@"/var/jb/var/mobile/.operit/foo");
#ifndef OPERIT_ROOTHIDE_COMPAT_H
#define OPERIT_ROOTHIDE_COMPAT_H

#ifdef USE_ROOTHIDE_API
#import <roothide.h>
#else
static inline NSString *operit_jbroot_path(NSString *path) { return path; }
#define jbroot operit_jbroot_path
#endif

#endif
