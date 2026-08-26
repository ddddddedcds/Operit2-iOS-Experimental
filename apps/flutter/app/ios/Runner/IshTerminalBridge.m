#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

// iSH kernel=ish (userspace emulation) API. This is the App Store-safe
// configuration: a real aarch64 Linux userspace is emulated, so no real
// kernel image is embedded and the iOS sandbox does not panic.
//
// All symbols below are provided by libish.a / libish_emu.a / libfakefs.a
// (built from OpenMinis/ish-arm64, feature-arm64, with -Dkernel=ish
// -Dguest_arch=arm64 -DISH_INTERNAL).
#include "kernel/init.h"   // mount_root, become_first_process, become_new_init_child, set_console_device, create_stdio
#include "kernel/calls.h"  // do_execve, generic_open, fd_close
#include "kernel/task.h"   // task_start, exit_hook, current, struct task
#include "kernel/fs.h"     // do_mount, generic_mknodat/mkdirat/setattrat, fakefs/procfs/devptsfs
#include "fs/tty.h"        // tty_input, tty_set_winsize, tty_hangup, pty_open_fake, struct tty, DEFINE_TTY_DRIVER
#include "fs/devices.h"    // TTY_CONSOLE_MAJOR, TTY_ALTERNATE_MAJOR, DEV_*_MINOR, MEM_MAJOR, dev_make
#include "fs/path.h"       // AT_PWD
#include "fs/stat.h"       // S_IFCHR
#include "fs/fake.h"       // fakefs_open_inode
#include "tools/fakefs.h"  // fakefs_import, fakefsify_error
#include "kernel/errno.h"  // IS_ERR / PTR_ERR / _EEXIST

// Host-app glue contract expected by the iSH emulation core. Upstream iSH
// declares these in app/LinuxInterop.h; we replicate the minimal contract here
// instead of pulling in the iSH iOS app headers (which require __KERNEL__ and
// linux/* includes that don't apply to this embedded bridge).
typedef const void *nsobj_t;
void FsInitialize(void);
void ReportPanic(const char *message);

// iSH's panic handler pointer (declared in debug.h); we override it so a
// kernel die() terminates only the iSH thread instead of abort()ing the app.
extern void (*die_handler)(const char *msg);

static const NSUInteger ORTIshOutputCapacity = 1024 * 1024;
static const NSTimeInterval ORTIshStartTimeout = 30.0;

@interface ORTIshTerminalSession : NSObject
@property(nonatomic, copy) NSString *sessionId;
@property(nonatomic, copy) NSString *sessionName;
@property(nonatomic, copy) NSString *workingDir;
@property(nonatomic, assign) struct tty *tty;       // pty slave created via pty_open_fake
@property(nonatomic, assign) pid_t_ guestPid;        // iSH pid of the session shell
@property(nonatomic, strong) NSMutableData *pendingOutput;
@property(nonatomic, strong) NSMutableData *screenOutput;
@property(nonatomic, assign) NSInteger rows;
@property(nonatomic, assign) NSInteger cols;
@property(nonatomic, assign) BOOL commandRunning;
@property(nonatomic, assign) BOOL closed;
@property(nonatomic, assign) NSInteger exitCode;
@property(nonatomic, assign) BOOL hasExitCode;
@property(nonatomic, strong) dispatch_semaphore_t startSignal;
@end

@implementation ORTIshTerminalSession

- (instancetype)init {
  self = [super init];
  if (self) {
    _pendingOutput = [NSMutableData data];
    _screenOutput = [NSMutableData data];
    _startSignal = dispatch_semaphore_create(0);
  }
  return self;
}

@end

// ---------------------------------------------------------------------------
// Process-global state
// ---------------------------------------------------------------------------

static NSMutableDictionary<NSString *, ORTIshTerminalSession *> *ORTIshSessions;
static NSMutableDictionary<NSString *, NSString *> *ORTIshSessionKeys;
static NSMutableDictionary<NSNumber *, ORTIshTerminalSession *> *ORTIshTtySessions; // tty pointer -> session (output routing)
static NSMutableDictionary<NSNumber *, ORTIshTerminalSession *> *ORTIshPidToSession; // guest pid -> session
static NSLock *ORTIshStateLock;
static NSLock *ORTIshStartLock;
static NSString *ORTIshRootPath;        // .../operit-ish/rootfs  (container with data/ + meta.db)
static BOOL ORTIshKernelStarted;
static uint64_t ORTIshNextSessionId;
static dispatch_queue_t ORTIshWorkQueue; // serial queue for iSH workqueue callbacks

