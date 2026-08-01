// operit-app.x
// Operit for iOS — per-app injected dylib.
// Injected into every GUI app (UIKit filter; SpringBoard and our own app excluded
// in the constructor). Serves a per-pid Unix socket that operit-sb forwards to,
// handling cross-app text injection into the focused input. Also reports the host
// app's pid (front.pid) so operit-sb's `type` can target the foreground app.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <pthread.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include "operit_log.h"

static int g_appfd = -1;
static NSString *g_sockpath_app = nil;   // 本进程的 per-pid socket 路径，退出时清理

// 前向声明（下面定义的 helper）
static void clear_front_pid_if_mine(pid_t pid);

// App 退出时清理：删 socket 文件 + 若 front.pid 是自身则清掉（避免残留 stale socket）。
static void app_cleanup(void) {
    if (g_sockpath_app) {
        unlink([g_sockpath_app UTF8String]);
        oc_log("app socket unlinked: %s", [g_sockpath_app UTF8String]);
    }
    clear_front_pid_if_mine(getpid());
}

// 前台 pid 文件：注入的 app 在“上台/变为活跃”时把自身 pid 写入，
// 进入后台时若是自己则清除。operit-sb 的 `type` 命令直接读它来定位前台 app 的 per-pid socket，
// 比让 SpringBoard 猜 frontmost 更稳定（UIApplicationDidBecomeActive 是公开稳定 API）。
static NSString *g_frontpath = @"/var/jb/var/mobile/.operit/front.pid";

static void write_front_pid(pid_t pid) {
    NSString *s = [NSString stringWithFormat:@"%d", (int)pid];
    [s writeToFile:g_frontpath atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

static void clear_front_pid_if_mine(pid_t pid) {
    NSString *cur = [NSString stringWithContentsOfFile:g_frontpath
                                              encoding:NSUTF8StringEncoding error:nil];
    if (cur && [cur intValue] == (int)pid) {
        [[NSFileManager defaultManager] removeItemAtPath:g_frontpath error:nil];
    }
}

// 所有可见窗口：iOS 13+ 用 connectedScenes（app.windows 在 iOS 15 SDK 被标 deprecated
// 且本项目 -Werror，故走 scene 路径，旧单窗口 App 用 pragma 兜底）。
static NSArray *all_windows(void) {
    UIApplication *app = [UIApplication sharedApplication];
    NSMutableArray *res = [NSMutableArray array];
    if ([app respondsToSelector:@selector(connectedScenes)]) {
        for (UIScene *sc in app.connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]])
                [res addObjectsFromArray:[(UIWindowScene *)sc windows]];
        }
    }
    if (res.count == 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [res addObjectsFromArray:app.windows];
#pragma clang diagnostic pop
    }
    return res;
}

// 类→role 映射
static NSString *role_for_view(UIView *v) {
    if      ([v isKindOfClass:[UIButton class]])          return @"AXButton";
    else if ([v isKindOfClass:[UILabel class]])           return @"AXStaticText";
    else if ([v isKindOfClass:[UITextField class]])       return @"AXTextField";
    else if ([v isKindOfClass:[UITextView class]])        return @"AXTextArea";
    else if ([v isKindOfClass:[UIImageView class]])       return @"AXImage";
    else if ([v isKindOfClass:[UISwitch class]])          return @"AXSwitch";
    else if ([v isKindOfClass:[UISlider class]])          return @"AXSlider";
    else if ([v isKindOfClass:[UIStepper class]])         return @"AXStepper";
    else if ([v isKindOfClass:[UISegmentedControl class]])return @"AXTab";
    else if ([v isKindOfClass:[UITableView class]])       return @"AXList";
    else if ([v isKindOfClass:[UICollectionView class]])  return @"AXGrid";
    else if ([v isKindOfClass:[UITableViewCell class]] ||
             [v isKindOfClass:[UICollectionViewCell class]]) return @"AXCell";
    else if ([v isKindOfClass:[UIScrollView class]])      return @"AXScrollArea";
    else if ([v isKindOfClass:NSClassFromString(@"WKWebView")] ||
             [v isKindOfClass:NSClassFromString(@"UIWebView")]) return @"AXWebArea";
    else if ([v isKindOfClass:NSClassFromString(@"UINavigationBar")]) return @"AXNavigationBar";
    else if ([v isKindOfClass:NSClassFromString(@"UITabBar")]) return @"AXTabBar";
    else if ([v isKindOfClass:NSClassFromString(@"UIAlertController")]) return @"AXAlert";
    return @"AXUnknown";
}

