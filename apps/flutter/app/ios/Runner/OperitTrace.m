// OperitTrace.m
// 最早期诊断追踪：在 main() 之前写入进程启动记录，并捕获 native 崩溃与未捕获异常。
// 背景：越狱设备启动早期无系统日志设施，且 Dart 之前崩溃无任何痕迹。
// 本文件保证"只要进程被 dyn-loaded 起来就留痕"，无论之后闪退还是白屏。
// 同时追踪 dyld 镜像加载（死在加载期也能看到最后一个加载的库）、进程退出、环境快照。
#import <Foundation/Foundation.h>
#import <signal.h>
#import <execinfo.h>
#import <unistd.h>
#import <string.h>
#import <time.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>

static int g_trace_fds[8];
static int g_trace_nfds = 0;

// 候选路径：优先 .operit，/tmp 兜底（rootless 下至少有一处可写）
static const char *kTracePaths[] = {
    "/var/mobile/trace.log",
    "/var/mobile/.operit/trace.log",
    "/var/jb/var/mobile/.operit/trace.log",
    "/tmp/trace.log",
    NULL
};

static void trace_raw(const char *msg) {
    if (!msg) return;
    size_t len = strlen(msg);
    for (int i = 0; i < g_trace_nfds; i++) {
        write(g_trace_fds[i], msg, len);
    }
}

static void trace_open(void);  // 前向声明，供 OperitTraceAppend 调用

// 供 Swift / 其他 native 代码统一追加一行（带时间戳）。Swift 可直接调用。
void OperitTraceAppend(const char *msg) {
    if (!msg) return;
    if (g_trace_nfds == 0) trace_open();
    char ts[32];
    time_t t = time(NULL);
    struct tm tmres;
    localtime_r(&t, &tmres);
    strftime(ts, sizeof(ts), "%Y-%m-%dT%H:%M:%S", &tmres);
    char buf[2048];
    snprintf(buf, sizeof(buf), "[%s] %s\n", ts, msg);
    trace_raw(buf);
}

static void trace_open(void) {
    // 只创建真实根下属于我们自己的目录。绝不 mkdir /var/jb 下任何东西：
    // 那会凭空造出 /var/jb，进而毒化所有基于它的环境判定
    // （真机已坐实：正是这样白屏的）。0777 是为了 root 先建时 mobile 仍可写。
    mkdir("/var/mobile/.operit", 0777);
    chmod("/var/mobile/.operit", 0777);
    // 只有确认是 rootless（有完整 jb 树）时才允许写 /var/jb 候选。
    int rootless = (access("/var/jb/usr/lib", F_OK) == 0);
    for (int i = 0; kTracePaths[i]; i++) {
        const char *p = kTracePaths[i];
        if (!rootless && strncmp(p, "/var/jb/", 8) == 0) {
            continue;
        }
        int fd = open(p, O_WRONLY | O_CREAT | O_APPEND, 0666);
        if (fd >= 0 && g_trace_nfds < 8) {
            g_trace_fds[g_trace_nfds++] = fd;
        }
    }
}

static const char *sig_name(int sig) {
    switch (sig) {
        case SIGABRT: return "SIGABRT";
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS:  return "SIGBUS";
        case SIGILL:  return "SIGILL";
        case SIGTRAP: return "SIGTRAP";
        case SIGFPE:  return "SIGFPE";
        default:      return "SIG?";
    }
}

// dyld 镜像加载追踪：记录每一个被加载的动态库/框架。
// 若进程死在 dyld 加载期，trace.log 里最后一个 DYLD_LOAD 就是嫌疑库。
static void operit_dyld_add_image(const struct mach_header *mh, intptr_t vmaddr_slide) {
    (void)vmaddr_slide;
    Dl_info info;
    const char *name = "?";
    if (dladdr(mh, &info) && info.dli_fname) name = info.dli_fname;
    char buf[2048];
    snprintf(buf, sizeof(buf), "DYLD_LOAD #%d %s\n", _dyld_image_count(), name);
    trace_raw(buf);
}