static void ORTIshInitializeState(void) {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    ORTIshSessions = [NSMutableDictionary dictionary];
    ORTIshSessionKeys = [NSMutableDictionary dictionary];
    ORTIshTtySessions = [NSMutableDictionary dictionary];
    ORTIshPidToSession = [NSMutableDictionary dictionary];
    ORTIshStateLock = [NSLock new];
    ORTIshStartLock = [NSLock new];
    ORTIshNextSessionId = 1;
    ORTIshWorkQueue = dispatch_queue_create("com.operit.ish.work", DISPATCH_QUEUE_SERIAL);
  });
}

// ---------------------------------------------------------------------------
// JSON envelope helpers
// ---------------------------------------------------------------------------

static NSDictionary *ORTIshResult(id result) {
  return @{ @"result" : result ?: [NSNull null] };
}

static NSDictionary *ORTIshError(NSString *message) {
  return @{ @"error" : message ?: @"iSH terminal bridge failed" };
}

static char *ORTIshEncodeResponse(NSDictionary *response) {
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:response options:0 error:&error];
  if (data == nil) {
    return strdup("{\"error\":\"iSH terminal response encoding failed\"}");
  }
  return strdup([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}

static NSString *ORTIshRequiredString(NSDictionary *request, NSString *key, NSString **errorOut) {
  id value = request[key];
  if (![value isKindOfClass:[NSString class]] || [((NSString *)value) length] == 0) {
    *errorOut = [NSString stringWithFormat:@"iSH terminal request has invalid %@", key];
    return nil;
  }
  return value;
}

static NSInteger ORTIshPositiveDimension(NSDictionary *request, NSString *key, NSString **errorOut) {
  id value = request[key];
  if (![value isKindOfClass:[NSNumber class]] || [value integerValue] <= 0) {
    *errorOut = [NSString stringWithFormat:@"iSH terminal request has invalid %@", key];
    return 0;
  }
  return [value integerValue];
}

static ORTIshTerminalSession *ORTIshSession(NSString *sessionId, NSString **errorOut) {
  ORTIshInitializeState();
  [ORTIshStateLock lock];
  ORTIshTerminalSession *session = ORTIshSessions[sessionId];
  [ORTIshStateLock unlock];
  if (session == nil) {
    *errorOut = [NSString stringWithFormat:@"iSH terminal session does not exist: %@", sessionId];
  }
  return session;
}

static NSString *ORTIshText(NSData *data, NSString **errorOut) {
  NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (text == nil) {
    *errorOut = @"iSH terminal emitted non-UTF-8 output";
  }
  return text;
}

static NSData *ORTIshDrainOutput(ORTIshTerminalSession *session) {
  @synchronized (session) {
    NSData *output = [session.pendingOutput copy];
    [session.pendingOutput setLength:0];
    return output;
  }
}

// ---------------------------------------------------------------------------
// TTY driver + output routing
// ---------------------------------------------------------------------------

// One driver backs both the init console (TTY_CONSOLE_MAJOR) and session PTYs.
// Its write callback routes guest output to the owning session's buffers.
static int ish_tty_write(struct tty *tty, const void *buf, size_t len, bool blocking);

static int ish_tty_init(struct tty *tty) { (void)tty; return 0; }
static void ish_tty_cleanup(struct tty *tty) { (void)tty; }

static struct tty_driver_ops ish_console_ops = {
    .init = ish_tty_init,
    .write = ish_tty_write,
    .cleanup = ish_tty_cleanup,
};

DEFINE_TTY_DRIVER(ish_console_driver, &ish_console_ops, TTY_CONSOLE_MAJOR, 8);
// pty_open_fake() overrides ->ttys/->major/->limit; we only need the ops.
static struct tty_driver ish_pty_driver = {.ops = &ish_console_ops};

// Called by the emulated shell's write() syscall. Routes bytes to the session
// that owns this tty (looked up by tty pointer). Runs on the iSH emulation
// thread; the session buffers are synchronized via @synchronized.
static int ish_tty_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
  (void)blocking;
  if (len == 0) return 0;
  ORTIshTerminalSession *session = nil;
  [ORTIshStateLock lock];
  session = ORTIshTtySessions[@((uintptr_t)tty)];
  [ORTIshStateLock unlock];
  if (session != nil) {
    @synchronized (session) {
      if (session.pendingOutput.length + len <= ORTIshOutputCapacity) {
        [session.pendingOutput appendBytes:buf length:len];
        [session.screenOutput appendBytes:buf length:len];
      }
    }
  }
  return (int)len;
}

// ---------------------------------------------------------------------------
// Kernel lifecycle
// ---------------------------------------------------------------------------