// accessibilityTraits → 可读串（便于 LLM 判断元素性质）
static NSString *traits_string_for(UIAccessibilityTraits t) {
    if (t == UIAccessibilityTraitNone) return @"";
    NSMutableArray *a = [NSMutableArray array];
    if (t & UIAccessibilityTraitButton)               [a addObject:@"Button"];
    if (t & UIAccessibilityTraitLink)                 [a addObject:@"Link"];
    if (t & UIAccessibilityTraitHeader)               [a addObject:@"Header"];
    if (t & UIAccessibilityTraitSearchField)          [a addObject:@"SearchField"];
    if (t & UIAccessibilityTraitImage)                [a addObject:@"Image"];
    if (t & UIAccessibilityTraitSelected)             [a addObject:@"Selected"];
    if (t & UIAccessibilityTraitKeyboardKey)          [a addObject:@"Key"];
    if (t & UIAccessibilityTraitStaticText)           [a addObject:@"StaticText"];
    if (t & UIAccessibilityTraitPlaysSound)           [a addObject:@"PlaysSound"];
    if (t & UIAccessibilityTraitUpdatesFrequently)    [a addObject:@"UpdatesFrequently"];
    if (t & UIAccessibilityTraitStartsMediaSession)   [a addObject:@"StartsMedia"];
    if (t & UIAccessibilityTraitAdjustable)           [a addObject:@"Adjustable"];
    if (t & UIAccessibilityTraitAllowsDirectInteraction) [a addObject:@"Direct"];
    if (t & UIAccessibilityTraitCausesPageTurn)       [a addObject:@"PageTurn"];
    if (t & UIAccessibilityTraitTabBar)               [a addObject:@"TabBar"];
    return [a componentsJoinedByString:@","];
}
static NSString *traits_string(UIView *v) { return traits_string_for(v.accessibilityTraits); }

// 前向声明：两函数互相递归

// 递归找当前 first responder（聚焦的输入框）。
static UIView *find_first_responder(UIView *root) {
    if ([root isFirstResponder]) return root;
    for (UIView *sub in root.subviews) {
        UIView *f = find_first_responder(sub);
        if (f) return f;
    }
    return nil;
}

// 把文本灌进聚焦输入框：先清空（AutoGLM "自动清除文本" 语义）再 insertText:。
// insertText: 走 UIKeyInput 通道，能正确驱动 SwiftUI @State 绑定；setText: 作兜底。
static NSString *app_type_text(NSString *text) {
    __block NSString *r = @"ERR|type";
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            UIView *fr = nil;
            for (UIWindow *w in all_windows()) {
                fr = find_first_responder(w);
                if (fr) break;
            }
            if (!fr) { r = @"ERR|type: no focused input (tap it first)"; return; }
            id target = fr;
            // UISearchBar 的输入框在其 searchTextField（iOS 13+）
            if ([fr isKindOfClass:NSClassFromString(@"UISearchBar")]) {
                SEL st = sel_registerName("searchTextField");
                if ([fr respondsToSelector:st]) target = [fr performSelector:st];
            }
            if (!target) { r = @"ERR|type: no target"; return; }
            // 清空已有内容
            if ([target respondsToSelector:@selector(setText:)]) {
                @try { [target setText:@""]; } @catch (NSException *e) { (void)e; }
            }
            // 输入新文本
            if ([target respondsToSelector:@selector(insertText:)]) {
                [target insertText:text];
                r = [NSString stringWithFormat:@"OK|typed %lu chars", (unsigned long)text.length];
            } else if ([target respondsToSelector:@selector(setText:)]) {
                [target setText:text];
                r = [NSString stringWithFormat:@"OK|typed(setText) %lu chars", (unsigned long)text.length];
            } else {
                r = @"ERR|type: target not a text input";
            }
        } @catch (NSException *ex) { r = [NSString stringWithFormat:@"ERR|type: %@", ex.reason]; }
    });
    return r;
}