// 进程正常退出钩子
static void operit_atexit(void) {
    char buf[256];
    snprintf(buf, sizeof(buf), "PROCESS_EXIT pid=%d\n", getpid());
    trace_raw(buf);
}

// 启动环境快照：身份、越狱视图、可执行路径、bundle id、注入库
static void operit_env_snapshot(void) {
    char buf[2048];
    snprintf(buf, sizeof(buf), "UID=%d EUID=%d\n", getuid(), geteuid());
    trace_raw(buf);
    trace_raw(access("/var/jb", F_OK) == 0 ? "VAR_JB_EXISTS=YES\n" : "VAR_JB_EXISTS=NO\n");
    char exep[1024]; uint32_t exesz = sizeof(exep);
    if (_NSGetExecutablePath(exep, &exesz) == 0) {
        snprintf(buf, sizeof(buf), "EXE=%s\n", exep);
        trace_raw(buf);
    }
    NSString *bid = [NSBundle mainBundle].bundleIdentifier;
    if (bid) {
        snprintf(buf, sizeof(buf), "BID=%s\n", [bid UTF8String]);
        trace_raw(buf);
    }
    const char *ins = getenv("DYLD_INSERT_LIBRARIES");
    snprintf(buf, sizeof(buf), "DYLD_INSERT_LIBRARIES=%s\n", ins ? ins : "(null)");
    trace_raw(buf);
}

static void operit_crash_handler(int sig, siginfo_t *info, void *ucontext);
static void operit_uncaught_handler(NSException *e);

__attribute__((constructor))
static void operit_trace_init(void) {
    trace_open();
    char buf[256];
    time_t t = time(NULL);
    snprintf(buf, sizeof(buf), "\n=== OPERIT_TRACE pid=%d time=%ld ===\n", getpid(), (long)t);
    trace_raw(buf);

    // 启动环境快照
    operit_env_snapshot();

    // 追踪 dyld 镜像加载（含已加载的 + 之后加载的）
    _dyld_register_func_for_add_image(operit_dyld_add_image);
    // 进程退出钩子
    atexit(operit_atexit);

    // 捕获 native 崩溃信号
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = operit_crash_handler;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);
    sigaction(SIGILL,  &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
    sigaction(SIGFPE,  &sa, NULL);

    // 捕获未处理的 Objective-C 异常
    NSSetUncaughtExceptionHandler(operit_uncaught_handler);
}

static void operit_crash_handler(int sig, siginfo_t *info, void *ucontext) {
    (void)info;
    (void)ucontext;
    char buf[1024];
    snprintf(buf, sizeof(buf), "CRASH signal=%d (%s) pid=%d\n", sig, sig_name(sig), getpid());
    trace_raw(buf);
    void *addrs[64];
    int cnt = backtrace(addrs, 64);
    for (int i = 0; i < cnt; i++) {
        snprintf(buf, sizeof(buf), "  #%d %p\n", i, addrs[i]);
        trace_raw(buf);
    }
    // 还原默认处理器并重发，让系统也记录这次崩溃
    struct sigaction dfl;
    memset(&dfl, 0, sizeof(dfl));
    dfl.sa_handler = SIG_DFL;
    sigaction(sig, &dfl, NULL);
    raise(sig);
}

static void operit_uncaught_handler(NSException *e) {
    char buf[1024];
    const char *name = [[e name] UTF8String] ?: "?";
    const char *reason = [[e reason] UTF8String] ?: "?";
    snprintf(buf, sizeof(buf), "UNCAUGHT_EXCEPTION name=%s reason=%s\n", name, reason);
    trace_raw(buf);
    NSArray<NSString *> *syms = [e callStackSymbols];
    for (NSString *s in syms) {
        const char *c = [s UTF8String];
        if (c) {
            snprintf(buf, sizeof(buf), "  %s\n", c);
            trace_raw(buf);
        }
    }
}