// Imports the bundled aarch64 Alpine root archive into the persistent iSH
// fakefs container (data/ + meta.db). Idempotent: skips import once present.
static BOOL ORTIshPrepareRoot(NSString **errorOut) {
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSURL *supportDirectory = [fileManager URLsForDirectory:NSApplicationSupportDirectory
                                                inDomains:NSUserDomainMask].firstObject;
  NSURL *runtimeDirectory = [supportDirectory URLByAppendingPathComponent:@"operit-ish"];
  NSURL *rootDirectory = [runtimeDirectory URLByAppendingPathComponent:@"rootfs"];
  NSError *directoryError = nil;
  if (![fileManager createDirectoryAtURL:runtimeDirectory
             withIntermediateDirectories:YES
                              attributes:nil
                                   error:&directoryError]) {
    *errorOut = directoryError.localizedDescription;
    return NO;
  }
  if ([fileManager fileExistsAtPath:rootDirectory.path]) {
    ORTIshRootPath = rootDirectory.path;
    return YES;
  }
  NSURL *archive = [NSBundle.mainBundle URLForResource:@"ish-root" withExtension:@"tar.gz"];
  if (archive == nil) {
    *errorOut = @"Bundled iSH Alpine root archive is missing";
    return NO;
  }
  struct fakefsify_error fakefsError = {};
  if (!fakefs_import(archive.fileSystemRepresentation, rootDirectory.fileSystemRepresentation,
                     &fakefsError, (struct progress){})) {
    NSString *message = fakefsError.message == NULL ? @"iSH root import failed"
                                                    : [NSString stringWithUTF8String:fakefsError.message];
    free(fakefsError.message);
    *errorOut = message;
    return NO;
  }
  ORTIshRootPath = rootDirectory.path;
  return YES;
}

// Creates the minimal /dev + /proc node set the guest userspace expects.
// Existing nodes/dirs are silently ignored (mknodat/mkdirat return EEXIST).
static void ORTIshCreateDeviceNodes(void) {
  generic_mkdirat(AT_PWD, "/dev", 0755);
  generic_mkdirat(AT_PWD, "/dev/pts", 0755);
  generic_mkdirat(AT_PWD, "/proc", 0755);
  generic_mkdirat(AT_PWD, "/tmp", 0777);

  for (int i = 1; i <= 7; i++) {
    NSString *path = [NSString stringWithFormat:@"/dev/tty%d", i];
    generic_mknodat(AT_PWD, path.UTF8String, S_IFCHR | 0666, dev_make(TTY_CONSOLE_MAJOR, i));
  }
  generic_mknodat(AT_PWD, "/dev/tty", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR));
  generic_mknodat(AT_PWD, "/dev/console", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR));
  generic_mknodat(AT_PWD, "/dev/ptmx", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR));
  generic_mknodat(AT_PWD, "/dev/null", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_NULL_MINOR));
  generic_mknodat(AT_PWD, "/dev/zero", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
  generic_mknodat(AT_PWD, "/dev/full", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_FULL_MINOR));
  generic_mknodat(AT_PWD, "/dev/random", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_RANDOM_MINOR));
  generic_mknodat(AT_PWD, "/dev/urandom", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));

  // iSH historically shipped with broken / permissions; restore them.
  generic_setattrat(AT_PWD, "/", (struct attr){.type = attr_mode, .mode = 0755}, false);
}

static void operit_ish_exit_hook(struct task *task, int code) {
  // Only interested in init and direct children of init.
  if (task->parent != NULL && task->parent->parent != NULL)
    return;
  pid_t pid = task->pid;
  ORTIshTerminalSession *session = nil;
  [ORTIshStateLock lock];
  session = ORTIshPidToSession[@(pid)];
  [ORTIshStateLock unlock];
  if (session != nil) {
    @synchronized (session) {
      session.closed = YES;
      session.exitCode = code;
      session.hasExitCode = YES;
    }
    [ORTIshStateLock lock];
    [ORTIshPidToSession removeObjectForKey:@(pid)];
    if (session.tty != NULL) [ORTIshTtySessions removeObjectForKey:@((uintptr_t)session.tty)];
    [ORTIshStateLock unlock];
  }
  NSLog(@"iSH process exited: pid=%d code=%d", (int)pid, code);

  // Diagnostics: dump the session's screen output + exit code to a fixed file
  // so it can be inspected over SSH (idevicesyslog needs USB, which is not
  // always attached). A busybox ash that dies at startup prints its reason to
  // stderr, which lands in screenOutput before this hook fires.
  if (session != nil) {
    @synchronized (session) {
      NSString *screenText = [[NSString alloc] initWithData:session.screenOutput
                                                   encoding:NSUTF8StringEncoding];
      NSString *dump = [NSString stringWithFormat:
          @"--- iSH session exit ---\npid=%d code=%d closed=%d\noutput:\n%@\n--- end ---\n",
          (int)pid, (int)code, session.closed ? 1 : 0,
          screenText ?: @"(non-UTF8)"];
      NSFileManager *fm = [NSFileManager defaultManager];
      [fm createDirectoryAtPath:@"/var/mobile/.operit"
          withIntermediateDirectories:YES attributes:nil error:NULL];
      [dump writeToFile:@"/var/mobile/.operit/ish-session-exit.log"
             atomically:YES encoding:NSUTF8StringEncoding error:NULL];
      NSLog(@"iSH session exit dumped");
    }
  }
}

