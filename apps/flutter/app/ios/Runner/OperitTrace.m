// OperitTrace.m
// 最早期诊断追踪：在 main() 之前写入进程启动记录，并捕获 native 崩溃与未捕获异常。
// 背景：roothide 设备无系统日志设施，且 Dart 之前崩溃无任何痕迹。
// 本文件保证"只要进程被 dyn-loaded 起来就留痕"，无论之后闪退还是白屏。
#import <Foundation/Foundation.h>
#import <signal.h>
#import <execinfo.h>
#import <unistd.h>
#import <string.h>
#import <time.h>
#import <sys/stat.h>

static int g_trace_fds[8];
static int g_trace_nfds = 0;

// 候选路径：优先 .operit，/tmp 兜底（roothide 双视图下至少有一处可写）
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

static void trace_open(void) {
    // 尽量保证 .operit 目录存在（忽略一切错误）
    mkdir("/var/mobile/.operit", 0755);
    mkdir("/var/jb/var/mobile/.operit", 0755);
    for (int i = 0; kTracePaths[i]; i++) {
        int fd = open(kTracePaths[i], O_WRONLY | O_CREAT | O_APPEND, 0644);
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

static void operit_crash_handler(int sig, siginfo_t *info, void *ucontext);
static void operit_uncaught_handler(NSException *e);

__attribute__((constructor))
static void operit_trace_init(void) {
    trace_open();
    char buf[256];
    time_t t = time(NULL);
    snprintf(buf, sizeof(buf), "\n=== OPERIT_TRACE pid=%d time=%ld ===\n", getpid(), (long)t);
    trace_raw(buf);

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
