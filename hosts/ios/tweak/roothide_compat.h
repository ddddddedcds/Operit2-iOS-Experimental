// roothide_compat.h — runtime jailbreak-environment detection for the operit
// tweaks (one binary, correct on both rootless and roothide).
//
// WHY NOT `/var/jb` EXISTS?
// -------------------------
// The old code (and the Rust/Swift/Dart siblings) decided "rootless vs roothide"
// by testing whether `/var/jb` exists. That is WRONG and was proven wrong on a
// real roothide device: our own tweak wrote to `jbroot("/var/jb/...")` while the
// identity stub was compiled in, which CREATED a real `/var/jb` tree owned by
// root:wheel. From then on every component mis-detected the device as rootless,
// pointed its data root at an unwritable root-owned directory, and the Flutter
// app white-screened because it could not create its log directory.
//
// THE RELIABLE TEST
// -----------------
// Ask "who installed me?" instead of "does some directory exist?".
// roothide installs the entire jailbreak tree inside
//   /var/containers/Bundle/Application/.jbroot-XXXXXXXXXXXXXXXX/
// so ANY binary it installs (app, daemon, dylib) has that path component in its
// own physical path. Verified on device:
//   /var/containers/Bundle/Application/.jbroot-58EAA282AAFACD0F/Library/
//       MobileSubstrate/DynamicLibraries/operit-app.dylib
//   /var/containers/Bundle/Application/.jbroot-58EAA282AAFACD0F/Applications/
//       Runner.app/Runner
// rootless (Dopamine/ElleKit) installs under /var/jb/... — no `.jbroot-` segment.
// This is self-evident and cannot be polluted by a stray `/var/jb` directory.
//
// PATH POLICY
// -----------
// Call sites keep writing rootless-style paths ("/var/jb/var/mobile/.operit/x").
//   rootless : returned unchanged (it is already the real path).
//   roothide : the `/var/jb` prefix is stripped, giving the REAL rootfs path
//              ("/var/mobile/.operit/x"). This matches the Rust daemon and the
//              Swift host, so tweak + daemon + app all share one data root and
//              nothing is ever created under `/var/jb`.
#ifndef OPERIT_ROOTHIDE_COMPAT_H
#define OPERIT_ROOTHIDE_COMPAT_H

#import <Foundation/Foundation.h>
#include <dlfcn.h>

/// Physical jbroot prefix of THIS dylib, e.g.
/// "/var/containers/Bundle/Application/.jbroot-58EAA282AAFACD0F".
/// Returns nil when not installed by roothide (rootless / non-jailbroken).
static NSString *operit_jbroot_prefix(void) {
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info;
        // Take the address of a symbol in this very image so dladdr resolves to
        // the dylib itself, not to whichever host process loaded us.
        if (dladdr((const void *)&operit_jbroot_prefix, &info) != 0 && info.dli_fname) {
            NSString *selfPath = [NSString stringWithUTF8String:info.dli_fname];
            NSRange marker = [selfPath rangeOfString:@"/.jbroot-"];
            if (marker.location != NSNotFound) {
                NSUInteger scan = marker.location + 1; // keep the leading '/'
                NSRange tail = NSMakeRange(scan, selfPath.length - scan);
                NSRange slash = [selfPath rangeOfString:@"/" options:0 range:tail];
                NSUInteger end = (slash.location == NSNotFound) ? selfPath.length
                                                                : slash.location;
                cached = [selfPath substringToIndex:end];
            }
        }
    });
    return cached;
}

/// YES when running under roothide (decided by our own install path).
static inline BOOL operit_is_roothide(void) {
    return operit_jbroot_prefix() != nil;
}

/// Map a rootless-style path to the real path for the current environment.
/// See PATH POLICY above.
static NSString *operit_env_path(NSString *path) {
    if (!path) return path;
    if (!operit_is_roothide()) return path; // rootless: already the real path
    if ([path isEqualToString:@"/var/jb"]) return @"/";
    if ([path hasPrefix:@"/var/jb/"]) {
        return [path substringFromIndex:7]; // drop "/var/jb", keep leading '/'
    }
    return path;
}

// Backwards-compatible alias so any missed call site still compiles and behaves
// correctly. New code should call operit_env_path() directly.
#define jbroot(p) operit_env_path(p)

#endif