static void operit_ish_die_handler(const char *msg) {
  ReportPanic(msg);
}

static BOOL ORTIshEnsureKernel(NSString **errorOut) {
  ORTIshInitializeState();
  [ORTIshStateLock lock];
  if (ORTIshKernelStarted) {
    [ORTIshStateLock unlock];
    return YES;
  }
  [ORTIshStateLock unlock];

  if (!ORTIshPrepareRoot(errorOut)) return NO;

  // mount_root takes the fakefs data/ subdirectory (it realpath()s + do_mounts it).
  NSString *dataPath = [ORTIshRootPath stringByAppendingPathComponent:@"data"];
  int err = mount_root(&fakefs, dataPath.fileSystemRepresentation);
  if (err < 0) {
    *errorOut = [NSString stringWithFormat:@"iSH mount_root failed: %d", err];
    return NO;
  }
  err = become_first_process();
  if (err < 0) {
    *errorOut = [NSString stringWithFormat:@"iSH become_first_process failed: %d", err];
    return NO;
  }
  FsInitialize();
  ORTIshCreateDeviceNodes();

  do_mount(&procfs, "proc", "/proc", "", 0);
  do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);

  exit_hook = operit_ish_exit_hook;
  die_handler = operit_ish_die_handler;

  // Register the console driver and attach init's stdio to /dev/console.
  tty_drivers[TTY_CONSOLE_MAJOR] = &ish_console_driver;
  set_console_device(TTY_CONSOLE_MAJOR, 1);
  err = create_stdio("/dev/console", TTY_CONSOLE_MAJOR, 1);
  if (err < 0) {
    NSLog(@"iSH create_stdio(/dev/console) returned %d (non-fatal)", err);
  }

  [ORTIshStateLock lock];
  ORTIshKernelStarted = YES;
  [ORTIshStateLock unlock];
  NSLog(@"iSH kernel=ish booted (aarch64 Alpine guest)");
  return YES;
}

// ---------------------------------------------------------------------------
// Session lifecycle (PTY-backed interactive shell)
// ---------------------------------------------------------------------------

// Forward declarations (defined just below) so ORTIshStartSession can use them.
static BOOL ORTIshWrite(ORTIshTerminalSession *session, NSData *input, NSString **errorOut);
static BOOL ORTIshResize(ORTIshTerminalSession *session, NSInteger rows, NSInteger cols, NSString **errorOut);