// 读取一行请求：遇换行即止（probe 发来的请求以 '\n' 结尾）。
// 用循环读取替代原 512 字节定长缓冲，避免长 type 文本被截断；
// 同时只在见到换行后停止，避免与“发完即等响应”的对端互相等待造成死锁。
static NSString *app_read_request(int fd) {
    NSMutableData *data = [NSMutableData data];
    char buf[4096];
    ssize_t n;
    while ((n = recv(fd, buf, sizeof(buf), 0)) > 0) {
        [data appendBytes:buf length:(NSUInteger)n];
        if (memchr(buf, '\n', (size_t)n)) break;   // 收齐一行，停止读取
        if (data.length > (1 << 20)) break;        // 1MB 安全上限
    }
    if (data.length == 0) return nil;
    NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [line stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
}

static void *app_server_thread(void *unused) {
    (void)unused;
    while (1) {
        int c = accept(g_appfd, NULL, NULL);
        if (c < 0) continue;
        NSString *line = app_read_request(c);
        if (line.length > 0) {
            NSString *resp = @"ERR|unknown";
            if ([line isEqualToString:@"ping"]) resp = @"OK";
            else if ([line hasPrefix:@"type "])      resp = app_type_text([line substringFromIndex:5]);
            const char *r = [resp UTF8String];
            if (r) send(c, r, (size_t)strlen(r), 0);
        }
        close(c);
    }
    return NULL;
}

%ctor {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if ([bid isEqualToString:@"com.apple.SpringBoard"]) return;   // 不注入 SpringBoard
    // 不注入 Operit2 自身 app（bundle id = com.ai.assistance.operit2），避免无谓注入/递归；
    // 同时兜底跳过 ai.operit.* 系列包。
    if ([bid isEqualToString:@"com.ai.assistance.operit2"] || [bid hasPrefix:@"ai.operit."]) return;
    // 排除 WebKit 辅助进程（WebContent / Networking / GPU 等）：
    // 它们也会加载 UIKit 被本 dylib 注入，但不是 GUI App；注入后 %ctor 内的
    // bind() 创建 per-pid socket 会崩溃（Address size fault），导致 Safari 等
    // 所有网页无法渲染。主 App（com.apple.mobilesafari）不在此前缀下，仍正常
    // 注入，保留地址栏/搜索框的跨 App 打字能力。
    if ([bid hasPrefix:@"com.apple.WebKit."]) return;
    int pid = getpid();
    g_oc_logpath = [NSString stringWithFormat:@"/var/jb/var/mobile/.operit/logs/app-%d.log", pid];
    oc_log("app init bid=%s pid=%d", [bid UTF8String], pid);

    // 上报前台 pid：启动时写一次，上台时更新，进后台若为自身则清除（home 屏 front.pid 为空）。
    write_front_pid(pid);
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil queue:nil
                usingBlock:^(NSNotification *n){ (void)n; write_front_pid(getpid()); }];
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidEnterBackgroundNotification
                    object:nil queue:nil
                usingBlock:^(NSNotification *n){ (void)n; clear_front_pid_if_mine(getpid()); }];
    oc_log("front.pid observers registered");

    NSString *path = [NSString stringWithFormat:@"/var/jb/var/mobile/.operit/app.%d.sock", pid];
    unlink([path UTF8String]);
    g_sockpath_app = path;   // 记下供退出清理
    g_appfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (g_appfd < 0) return;
    struct sockaddr_un a; memset(&a, 0, sizeof(a)); a.sun_family = AF_UNIX;
    strncpy(a.sun_path, [path UTF8String], sizeof(a.sun_path) - 1);
    if (bind(g_appfd, (struct sockaddr *)&a, sizeof(a)) < 0) { close(g_appfd); g_appfd = -1; return; }
    listen(g_appfd, 4);
    // 退出清理：正常终止走通知，崩溃/被杀走 atexit（崩溃时可能来不及，但尽力）
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationWillTerminateNotification
                    object:nil queue:nil
                usingBlock:^(NSNotification *n){ (void)n; app_cleanup(); }];
    atexit(app_cleanup);
    pthread_t t; pthread_create(&t, NULL, app_server_thread, NULL);
}