static ORTIshTerminalSession *ORTIshStartSession(NSString *sessionName, NSString *workingDir,
                                                 NSInteger rows, NSInteger cols, NSString **errorOut) {
  if (!ORTIshEnsureKernel(errorOut)) return nil;
  ORTIshInitializeState();

  ORTIshTerminalSession *session = [ORTIshTerminalSession new];
  [ORTIshStateLock lock];
  session.sessionId = [NSString stringWithFormat:@"ios-ish-%llu", ORTIshNextSessionId++];
  [ORTIshStateLock unlock];
  session.sessionName = sessionName;
  session.workingDir = workingDir;
  session.rows = rows;
  session.cols = cols;

  // Serialize session creation so the per-thread `current` and pty reservation
  // are never clobbered by a concurrent start on the same host thread.
  [ORTIshStartLock lock];

  struct task *saved_current = current;
  int err = become_new_init_child();
  if (err < 0) {
    current = saved_current;
    [ORTIshStartLock unlock];
    *errorOut = [NSString stringWithFormat:@"iSH session spawn failed: %d", err];
    return nil;
  }
  struct task *task = current;

  // Allocate a fake PTY; pty_open_fake returns the slave tty we feed/observe.
  struct tty *tty = pty_open_fake(&ish_pty_driver);
  if (IS_ERR(tty)) {
    current = saved_current;
    [ORTIshStartLock unlock];
    *errorOut = [NSString stringWithFormat:@"iSH pty allocation failed: %ld", (long)PTR_ERR(tty)];
    return nil;
  }

  [ORTIshStateLock lock];
  ORTIshTtySessions[@((uintptr_t)tty)] = session;
  [ORTIshStateLock unlock];
  session.tty = tty;

  struct winsize_ winsize = {.row = (word_t)rows, .col = (word_t)cols, .xpixel = 0, .ypixel = 0};
  tty_set_winsize(tty, winsize);

  NSString *stdioFile = [NSString stringWithFormat:@"/dev/pts/%d", tty->num];
  err = create_stdio(stdioFile.fileSystemRepresentation, TTY_PSEUDO_SLAVE_MAJOR, tty->num);
  if (err < 0) {
    [ORTIshStateLock lock];
    [ORTIshTtySessions removeObjectForKey:@((uintptr_t)tty)];
    [ORTIshStateLock unlock];
    current = saved_current;
    [ORTIshStartLock unlock];
    *errorOut = [NSString stringWithFormat:@"iSH stdio setup failed: %d", err];
    return nil;
  }

  // argv: "/bin/sh" "-i"  (NUL-separated, double-NUL terminated via memset)
  char argv[4096];
  memset(argv, 0, sizeof(argv));
  size_t ap = 0;
#define ORT_ARG(s) do { \
    const char *_a = (s); size_t _l = strlen(_a) + 1; \
    if (ap + _l < sizeof(argv)) { memcpy(argv + ap, _a, _l); ap += _l; } \
  } while (0)
  ORT_ARG("/bin/sh");
  ORT_ARG("-i");
#undef ORT_ARG

  // envp
  char envp[8192];
  memset(envp, 0, sizeof(envp));
  size_t ep = 0;
#define ORT_ENVP(s) do { \
    const char *_s = (s); size_t _l = strlen(_s) + 1; \
    if (ep + _l < sizeof(envp)) { memcpy(envp + ep, _s, _l); ep += _l; } \
  } while (0)
  ORT_ENVP("TERM=xterm-256color");
  ORT_ENVP("HOME=/root");
  ORT_ENVP("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
  ORT_ENVP("LANG=C.UTF-8");
  ORT_ENVP("PYTHONMALLOC=malloc");
#undef ORT_ENVP

  err = do_execve("/bin/sh", 2, argv, envp);
  if (err < 0) {
    NSLog(@"iSH exec /bin/sh FAILED: err=%d (pid=%d)", err, task->pid);
    [ORTIshStateLock lock];
    [ORTIshTtySessions removeObjectForKey:@((uintptr_t)tty)];
    [ORTIshStateLock unlock];
    current = saved_current;
    [ORTIshStartLock unlock];
    *errorOut = [NSString stringWithFormat:@"iSH exec failed: %d", err];
    return nil;
  }
  NSLog(@"iSH exec /bin/sh OK: pid=%d tty=%d -> task_start", task->pid, tty->num);

  task_start(task);
  current = saved_current;
  [ORTIshStartLock unlock];

  [ORTIshStateLock lock];
  ORTIshSessions[session.sessionId] = session;
  ORTIshSessionKeys[[NSString stringWithFormat:@"shell\n%@", sessionName]] = session.sessionId;
  ORTIshPidToSession[@(task->pid)] = session;
  [ORTIshStateLock unlock];

  // Move into the requested working directory.
  if (workingDir.length > 0) {
    NSString *cdCommand = [NSString stringWithFormat:@"cd -- %@\n", workingDir];
    ORTIshWrite(session, [cdCommand dataUsingEncoding:NSUTF8StringEncoding], errorOut);
  }
  return session;
}

// Feeds UTF-8 bytes into the session PTY. Safe to call from any host thread;
// tty_input is internally locked and wakes the guest reader.
static BOOL ORTIshWrite(ORTIshTerminalSession *session, NSData *input, NSString **errorOut) {
  @synchronized (session) {
    if (session.tty == NULL || session.closed) {
      *errorOut = @"iSH terminal session is not running";
      return NO;
    }
    struct tty *tty = session.tty;
    tty_input(tty, (const char *)(input.bytes), input.length, false);
  }
  return YES;
}

static BOOL ORTIshResize(ORTIshTerminalSession *session, NSInteger rows, NSInteger cols, NSString **errorOut) {
  @synchronized (session) {
    if (session.tty == NULL || session.closed) {
      *errorOut = @"iSH terminal session is not running";
      return NO;
    }
    session.rows = rows;
    session.cols = cols;
    struct tty *tty = session.tty;
    struct winsize_ winsize = {.row = (word_t)rows, .col = (word_t)cols, .xpixel = 0, .ypixel = 0};
    tty_set_winsize(tty, winsize);
  }
  return YES;
}

// ---------------------------------------------------------------------------
// Command execution (marker-based, mirrors the prior implementation)
// ---------------------------------------------------------------------------

static NSDictionary *ORTIshSessionEntry(ORTIshTerminalSession *session) {
  @synchronized (session) {
    return @{
      @"sessionId" : session.sessionId,
      @"sessionName" : session.sessionName,
      @"terminalType" : @"shell",
      @"sessionKind" : @"pty",
      @"workingDir" : session.workingDir,
      @"commandRunning" : @(session.commandRunning),
    };
  }
}

static NSDictionary *ORTIshExecute(ORTIshTerminalSession *session, NSString *command,
                                   uint64_t timeoutMs, NSString **errorOut) {
  NSString *marker = [NSString stringWithFormat:@"__OPERIT_ISH_%@__", NSUUID.UUID.UUIDString];
  NSString *wrapped = [NSString stringWithFormat:@"%@\nprintf '\036%@:%%s\037' \"$?\"\n", command, marker];
  @synchronized (session) {
    if (session.commandRunning) {
      *errorOut = @"iSH terminal already has a command in progress";
      return nil;
    }
    session.commandRunning = YES;
    [session.pendingOutput setLength:0];
  }
  if (!ORTIshWrite(session, [wrapped dataUsingEncoding:NSUTF8StringEncoding], errorOut)) {
    @synchronized (session) {
      session.commandRunning = NO;
    }
    return nil;
  }
  NSMutableData *output = [NSMutableData data];
  NSData *markerData = [marker dataUsingEncoding:NSUTF8StringEncoding];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:(NSTimeInterval)timeoutMs / 1000.0];
  for (;;) {
    [output appendData:ORTIshDrainOutput(session)];
    NSRange markerRange = [output rangeOfData:markerData options:0 range:NSMakeRange(0, output.length)];
    if (markerRange.location != NSNotFound) {
      NSUInteger statusStart = markerRange.location + markerRange.length + 1;
      const uint8_t *bytes = (const uint8_t *)(output.bytes);
      NSUInteger statusEnd = statusStart;
      while (statusEnd < output.length && bytes[statusEnd] != '\037') {
        statusEnd++;
      }
      if (statusEnd == output.length) {
        [NSThread sleepForTimeInterval:0.01];
        continue;
      }
      NSData *statusData = [output subdataWithRange:NSMakeRange(statusStart, statusEnd - statusStart)];
      NSString *statusText = ORTIshText(statusData, errorOut);
      NSInteger exitCode = statusText.integerValue;
      NSData *visibleData = [output subdataWithRange:NSMakeRange(0, markerRange.location)];
      NSString *visibleOutput = ORTIshText(visibleData, errorOut);
      @synchronized (session) {
        session.commandRunning = NO;
      }
      if (visibleOutput == nil || statusText == nil) {
        return nil;
      }
      return @{
        @"sessionId" : session.sessionId,
        @"terminalType" : @"shell",
        @"output" : visibleOutput,
        @"exitCode" : @(exitCode),
        @"timedOut" : @NO,
      };
    }
    if ([deadline timeIntervalSinceNow] <= 0) {
      NSString *interrupt = @"\003";
      ORTIshWrite(session, [interrupt dataUsingEncoding:NSUTF8StringEncoding], errorOut);
      NSString *visibleOutput = ORTIshText(output, errorOut);
      @synchronized (session) {
        session.commandRunning = NO;
      }
      if (visibleOutput == nil) {
        return nil;
      }
      return @{
        @"sessionId" : session.sessionId,
        @"terminalType" : @"shell",
        @"output" : visibleOutput,
        @"exitCode" : @124,
        @"timedOut" : @YES,
      };
    }
    [NSThread sleepForTimeInterval:0.01];
  }
}

// ---------------------------------------------------------------------------
// Command dispatch (preserves the full FFI command set for operit2)
// ---------------------------------------------------------------------------

static NSDictionary *ORTIshHandleCommand(NSString *command, NSDictionary *request) {
  NSString *error = nil;

  // kernel=ish is a userspace emulator; the App-owned runtime mount directory
  // (bind-mount of a host path into iSH) is not wired up in this build.
  if ([command isEqualToString:@"managedRuntimeMount"]) {
    return ORTIshError(@"managedRuntimeMount is not supported under kernel=ish (userspace emulation mode)");
  }
  if ([command isEqualToString:@"terminalStart"]) {
    NSString *sessionName = ORTIshRequiredString(request, @"sessionName", &error);
    NSString *terminalType = ORTIshRequiredString(request, @"terminalType", &error);
    NSString *workingDir = ORTIshRequiredString(request, @"workingDir", &error);
    NSInteger rows = ORTIshPositiveDimension(request, @"rows", &error);
    NSInteger cols = ORTIshPositiveDimension(request, @"cols", &error);
    if (error != nil) return ORTIshError(error);
    if (![terminalType isEqualToString:@"shell"]) return ORTIshError(@"Unsupported iSH terminal type");
    ORTIshTerminalSession *session = ORTIshStartSession(sessionName, workingDir, rows, cols, &error);
    return session == nil ? ORTIshError(error) : ORTIshResult(@{ @"sessionId" : session.sessionId });
  }
  if ([command isEqualToString:@"terminalRead"]) {
    ORTIshTerminalSession *session = ORTIshSession(ORTIshRequiredString(request, @"sessionId", &error), &error);
    if (session == nil) return ORTIshError(error);
    NSString *output = ORTIshText(ORTIshDrainOutput(session), &error);
    return output == nil ? ORTIshError(error) : ORTIshResult(@{ @"output" : output });
  }
  if ([command isEqualToString:@"terminalWrite"]) {
    ORTIshTerminalSession *session = ORTIshSession(ORTIshRequiredString(request, @"sessionId", &error), &error);
    NSString *input = ORTIshRequiredString(request, @"input", &error);
    if (session == nil || input == nil) return ORTIshError(error);
    NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];
    return ORTIshWrite(session, data, &error) ? ORTIshResult(@{ @"acceptedChars" : @(input.length) }) : ORTIshError(error);
  }
  if ([command isEqualToString:@"terminalResize"]) {
    ORTIshTerminalSession *session = ORTIshSession(ORTIshRequiredString(request, @"sessionId", &error), &error);
    NSInteger rows = ORTIshPositiveDimension(request, @"rows", &error);
    NSInteger cols = ORTIshPositiveDimension(request, @"cols", &error);
    if (session == nil || error != nil) return ORTIshError(error);
    return ORTIshResize(session, rows, cols, &error) ? ORTIshResult(@{}) : ORTIshError(error);
  }
  if ([command isEqualToString:@"terminalPoll"]) {
    ORTIshTerminalSession *session = ORTIshSession(ORTIshRequiredString(request, @"sessionId", &error), &error);
    if (session == nil) return ORTIshError(error);
    @synchronized (session) {
      return ORTIshResult(@{ @"exitCode" : session.hasExitCode ? @(session.exitCode) : [NSNull null] });
    }
  }
  if ([command isEqualToString:@"terminalClose"]) {
    ORTIshTerminalSession *session = ORTIshSession(ORTIshRequiredString(request, @"sessionId", &error), &error);
    if (session == nil) return ORTIshError(error);
    @synchronized (session) {
      if (session.tty != NULL) {
        tty_hangup(session.tty);
      }
      session.closed = YES;
      session.exitCode = 0;
      session.hasExitCode = YES;
    }
    return ORTIshResult(@{});
  }
  if ([command isEqualToString:@"terminalList"]) {
    ORTIshInitializeState();
    [ORTIshStateLock lock];
    NSArray<ORTIshTerminalSession *> *sessions = ORTIshSessions.allValues;
    [ORTIshStateLock unlock];
    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:sessions.count];
    for (ORTIshTerminalSession *session in sessions) {
      BOOL closed = NO;
      @synchronized (session) {
        closed = session.closed;
      }
      if (!closed) [entries addObject:ORTIshSessionEntry(session)];
    }
    return ORTIshResult(@{ @"sessions" : entries });
  }
  if ([command isEqualToString:@"terminalCreateOrGet"]) {
    NSString *sessionName = ORTIshRequiredString(request, @"sessionName", &error);
    NSString *terminalType = ORTIshRequiredString(request, @"terminalType", &error);
    if (error != nil) return ORTIshError(error);
    if (![terminalType isEqualToString:@"shell"]) return ORTIshError(@"Unsupported iSH terminal type");
    NSString *key = [NSString stringWithFormat:@"shell\n%@", sessionName];
    ORTIshInitializeState();
    [ORTIshStateLock lock];
    NSString *existingId = ORTIshSessionKeys[key];
    ORTIshTerminalSession *existing = ORTIshSessions[existingId];
    [ORTIshStateLock unlock];
    if (existing != nil) return ORTIshResult(@{ @"sessionId" : existing.sessionId, @"sessionName" : sessionName, @"terminalType" : @"shell", @"isNewSession" : @NO });
    ORTIshTerminalSession *session = ORTIshStartSession(sessionName, @"/", 24, 80, &error);
    return session == nil ? ORTIshError(error) : ORTIshResult(@{ @"sessionId" : session.sessionId, @"sessionName" : sessionName, @"terminalType" : @"shell", @"isNewSession" : @YES });
  }
  if ([command isEqualToString:@"terminalExecute"]) {
    ORTIshTerminalSession *session = ORTIshSession(ORTIshRequiredString(request, @"sessionId", &error), &error);
    NSString *shellCommand = ORTIshRequiredString(request, @"command", &error);
    NSNumber *timeout = request[@"timeoutMs"];
    if (session == nil || shellCommand == nil || ![timeout isKindOfClass:[NSNumber class]]) return ORTIshError(error ?: @"iSH terminal request has invalid timeoutMs");
    NSDictionary *result = ORTIshExecute(session, shellCommand, timeout.unsignedLongLongValue, &error);
    return result == nil ? ORTIshError(error) : ORTIshResult(result);
  }
  if ([command isEqualToString:@"terminalScreen"]) {
    ORTIshTerminalSession *session = ORTIshSession(ORTIshRequiredString(request, @"sessionId", &error), &error);
    if (session == nil) return ORTIshError(error);
    @synchronized (session) {
      NSString *content = ORTIshText(session.screenOutput, &error);
      if (content == nil) return ORTIshError(error);
      return ORTIshResult(@{ @"sessionId" : session.sessionId, @"terminalType" : @"shell", @"rows" : @(session.rows), @"cols" : @(session.cols), @"content" : content, @"commandRunning" : @(session.commandRunning) });
    }
  }
  return ORTIshError([NSString stringWithFormat:@"Unsupported iSH terminal command: %@", command]);
}

// ---------------------------------------------------------------------------
// Rust host FFI entry points
// ---------------------------------------------------------------------------

char *operit_ios_ish_terminal_call(const char *command, const char *request_json) {
  @autoreleasepool {
    if (command == NULL || request_json == NULL) return ORTIshEncodeResponse(ORTIshError(@"iSH terminal bridge request is missing"));
    NSError *jsonError = nil;
    NSData *requestData = [NSData dataWithBytes:request_json length:strlen(request_json)];
    id requestValue = [NSJSONSerialization JSONObjectWithData:requestData options:0 error:&jsonError];
    if (jsonError != nil || ![requestValue isKindOfClass:[NSDictionary class]]) return ORTIshEncodeResponse(ORTIshError(@"iSH terminal request is not a JSON object"));
    return ORTIshEncodeResponse(ORTIshHandleCommand([NSString stringWithUTF8String:command], requestValue));
  }
}

void operit_ios_ish_terminal_free(char *value) {
  free(value);
}

// ---------------------------------------------------------------------------
// Kernel-extern app glue (retained for ABI compatibility with iSH core)
// ---------------------------------------------------------------------------

nsobj_t objc_get(nsobj_t object) {
  return CFBridgingRetain((__bridge id)object);
}

void objc_put(nsobj_t object) {
  CFBridgingRelease(object);
}

void async_do_in_ios(void (^block)(void)) {
  dispatch_async(dispatch_get_main_queue(), block);
}

void async_do_in_workqueue(void (^block)(void)) {
  dispatch_async(ORTIshWorkQueue, block);
}

void sync_do_in_workqueue(void (^block)(void (^done)(void))) {
  dispatch_semaphore_t completion = dispatch_semaphore_create(0);
  async_do_in_workqueue(^{ block(^{ dispatch_semaphore_signal(completion); }); });
  dispatch_semaphore_wait(completion, DISPATCH_TIME_FOREVER);
}

void ConsoleLog(const char *data, unsigned len) {
  NSLog(@"%.*s", (int)len, data);
}

void ReportPanic(const char *message) {
  NSLog(@"iSH kernel panic: %s", message);
}

// No-op filesystem migration hook (the real kernel=linux path used this).
void FsInitialize(void) {
}

nsobj_t UIPasteboard_get(void) {
  return objc_get((__bridge nsobj_t)UIPasteboard.generalPasteboard);
}

long UIPasteboard_changeCount(void) {
  return UIPasteboard.generalPasteboard.changeCount;
}

void UIPasteboard_set(const char *data, size_t len) {
  UIPasteboard.generalPasteboard.string = [[NSString alloc] initWithBytes:data length:len encoding:NSUTF8StringEncoding];
}

size_t NSData_length(nsobj_t data) {
  return [(__bridge NSData *)data length];
}

const void *NSData_bytes(nsobj_t data) {
  return [(__bridge NSData *)data bytes];
}
