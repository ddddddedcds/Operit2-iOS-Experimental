// operit-sb.x
// Operit for iOS — SpringBoard control tweak (Dopamine rootless + ElleKit).
// Phase 1: exposes a Unix socket so the Operit app (and the operit-probe CLI)
// can drive basic device actions (launch/home/tap/swipe/type/screenshot) over
// a Unix socket. The per-app injected dylib (operit-app.dylib) handles cross-app
// text injection into the focused input.
//
// Hard-won lessons from the old project, baked in from day one:
//  * iOS AX uses AXLabel/AXValue/AXHint (NOT macOS's AXTitle/AXDescription).
//  * UI-affecting calls (launch/home) must run on the main thread.
//  * AX queries must never run on SpringBoard's main thread (deadlock -> safe mode).
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <pthread.h>
#include <string.h>
#include <stdarg.h>
#include <time.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/select.h>
#include <mach/mach_time.h>
#include <notify.h>
#include <sqlite3.h>
#include "operit_log.h"

// ---- app lock（启动拦截名单）----
// 名单文件：/var/mobile/.operit/app_lock.plist（真实根，SpringBoard mobile 可写/读；
// rootless app 无沙箱也可写同一路径）。
// 格式：{ "<bundleId>": { "title": "...", "subtitle": "...", "button": "..." }, ... }
// 拦截点：FBSSystemService / FBSOpenApplicationService（FrontBoard 统一启动入口，
// SpringBoard 前台启动与外部请求都汇聚于此）+ 本 tweak 的 cmd_launch（AI 主动启动一致拦截）。

static NSString *g_lockPath; // 由 operit_tweak_init_paths() 在 load 时解析（rootless 真实根）

// ---- 设置面板（PreferenceLoader：设置 → Operit2）总开关 ----
// NSUserDefaults 域 com.operit；与 AI 命令的文件开关（app_lock.plist /
// notif_block.plist / clipboard_enabled）并存：面板开关是总控，文件机制保留。
static NSUserDefaults *operit_cfg(void) {
    static NSUserDefaults *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = [[NSUserDefaults alloc] initWithSuiteName:@"com.operit"];
    });
    return d;
}

static BOOL operit_cfg_bool(NSString *key, BOOL def) {
    id v = [operit_cfg() objectForKey:key];
    return v ? [v boolValue] : def;
}

static NSDictionary *lock_load(void) {
    return [NSDictionary dictionaryWithContentsOfFile:g_lockPath] ?: @{};
}

static NSDictionary *lock_cfg_for(NSString *bid) {
    // 面板总开关：关 = 锁定功能整体停（拦截 + 通知联动）
    if (!operit_cfg_bool(@"applockEnabled", YES)) return nil;
    if (!bid || bid.length == 0) return nil;
    return lock_load()[bid];
}

static BOOL lock_save(NSDictionary *dict) {
    NSString *dir = [g_lockPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [dict writeToFile:g_lockPath atomically:YES];
}

// 弹自定义屏蔽提示页（SpringBoard 进程内，UIAlertController）
// 当前屏蔽页 window 引用（保持存活；点按钮移除）
static UIWindow *g_lockWin = nil;

static void lock_dismiss_alert(void) {
    if (g_lockWin) {
        [g_lockWin setHidden:YES];
        g_lockWin = nil;
    }
}

// 弹自定义全屏屏蔽页（独立 UIWindow，不依赖 SpringBoard window 的 rootViewController）
static void lock_show_alert(NSString *bid, NSDictionary *cfg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            NSString *title = cfg[@"title"] ?: @"休息一下";
            NSString *subtitle = cfg[@"subtitle"] ?: [NSString stringWithFormat:@"%@ 已被 Operit 锁定", bid];
            NSString *btn = cfg[@"button"] ?: @"好的";
            // 已有屏蔽页则先移除（避免堆叠）
            if (g_lockWin) { [g_lockWin setHidden:YES]; g_lockWin = nil; }
            UIWindow *win = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            UIScene *scene = [UIApplication sharedApplication].connectedScenes.allObjects.firstObject;
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                win.windowScene = (UIWindowScene *)scene;
            }
            win.windowLevel = 2100; // statusBar(1000)/alert(2000) 之上
            win.backgroundColor = [UIColor systemBackgroundColor];
            UIView *v = [[UIView alloc] initWithFrame:win.bounds];
            v.backgroundColor = [UIColor systemBackgroundColor];
            // 图标占位（圆形渐变色块）
            UIView *icon = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 88, 88)];
            icon.center = CGPointMake(win.bounds.size.width / 2, win.bounds.size.height * 0.30);
            icon.backgroundColor = [UIColor systemIndigoColor];
            icon.layer.cornerRadius = 24;
            [v addSubview:icon];
            // 主标题
            UILabel *titleL = [[UILabel alloc] initWithFrame:CGRectMake(32, icon.frame.origin.y + 120, win.bounds.size.width - 64, 34)];
            titleL.text = title;
            titleL.font = [UIFont systemFontOfSize:26 weight:UIFontWeightSemibold];
            titleL.textAlignment = NSTextAlignmentCenter;
            [v addSubview:titleL];
            // 副标题
            UILabel *subL = [[UILabel alloc] initWithFrame:CGRectMake(40, titleL.frame.origin.y + 44, win.bounds.size.width - 80, 60)];
            subL.text = subtitle;
            subL.font = [UIFont systemFontOfSize:15];
            subL.textColor = [UIColor secondaryLabelColor];
            subL.textAlignment = NSTextAlignmentCenter;
            subL.numberOfLines = 0;
            [v addSubview:subL];
            // 按钮
            UIButton *btnB = [UIButton buttonWithType:UIButtonTypeSystem];
            btnB.frame = CGRectMake(win.bounds.size.width / 2 - 80, win.bounds.size.height - 160, 160, 48);
            [btnB setTitle:btn forState:UIControlStateNormal];
            btnB.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
            btnB.backgroundColor = [UIColor systemIndigoColor];
            btnB.layer.cornerRadius = 24;
            [btnB setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            [btnB addAction:[UIAction actionWithHandler:^(UIAction *action) {
                lock_dismiss_alert();
            }] forControlEvents:UIControlEventTouchUpInside];
            [v addSubview:btnB];
            [win addSubview:v];
            g_lockWin = win;
            [win makeKeyAndVisible];
            oc_log("ALERT: fullscreen shown for %s", bid.UTF8String);
        } @catch (NSException *ex) {
            oc_log("lock_show_alert threw: %s", ex.reason.UTF8String ?: "");
        }
    });
}

// 从 FrontBoard 启动参数提取 bundle id（FBApplicationProcess 对象或 NSString）
static NSString *lock_bid_from_arg(id app) {
    if (!app) return nil;
    if ([app isKindOfClass:[NSString class]]) return app;
    @try {
        NSString *bid = [app valueForKey:@"bundleIdentifier"];
        return bid;
    } @catch (NSException *ex) {
        return nil;
    }
}

// 从 SBIconView 的 icon（SBApplicationIcon）安全取 bundle id。
// SBApplicationIcon 没有 applicationBundleIdentifier 这个 KVC 键（真机报
// valueForUndefinedKey），正确路径是 application.bundleIdentifier；兜底直接
// bundleIdentifier。fail-safe：取不到返回 nil。
static NSString *sbicon_bundle_id(id icon) {
    if (!icon) return nil;
    @try {
        id app = [icon valueForKey:@"application"];
        if (app) {
            NSString *b = [app valueForKey:@"bundleIdentifier"];
            if (b && b.length) return b;
        }
    } @catch (NSException *ex) {}
    @try {
        NSString *b = [icon valueForKey:@"bundleIdentifier"];
        if (b && b.length) return b;
    } @catch (NSException *ex) {}
    return nil;
}

// ---- 历史通知清除（前向声明，实现在 BBObserver 段）----
static BOOL notif_clear_section(NSString *bid);
// ---- 锁相关前向声明（实现在后文）----
static void lock_show_alert(NSString *bid, NSDictionary *cfg);
static void lock_kill_app(NSString *bid);

// ---- 事件驱动前台检测（SBSceneManager hook）已移除 ----
// 曾 hook SBSceneManager -sceneManager:interceptUpdateForScene:withNewSettings: 做事件驱动
// 拦截（多任务切回）。真机实测：hook 后点搜索框触发 scene 更新 → SpringBoard crash → Safe
// Mode（真实签名与猜测不匹配，%orig 调用栈损坏）。已移除。多任务切回由 150ms 轮询兜底
//（已修复系统 UI scene 抢占问题，轮询能正确检测到前台 app）。

// ---- 启动拦截：SBMainWorkspace hook 已移除 ----
// 曾 hook _validateRequestToOpenApplication / createRequestForApplicationActivation /
// canExecuteTransitionRequest / executeTransitionRequest 做统一启动拦截（通知点击/URL
// Scheme/深链/Spotlight）。真机实测：hook 后所有 app 通过这些路径全部打不开（日志无
// LAUNCH: 记录 → 不是"命中才拦"而是 hook 本身破坏了 SpringBoard 行为，最可能该方法是
// 非 BOOL 返回，%orig 返回值被错误解释）。已整体移除，拦截靠手势 hook（主屏点击）+
// EVTLOCK（SBSceneManager 事件，多任务切回）+ 轮询兜底（已在运行 app 切前台）三层。

// 统一拦截判定：命中锁名单 → 阻断 + 弹提示 + 返回 YES（已拦截）；否则 NO（放行）。
// fail-open：任何异常都视为"未命中"，保证拦截逻辑出问题只会放行、绝不进安全模式。
static BOOL lock_try_block(NSString *bid) {
    @try {
        if (!bid || bid.length == 0) return NO;
        NSDictionary *cfg = lock_cfg_for(bid);
        if (!cfg) return NO;
        oc_log("LOCK: blocking launch of %s", bid.UTF8String);
        lock_show_alert(bid, cfg);
        // 锁定触发时清掉该 app 通知中心已有通知（官方同款：锁了全消失）
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            notif_clear_section(bid);
        });
        return YES;
    } @catch (NSException *ex) {
        oc_log("lock_try_block threw (fail-open): %s", ex.reason.UTF8String ?: "");
        return NO;
    }
}

// ---- commands ----

static NSString *cmd_launch(NSString *bid) {
    if (!bid || bid.length == 0) return @"ERR|launch: empty bundleId";

    // 锁名单拦截：AI 主动启动被锁 app 与用户点图标一致对待。
    if (lock_try_block(bid)) return [NSString stringWithFormat:@"ERR|launch %@ 已被锁定", bid];

    BOOL launched = NO;

    // 1) FBSystemService.openApplication:withOptions:completion:
    //    FrontBoard 系统服务，从 SpringBoard 进程内调用是 iOS 13+ 最可靠的启动方式。
    //    弃用 LSApplicationWorkspace.openApplicationWithBundleID:：iOS 15.7 上静默失效
    //    （不抛异常、返回 void，但 App 根本没起来），导致"命令成功、屏幕不变"。
    Class fbSys = objc_getClass("FBSystemService");
    if (fbSys && [fbSys respondsToSelector:@selector(sharedInstance)]) {
        id svc = [fbSys performSelector:@selector(sharedInstance)];
        SEL open = sel_registerName("openApplication:withOptions:completion:");
        if (svc && [svc respondsToSelector:open]) {
            NSMethodSignature *sig = [svc methodSignatureForSelector:open];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:svc]; [inv setSelector:open];
                [inv setArgument:&bid atIndex:2];
                NSDictionary *opts = @{};
                [inv setArgument:&opts atIndex:3];
                void (^comp)(BOOL, NSError *) = ^(BOOL ok, NSError *e){ (void)ok; (void)e; };
                [inv setArgument:&comp atIndex:4];
                @try { [inv invoke]; launched = YES; }
                @catch (NSException *ex) { oc_log("launch: FBSystemService threw %s", ex.reason.UTF8String ?: ""); launched = NO; }
            }
        }
    }

    // 2) 回退 SpringBoardServices（老设备 / 上述符号缺失时）
    if (!launched) {
        void *ss = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        void *p = ss ? dlsym(ss, "SBSLaunchApplicationWithIdentifier") : NULL;
        if (p) {
            BOOL (*fn)(CFStringRef, BOOL) = (void *)p;
            @try { fn((__bridge CFStringRef)bid, NO); launched = YES; }
            @catch (NSException *ex) { oc_log("launch: SBSLaunch threw %s", ex.reason.UTF8String ?: ""); launched = NO; }
        }
        if (ss) dlclose(ss);
    }

    if (!launched) return @"ERR|launch: 没有可用方法启动该 App";

    // 3) 验证前台是否真的切换（iOS 启动有延迟，等 0.7s 再查）
    usleep(700000);
    Class wsCls = objc_getClass("SBWorkspace") ?: objc_getClass("FBWorkspace");
    id ws = nil;
    if (wsCls) {
        if ([wsCls respondsToSelector:@selector(sharedInstance)])
            ws = [wsCls performSelector:@selector(sharedInstance)];
        else if ([wsCls respondsToSelector:@selector(mainWorkspace)])
            ws = [wsCls performSelector:@selector(mainWorkspace)];
    }
    id front = ws ? [ws performSelector:@selector(frontmostApplication)] : nil;
    NSString *frontBid = [front valueForKey:@"bundleIdentifier"];
    if (frontBid && [frontBid isEqualToString:bid])
        return [NSString stringWithFormat:@"OK|launched %@", bid];
    return [NSString stringWithFormat:@"ERR|launch %@ 失败：前台仍是 %@", bid, frontBid ?: @"?"];
}

static NSString *cmd_home(void) {
    @try {
        Class wsCls = objc_getClass("SBWorkspace") ?: objc_getClass("FBWorkspace");
        if (!wsCls) return @"ERR|no workspace class";
        id ws = [wsCls respondsToSelector:@selector(sharedInstance)]
                    ? [wsCls performSelector:@selector(sharedInstance)]
                    : ([wsCls respondsToSelector:@selector(mainWorkspace)]
                           ? [wsCls performSelector:@selector(mainWorkspace)] : nil);
        if (!ws) return @"ERR|no workspace";
        id app = [ws respondsToSelector:@selector(frontmostApplication)]
                     ? [ws performSelector:@selector(frontmostApplication)] : nil;
        NSString *bid = [app valueForKey:@"bundleIdentifier"];
        if (!bid) return @"ERR|no frontmost bundle";
        if ([ws respondsToSelector:@selector(closeApplicationWithBundleIdentifier:)]) {
            [ws performSelector:@selector(closeApplicationWithBundleIdentifier:) withObject:bid];
        } else if ([ws respondsToSelector:@selector(requestExitFromAppWithBundleID:)]) {
            [ws performSelector:@selector(requestExitFromAppWithBundleID:) withObject:bid];
        } else {
            return @"ERR|no close method";
        }
        return [NSString stringWithFormat:@"OK|home (%@)", bid];
    } @catch (NSException *ex) {
        return [NSString stringWithFormat:@"ERR|home: %@", ex.reason];
    }
}

// ---- screenshot（option B 基础设施，多级回退链）----
// 跨进程读屏兜底：读像素，不依赖任何 AX 符号，免疫微信反注入/SwiftUI 渲染。
// 多级回退（任一拿到 PNG 立即返回）：
//   0) _UICreateScreenUIImage        (UIKit，最简单，iOS 各版本通用) —— 本项目的全新赌注
//   1) CARenderServerGetDisplayIOSurface (主线程)
//   2) IOMobileFramebuffer           (主线程)
//   3) CAWindowServer -> display     (主线程)
//   4) CADisplay.mainDisplay.screenSurface (主线程)
//   5) SBScreenshotManager           (capture/save with completion，主线程触发)
//   6) 系统截图存相册 -> 轮询 DCIM 最新图 (主线程触发, 后台轮询) —— 核弹级兜底
// 所有私有符号均 dlsym 解析 + @try/@catch，单级失败不影响下一级，绝不崩 SpringBoard。
// 整条链在后台 socket 线程跑；需要主线程的 tier 自行 dispatch_sync(main)，DCIM 轮询留后台不堵主线程。

typedef struct __IOSurface *IOSurfaceRef;
typedef struct __IOMobileFramebuffer *IOMobileFBConnection;

// IOSurfaceRef -> PNG（双保险：UIImage imageWithIOSurface: 失败回退 CIImage）
static NSData *png_from_iosurface(IOSurfaceRef surf) {
    if (!surf) return nil;
    Class uiimg = objc_getClass("UIImage");
    if (!uiimg) return nil;
    id image = nil;
    SEL imgSurf = sel_registerName("imageWithIOSurface:");
    if ([uiimg respondsToSelector:imgSurf]) {
        @try { image = [uiimg performSelector:imgSurf withObject:(__bridge id)surf]; }
        @catch (NSException *e) { (void)e; image = nil; }
    }
    if (!image) {
        Class ciimg = objc_getClass("CIImage");
        SEL ciSurf = sel_registerName("imageWithIOSurface:");
        if (ciimg && [ciimg respondsToSelector:ciSurf]) {
            @try {
                id ci = [ciimg performSelector:ciSurf withObject:(__bridge id)surf];
                if (ci && [uiimg respondsToSelector:sel_registerName("imageWithCIImage:")])
                    image = [uiimg performSelector:sel_registerName("imageWithCIImage:") withObject:ci];
            } @catch (NSException *e) { (void)e; }
        }
    }
    if (!image) return nil;
    return UIImagePNGRepresentation(image);
}

// 0) _UICreateScreenUIImage（主线程，UIKit 最简洁路径）
static NSData *shot_uicreate(void) {
    static void *(*createScreen)(void) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        createScreen = dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
        if (!createScreen) {
            void *uikit = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_LAZY | RTLD_LOCAL);
            if (uikit) createScreen = dlsym(uikit, "_UICreateScreenUIImage");
        }
        oc_log("screenshot[0]: _UICreateScreenUIImage=%p", createScreen);
    });
    if (!createScreen) return nil;
    __block NSData *png = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            UIImage *img = (__bridge_transfer UIImage *)createScreen();
            if (img) png = UIImagePNGRepresentation(img);
        } @catch (NSException *e) { oc_log("screenshot[0]: %s", e.reason.UTF8String ?: ""); }
    });
    return png;
}

// 1) CARenderServerGetDisplayIOSurface（必须在主线程；否则 iOS 15.7 返回 nil）
static NSData *shot_carenderserver(void) {
    void *ca = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
    if (!ca) return nil;
    void *sym = dlsym(ca, "CARenderServerGetDisplayIOSurface");
    if (!sym) { dlclose(ca); return nil; }
    IOSurfaceRef (*getSurf)(uint32_t, uint32_t *) = (void *)sym;
    __block NSData *png = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        uint32_t seed = 0;
        IOSurfaceRef surf = NULL;
        @try { surf = getSurf(0, &seed); } @catch (NSException *e) { (void)e; surf = NULL; }
        if (surf) { oc_log("screenshot[1]: CARenderServer surface seed=%u", seed); png = png_from_iosurface(surf); }
        else oc_log("screenshot[1]: CARenderServer returned nil");
    });
    dlclose(ca);
    return png;
}

// 2) IOMobileFramebuffer（主线程；iOS 15.7 可能 kIOReturnNotPrivileged）
static NSData *shot_iomfb(void) {
    void *iof = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_LAZY);
    if (!iof) return nil;
    int (*getMain)(IOMobileFBConnection *) = (void *)dlsym(iof, "IOMobileFramebufferGetMainDisplay");
    int (*getLayer)(IOMobileFBConnection, int, IOSurfaceRef *) = (void *)dlsym(iof, "IOMobileFramebufferGetLayerDefaultSurface");
    if (!getMain || !getLayer) { dlclose(iof); return nil; }
    __block NSData *png = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        IOMobileFBConnection conn = NULL;
        int kr = getMain(&conn);
        if (kr != 0 || !conn) { oc_log("screenshot[2]: IOMobileFramebuffer GetMainDisplay failed kr=%d", (int)kr); return; }
        IOSurfaceRef surf = NULL;
        kr = getLayer(conn, 0, &surf);
        if (kr != 0 || !surf) { oc_log("screenshot[2]: IOMobileFramebuffer GetLayerDefaultSurface failed kr=%d", (int)kr); return; }
        oc_log("screenshot[2]: IOMobileFramebuffer surface ok");
        png = png_from_iosurface(surf);
    });
    dlclose(iof);
    return png;
}

// 3) CAWindowServer -> display -> surface（主线程）
static NSData *shot_cawindowserver(void) {
    Class svCls = objc_getClass("CAWindowServer");
    if (!svCls) return nil;
    SEL serverSel = sel_registerName("serverIfRunning");
    if (![svCls respondsToSelector:serverSel]) serverSel = sel_registerName("server");
    if (![svCls respondsToSelector:serverSel]) return nil;
    __block NSData *png = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        id server = nil;
        @try { server = [svCls performSelector:serverSel]; } @catch (NSException *e) { (void)e; }
        if (!server) return;
        NSArray *displays = nil;
        if ([server respondsToSelector:sel_registerName("displays")]) {
            @try { displays = [server performSelector:sel_registerName("displays")]; } @catch (NSException *e) { (void)e; }
        }
        if (!displays || [displays count] == 0) return;
        id display = displays[0];
        id surf = nil;
        if ([display respondsToSelector:sel_registerName("surface")]) {
            @try { surf = [display performSelector:sel_registerName("surface")]; } @catch (NSException *e) { (void)e; }
        }
        if (!surf) {
            const char *cands[] = {"screenSurface","_surface","displaySurface","snapshot","_snapshot","renderSurface","_renderSurface",NULL};
            for (int i = 0; cands[i] && !surf; i++) {
                SEL s = sel_registerName(cands[i]);
                if ([display respondsToSelector:s]) @try { surf = [display performSelector:s]; } @catch (NSException *e) { (void)e; }
            }
        }
        if (surf) { oc_log("screenshot[3]: CAWindowServer surface ok"); png = png_from_iosurface((IOSurfaceRef)(__bridge void *)surf); }
    });
    return png;
}

// 4) CADisplay.mainDisplay.screenSurface（主线程；iOS 15.7 该 selector 可能已更名/移除）
static NSData *shot_cadisplay(void) {
    Class dispCls = objc_getClass("CADisplay");
    if (!dispCls) return nil;
    if (![dispCls respondsToSelector:sel_registerName("mainDisplay")]) return nil;
    __block NSData *png = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        id display = nil;
        @try { display = [dispCls performSelector:sel_registerName("mainDisplay")]; } @catch (NSException *e) { (void)e; }
        if (!display) return;
        id surf = nil;
        if ([display respondsToSelector:sel_registerName("screenSurface")]) {
            @try { surf = [display performSelector:sel_registerName("screenSurface")]; } @catch (NSException *e) { (void)e; }
        }
        if (!surf) {
            const char *cands[] = {"surface","_surface","_screenSurface","displaySurface","_displaySurface","renderSurface","_renderSurface",NULL};
            for (int i = 0; cands[i] && !surf; i++) {
                SEL s = sel_registerName(cands[i]);
                if ([display respondsToSelector:s]) @try { surf = [display performSelector:s]; } @catch (NSException *e) { (void)e; }
            }
        }
        if (surf) { oc_log("screenshot[4]: CADisplay surface ok"); png = png_from_iosurface((IOSurfaceRef)(__bridge void *)surf); }
    });
    return png;
}

// 5) SBScreenshotManager（主线程触发，completion 回 UIImage；后台等信号，绝不死锁主线程）
static NSData *shot_sbscreenshotmgr(void) {
    __block NSData *png = nil;
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        Class sbCls = objc_getClass("SpringBoard");
        id sb = sbCls ? [sbCls performSelector:sel_registerName("sharedApplication")] : nil;
        id mgr = nil;
        if (sb && [sb respondsToSelector:sel_registerName("screenshotManager")]) {
            @try { mgr = [sb performSelector:sel_registerName("screenshotManager")]; } @catch (NSException *e) { (void)e; }
        }
        if (!mgr) {
            Class mgrCls = objc_getClass("SBScreenshotManager");
            if (mgrCls && [mgrCls respondsToSelector:sel_registerName("sharedInstance")])
                @try { mgr = [mgrCls performSelector:sel_registerName("sharedInstance")]; } @catch (NSException *e) { (void)e; }
        }
        if (!mgr) { oc_log("screenshot[5]: SBScreenshotManager unavailable"); dispatch_semaphore_signal(s); return; }
        SEL cap = sel_registerName("captureScreenshotWithCompletion:");
        if ([mgr respondsToSelector:cap]) {
            void (^comp)(id) = ^(id image) { if (image) png = UIImagePNGRepresentation(image); dispatch_semaphore_signal(s); };
            @try { [mgr performSelector:cap withObject:comp]; } @catch (NSException *e) { (void)e; dispatch_semaphore_signal(s); }
            return;
        }
        SEL swc = sel_registerName("saveScreenshot:withCompletion:");
        if ([mgr respondsToSelector:swc]) {
            void (^comp)(id,id) = ^(id image, id err) { (void)err; if (image) png = UIImagePNGRepresentation(image); dispatch_semaphore_signal(s); };
            @try { [mgr performSelector:swc withObject:@NO withObject:comp]; } @catch (NSException *e) { (void)e; dispatch_semaphore_signal(s); }
            return;
        }
        oc_log("screenshot[5]: SBScreenshotManager lacks capture/save completion");
        dispatch_semaphore_signal(s);
    });
    dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    return png;
}

// ---- 6) 系统截图存相册 -> 轮询 DCIM 最新图（核弹级兜底；主线程触发, 后台轮询不堵主线程）----
static long long oc_newest_image_mtime(NSString *dir) {
    long long best = 0;
    NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtPath:dir];
    for (NSString *rel in en) {
        NSString *low = [rel lowercaseString];
        if (!([low hasSuffix:@".png"]||[low hasSuffix:@".jpg"]||[low hasSuffix:@".jpeg"]||[low hasSuffix:@".heic"]||[low hasSuffix:@".tiff"]||[low hasSuffix:@".bmp"])) continue;
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:[dir stringByAppendingPathComponent:rel] error:nil];
        if (!attr) continue;
        long long mt = (long long)[attr[NSFileModificationDate] timeIntervalSince1970];
        if (mt > best) best = mt;
    }
    return best;
}
static NSString *oc_find_newest_image_after(NSString *dir, long long minMtime) {
    long long best = 0; NSString *bestPath = nil;
    NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtPath:dir];
    for (NSString *rel in en) {
        NSString *low = [rel lowercaseString];
        if (!([low hasSuffix:@".png"]||[low hasSuffix:@".jpg"]||[low hasSuffix:@".jpeg"]||[low hasSuffix:@".heic"]||[low hasSuffix:@".tiff"]||[low hasSuffix:@".bmp"])) continue;
        NSString *full = [dir stringByAppendingPathComponent:rel];
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:nil];
        if (!attr) continue;
        long long mt = (long long)[attr[NSFileModificationDate] timeIntervalSince1970];
        if (mt > best) { best = mt; bestPath = full; }
    }
    if (bestPath && best > minMtime) return bestPath;
    return nil;
}
static NSData *shot_photos_dcim(void) {
    NSString *dcim = @"/var/mobile/Media/DCIM";
    if (![[NSFileManager defaultManager] fileExistsAtPath:dcim]) { oc_log("screenshot[6]: DCIM missing"); return nil; }
    long long before = oc_newest_image_mtime(dcim);
    // 触发系统截图（主线程，saveScreenshotsWithCompletion: 仅存相册，不回 UIImage）
    __block BOOL triggered = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        Class sbCls = objc_getClass("SpringBoard");
        id sb = sbCls ? [sbCls performSelector:sel_registerName("sharedApplication")] : nil;
        id mgr = nil;
        if (sb && [sb respondsToSelector:sel_registerName("screenshotManager")]) {
            @try { mgr = [sb performSelector:sel_registerName("screenshotManager")]; } @catch (NSException *e) { (void)e; }
        }
        if (!mgr) {
            Class mgrCls = objc_getClass("SBScreenshotManager");
            if (mgrCls && [mgrCls respondsToSelector:sel_registerName("sharedInstance")])
                @try { mgr = [mgrCls performSelector:sel_registerName("sharedInstance")]; } @catch (NSException *e) { (void)e; }
        }
        if (!mgr) { oc_log("screenshot[6]: SBScreenshotManager unavailable"); return; }
        SEL sswc = sel_registerName("saveScreenshotsWithCompletion:");
        if (![mgr respondsToSelector:sswc]) { oc_log("screenshot[6]: saveScreenshotsWithCompletion: missing"); return; }
        void (^comp)(BOOL) = ^(BOOL success) { (void)success; };
        @try { [mgr performSelector:sswc withObject:comp]; triggered = YES; } @catch (NSException *e) { oc_log("screenshot[6]: %s", e.reason.UTF8String ?: ""); }
    });
    if (!triggered) { oc_log("screenshot[6]: trigger failed"); return nil; }
    // 后台轮询 DCIM（当前线程，不堵主线程）
    NSString *found = nil;
    for (int i = 0; i < 50; i++) {
        found = oc_find_newest_image_after(dcim, before);
        if (found) break;
        usleep(100000);
    }
    if (!found) found = oc_find_newest_image_after(dcim, 0);
    if (!found) { oc_log("screenshot[6]: no image in DCIM"); return nil; }
    NSData *data = nil;
    Class uiimg = objc_getClass("UIImage");
    if (uiimg && [uiimg respondsToSelector:sel_registerName("imageWithContentsOfFile:")]) {
        id img = [uiimg performSelector:sel_registerName("imageWithContentsOfFile:") withObject:found];
        if (img && [uiimg respondsToSelector:sel_registerName("UIImagePNGRepresentation")])
            data = [uiimg performSelector:sel_registerName("UIImagePNGRepresentation") withObject:img];
    }
    if (!data || [data length] == 0) data = [NSData dataWithContentsOfFile:found];
    oc_log("screenshot[6]: DCIM image %s (%llu bytes)", [found UTF8String], (unsigned long long)[data length]);
    return data;
}

// 多级回退入口：任一 tier 拿到 PNG 立即返回
static NSData *capture_screen_png(void) {
    NSData *(*tiers[])(void) = { shot_uicreate, shot_carenderserver, shot_iomfb,
                                 shot_cawindowserver, shot_cadisplay, shot_sbscreenshotmgr, shot_photos_dcim };
    const char *names[] = {"_UICreateScreenUIImage","CARenderServer","IOMobileFramebuffer",
                           "CAWindowServer","CADisplay","SBScreenshotManager","Photos/DCIM"};
    for (int i = 0; i < 7; i++) {
        @try {
            NSData *png = tiers[i]();
            if (png && [png length] > 0) { oc_log("screenshot: OK via tier %d (%s), %lu bytes", i, names[i], (unsigned long)[png length]); return png; }
            oc_log("screenshot: tier %d (%s) returned nil", i, names[i]);
        } @catch (NSException *e) { oc_log("screenshot: tier %d (%s) threw: %s", i, names[i], e.reason.UTF8String ?: ""); }
    }
    oc_log("screenshot: ALL tiers failed");
    return nil;
}

static NSString *cmd_screenshot(void) {
    // 整条链在后台 socket 线程跑；需主线程的 tier 内部自行 dispatch_sync(main)，DCIM 轮询留后台。
    NSData *png = nil;
    @try { png = capture_screen_png(); }
    @catch (NSException *ex) { oc_log("screenshot: %s", ex.reason.UTF8String ?: ""); }
    if (!png || [png length] == 0) return @"ERR|screenshot: all tiers failed (see tweak.log)";
    NSString *path = @"/var/mobile/.operit/screen.png";
    if (![png writeToFile:path atomically:NO]) return @"ERR|screenshot: write failed";
    return [NSString stringWithFormat:@"OK|screenshot %lu bytes -> %@", (unsigned long)[png length], path];
}

// ---- tap / 触摸注入（IOKit HID, iOS 15, SimulateTouch 风格）----
// 用 IOHIDEvent 直接构造 digitizer 触摸事件派发到系统，不依赖任何 App、不触发反注入。
// 坐标用主屏归一化坐标 (0..1)；act_tap 把绝对 point 坐标按 mainScreen.bounds 归一化。
// 全部私有符号 dlsym 解析 + @try/@catch，符号缺失只返回 ERR，绝不崩 SpringBoard。
typedef uint64_t AbsTime;
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

typedef IOHIDEventRef (*F_digEvent)(CFAllocatorRef, AbsTime, int, uint32_t, uint32_t,
                                    uint32_t, uint32_t, float, float, float, float, float,
                                    unsigned char, unsigned char, uint32_t);
typedef IOHIDEventRef (*F_fingerEvent)(CFAllocatorRef, AbsTime, uint32_t, uint32_t, uint32_t,
                                       float, float, float, float, float,
                                       unsigned char, unsigned char, uint32_t);
typedef IOHIDEventRef (*F_fingerEventQ)(CFAllocatorRef, AbsTime, uint32_t, uint32_t, uint32_t,
                                        float, float, float, float, float, float, float, float,
                                        unsigned char, unsigned char, uint32_t);
typedef IOHIDEventSystemClientRef (*F_evSysClientCreate)(CFAllocatorRef);
typedef void (*F_evSysClientDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef void (*F_evAppend)(IOHIDEventRef, IOHIDEventRef);
typedef void (*F_evSetSender)(IOHIDEventRef, uint64_t);
typedef void (*F_evSetIntOpt)(IOHIDEventRef, int, int, int);

static void *g_ioh = NULL;
static void *ioh_sym(const char *name) {
    if (!g_ioh) g_ioh = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    return g_ioh ? dlsym(g_ioh, name) : NULL;
}

static IOHIDEventSystemClientRef g_hid_client = NULL;
static void send_hid_event(IOHIDEventRef event) {
    if (!event) return;
    F_evSysClientCreate create = (F_evSysClientCreate)ioh_sym("IOHIDEventSystemClientCreate");
    F_evSysClientDispatch dispatch = (F_evSysClientDispatch)ioh_sym("IOHIDEventSystemClientDispatchEvent");
    if (!create || !dispatch) { CFRelease(event); return; }
    if (!g_hid_client) g_hid_client = create(kCFAllocatorDefault);
    if (!g_hid_client) { CFRelease(event); return; }
    dispatch(g_hid_client, event);
    CFRelease(event);
}

#define HID_TRANS_HAND 3
#define F_DIG_EVENTMASK 0x27
#define F_DIG_RANGE     0x28
#define F_DIG_TOUCH     0x29
#define DIG_RANGE  0x01
#define DIG_TOUCH  0x02
#define DIG_POS    0x04
#define DIG_IDENT  0x20
#define SENDER_HID 0xDEFACEDBEEFFECE5

static void wake_user_event(void) {
    Class cls = objc_getClass("BKUserEventTimer");
    if (!cls) return;
    id et = [cls performSelector:sel_registerName("sharedInstance")];
    if (!et) return;
    SEL s1 = sel_registerName("userEventOccurred");
    SEL s2 = sel_registerName("userEventOccurredOnDisplay:");
    @try {
        if ([et respondsToSelector:s1]) [et performSelector:s1];
        else if ([et respondsToSelector:s2]) [et performSelector:s2 withObject:nil];
    } @catch (NSException *e) { (void)e; }
}

// touch=1 按下, touch=0 抬起；nx/ny 为归一化 (0..1) 主屏坐标
static BOOL inject_finger(float nx, float ny, int touch, int identity) {
    F_digEvent createHand = (F_digEvent)ioh_sym("IOHIDEventCreateDigitizerEvent");
    F_fingerEvent createFinger = (F_fingerEvent)ioh_sym("IOHIDEventCreateDigitizerFingerEvent");
    F_fingerEventQ createFingerQ = (F_fingerEventQ)ioh_sym("IOHIDEventCreateDigitizerFingerEventWithQuality");
    F_evAppend append = (F_evAppend)ioh_sym("IOHIDEventAppendEvent");
    F_evSetSender setSender = (F_evSetSender)ioh_sym("IOHIDEventSetSenderID");
    F_evSetIntOpt setInt = (F_evSetIntOpt)ioh_sym("IOHIDEventSetIntegerValueWithOptions");
    if (!createHand || !append || !setSender || !setInt) return NO;
    if (!createFinger && !createFingerQ) return NO;

    uint64_t ab = mach_absolute_time();
    AbsTime ts = ab;
    int eventMask = DIG_RANGE | DIG_TOUCH | DIG_POS | DIG_IDENT;
    IOHIDEventRef hand = createHand(kCFAllocatorDefault, ts, HID_TRANS_HAND, 0, 1, 0, 0,
                                    0, 0, 0, 0, 0, 0, 0, 0);
    if (!hand) return NO;
    setSender(hand, SENDER_HID);

    IOHIDEventRef finger = NULL;
    if (createFinger) {
        finger = createFinger(kCFAllocatorDefault, ts, 1, 2, eventMask,
                      nx, ny, 0, 0, 0, (unsigned char)touch, (unsigned char)identity, 0);
    } else {
        finger = createFingerQ(kCFAllocatorDefault, ts, 1, 2, eventMask,
                       nx, ny, 0, 0, 0, 0, 0, 0, 0,
                       (unsigned char)touch, (unsigned char)identity);
    }
    if (!finger) { CFRelease(hand); return NO; }
    append(hand, finger);
    CFRelease(finger);

    setInt(hand, F_DIG_EVENTMASK, eventMask, (int)0xF0000000);
    setInt(hand, F_DIG_RANGE, touch, (int)0xF0000000);
    setInt(hand, F_DIG_TOUCH, touch, (int)0xF0000000);

    wake_user_event();
    send_hid_event(hand);
    return YES;
}

// 归一化 (0..1) 主屏坐标（由调用方把模型 0–999 换算好）→ 直接注入按下+抬起（间隔 40ms）。
// 不再在此做 UIScreen 归一化：调用方（App / 守护进程）统一传 0..1，避免像素/点混用导致坐标错位。
// fuzzing：±0.002 归一化抖动（约 ±2px），对齐官方 InputController 的点击抖动，提升命中率。
static NSString *act_tap(double nx, double ny) {
    double jx = ((double)arc4random_uniform(5) - 2.0) / 1000.0;
    double jy = ((double)arc4random_uniform(5) - 2.0) / 1000.0;
    nx = nx + jx; ny = ny + jy;
    if (nx < 0.0) nx = 0.0; if (nx > 1.0) nx = 1.0;
    if (ny < 0.0) ny = 0.0; if (ny > 1.0) ny = 1.0;
    if (!inject_finger((float)nx, (float)ny, 1, 1)) return nil;
    usleep(40000);
    if (!inject_finger((float)nx, (float)ny, 0, 1)) return nil;
    return [NSString stringWithFormat:@"tapped (%.3f,%.3f)", nx, ny];
}

// tap 命令：归一化 (0..1) 主屏坐标。UIKit 调用放主线程执行。
static NSString *cmd_tap(double nx, double ny) {
    __block NSString *r = @"ERR|tap";
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            NSString *res = act_tap(nx, ny);
            r = res ? [@"OK|" stringByAppendingString:res] : @"ERR|tap: injection failed (verify IOHID symbols on iOS 15.7)";
        } @catch (NSException *ex) { r = [NSString stringWithFormat:@"ERR|tap: %@", ex.reason]; }
    });
    return r;
}

// 归一化 (0..1) 主屏坐标，dur_ms 为滑动时长（毫秒）。复用 inject_finger：down=1 / move=2 / up=0
static NSString *act_swipe(double nx1, double ny1, double nx2, double ny2, double dur_ms) {
    if (nx1 < 0 || nx1 > 1 || ny1 < 0 || ny1 > 1 ||
        nx2 < 0 || nx2 > 1 || ny2 < 0 || ny2 > 1) return nil;
    if (!inject_finger(nx1, ny1, 1, 1)) return nil;            // down
    int steps = (int)(dur_ms / 16.0); if (steps < 2) steps = 2;
    useconds_t per = (useconds_t)(dur_ms * 1000.0 / (double)steps);
    // smoothstep 缓动（对齐官方 InputController 的多段插值），让滑动更自然、更稳。
    for (int i = 1; i <= steps; i++) {
        float t = (float)i / (float)steps;
        float e = t * t * (3.0f - 2.0f * t);
        float nx = nx1 + (nx2 - nx1) * e;
        float ny = ny1 + (ny2 - ny1) * e;
        usleep(per);
        if (!inject_finger(nx, ny, 2, 1)) return nil;          // move
    }
    if (!inject_finger(nx2, ny2, 0, 1)) return nil;            // up
    return [NSString stringWithFormat:@"swiped (%.3f,%.3f)->(%.3f,%.3f)", nx1, ny1, nx2, ny2];
}

// swipe 命令：归一化 (0..1) 主屏坐标，dur_ms 毫秒。UIKit 调用放主线程。
static NSString *cmd_swipe(double nx1, double ny1, double nx2, double ny2, double dur_ms) {
    __block NSString *r = @"ERR|swipe";
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            NSString *res = act_swipe(nx1, ny1, nx2, ny2, dur_ms);
            r = res ? [@"OK|" stringByAppendingString:res] : @"ERR|swipe: injection failed (verify IOHID symbols on iOS 15.7)";
        } @catch (NSException *ex) { r = [NSString stringWithFormat:@"ERR|swipe: %@", ex.reason]; }
    });
    return r;
}

// 长按：归一化 (0..1) 主屏坐标，按住 ~800ms 后抬起。复用 inject_finger。
static NSString *act_longpress(double nx, double ny) {
    if (nx < 0 || nx > 1 || ny < 0 || ny > 1) return nil;
    if (!inject_finger((float)nx, (float)ny, 1, 1)) return nil;   // down
    usleep(800000);                                  // hold 800ms
    if (!inject_finger((float)nx, (float)ny, 0, 1)) return nil;   // up
    return [NSString stringWithFormat:@"longpressed (%.3f,%.3f)", nx, ny];
}

static NSString *cmd_longpress(double nx, double ny) {
    __block NSString *r = @"ERR|longpress";
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            NSString *res = act_longpress(nx, ny);
            r = res ? [@"OK|" stringByAppendingString:res] : @"ERR|longpress: injection failed";
        } @catch (NSException *ex) { r = [NSString stringWithFormat:@"ERR|longpress: %@", ex.reason]; }
    });
    return r;
}

// type 命令：把文本灌进前台 App 当前聚焦的输入框（跨进程）。
// SpringBoard 读 front.pid -> 连前台 app 的 per-pid socket -> 转给 operit-app 注入。
static NSString *cmd_type(NSString *text) {
    if (!text || text.length == 0) return @"ERR|type: empty";
    NSString *pidPath = @"/var/mobile/.operit/front.pid";
    NSString *pidStr = [NSString stringWithContentsOfFile:pidPath
                                                  encoding:NSUTF8StringEncoding error:nil];
    pidStr = [pidStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!pidStr || pidStr.length == 0) return @"ERR|type: no foreground app (front.pid empty)";
    NSString *sock = [NSString stringWithFormat:@"%@/app.%@.sock", @"/var/mobile/.operit", pidStr];
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return @"ERR|type: socket";
    struct sockaddr_un a; memset(&a, 0, sizeof(a)); a.sun_family = AF_UNIX;
    strncpy(a.sun_path, [sock UTF8String], sizeof(a.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) { close(fd); return @"ERR|type: connect app socket"; }
    NSString *req = [NSString stringWithFormat:@"type %@\n", text];
    const char *rb = [req UTF8String];
    send(fd, rb, (size_t)strlen(rb), 0);
    char buf[8192]; ssize_t n = 0, total = 0;
    while ((n = recv(fd, buf + total, sizeof(buf) - total - 1, 0)) > 0) {
        total += n; if (total >= (ssize_t)sizeof(buf) - 1) break;
    }
    close(fd);
    if (total > 0) { buf[total] = 0; return [NSString stringWithUTF8String:buf]; }
    return @"ERR|type: no response";
}

// ---- 前台 App 查询（A 路：让 agent 知道当前在哪个 App，避免把 Operit 当微信）----
static NSString *cmd_front(void) {
    __block NSString *r = @"ERR|front";
    @try {
        dispatch_sync(dispatch_get_main_queue(), ^{
            @try {
                Class wsCls = objc_getClass("SBWorkspace") ?: objc_getClass("FBWorkspace");
                id ws = nil;
                if (wsCls) {
                    if ([wsCls respondsToSelector:@selector(sharedInstance)])
                        ws = [wsCls performSelector:@selector(sharedInstance)];
                    else if ([wsCls respondsToSelector:@selector(mainWorkspace)])
                        ws = [wsCls performSelector:@selector(mainWorkspace)];
                }
                id front = ws ? [ws performSelector:@selector(frontmostApplication)] : nil;
                if (!front) { r = @"ERR|front: 无前台 App"; return; }
                NSString *bid = [front valueForKey:@"bundleIdentifier"];
                NSString *name = [front valueForKey:@"displayName"];
                if (!name || name.length == 0) name = bid;
                if (!bid) { r = @"ERR|front: 无 bundleId"; return; }
                r = [NSString stringWithFormat:@"OK|front %@|%@", bid, name ?: bid];
            } @catch (NSException *ex) {
                r = [NSString stringWithFormat:@"ERR|front: %@", ex.reason];
            }
        });
    } @catch (NSException *ex) { r = [NSString stringWithFormat:@"ERR|front: %@", ex.reason]; }
    return r;
}

// ---- socket server ----
static NSString *g_sockpath = nil;
static int g_listen = -1;

static void ensure_sock_dir(void) {
    NSString *dir = [g_sockpath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                               withIntermediateDirectories:YES attributes:nil error:nil];
}

static void handle_conn(int fd) {
    NSString *resp = @"ERR|unknown";
    NSString *cmd = @"?";
    @try {
        char buf[8192];
        ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
        if (n <= 0) { close(fd); return; }
        buf[n] = 0;
        NSString *line = [[NSString alloc] initWithBytes:buf length:n encoding:NSUTF8StringEncoding];
        line = [line stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        NSArray *parts = [line componentsSeparatedByString:@" "];
        cmd = [[parts.firstObject lowercaseString]
               stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        if ([cmd isEqualToString:@"ping"]) {
            resp = @"OK|pong";
        } else if ([cmd isEqualToString:@"launch"] && parts.count > 1) {
            __block NSString *r = @"ERR|launch";
            @try {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    @try { r = cmd_launch(parts[1]); }
                    @catch (NSException *ex) { r = [NSString stringWithFormat:@"ERR|launch: %@", ex.reason]; }
                });
            } @catch (NSException *ex) { r = [NSString stringWithFormat:@"ERR|launch: %@", ex.reason]; }
            resp = r;
        } else if ([cmd isEqualToString:@"screenshot"]) {
            // cmd_screenshot 在后台 socket 线程跑；需主线程的 tier 内部自行 dispatch_sync(main)。
            // 不要在这里 dispatch_sync(main)，否则会与 tier 0/DCIM 轮询产生死锁或堵住 SpringBoard。
            @try { resp = cmd_screenshot(); }
            @catch (NSException *ex) { resp = [NSString stringWithFormat:@"ERR|screenshot: %@", ex.reason]; }
        } else if ([cmd isEqualToString:@"tap"]) {
            if (parts.count < 3) { resp = @"ERR|usage: tap <x> <y>"; }
            else {
                @try { resp = cmd_tap([parts[1] doubleValue], [parts[2] doubleValue]); }
                @catch (NSException *ex) { resp = [NSString stringWithFormat:@"ERR|tap: %@", ex.reason]; }
            }
        } else if ([cmd isEqualToString:@"swipe"]) {
            if (parts.count < 6) { resp = @"ERR|usage: swipe <x1> <y1> <x2> <y2> <dur_ms>"; }
            else {
                @try {
                    resp = cmd_swipe([parts[1] doubleValue], [parts[2] doubleValue],
                                     [parts[3] doubleValue], [parts[4] doubleValue],
                                     [parts[5] doubleValue]);
                } @catch (NSException *ex) { resp = [NSString stringWithFormat:@"ERR|swipe: %@", ex.reason]; }
            }
        } else if ([cmd isEqualToString:@"longpress"]) {
            if (parts.count < 3) { resp = @"ERR|usage: longpress <x> <y>"; }
            else {
                @try { resp = cmd_longpress([parts[1] doubleValue], [parts[2] doubleValue]); }
                @catch (NSException *ex) { resp = [NSString stringWithFormat:@"ERR|longpress: %@", ex.reason]; }
            }
        } else if ([cmd isEqualToString:@"type"]) {
            if (parts.count < 2) { resp = @"ERR|usage: type <text>"; }
            else {
                NSString *text = [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)]
                                   componentsJoinedByString:@" "];
                @try { resp = cmd_type(text); }
                @catch (NSException *ex) { resp = [NSString stringWithFormat:@"ERR|type: %@", ex.reason]; }
            }
        } else if ([cmd isEqualToString:@"home"]) {
            __block NSString *r = @"ERR|home";
            @try {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    @try { r = cmd_home(); }
                    @catch (NSException *ex) { r = [NSString stringWithFormat:@"ERR|home: %@", ex.reason]; }
                });
            } @catch (NSException *ex) { r = [NSString stringWithFormat:@"ERR|home: %@", ex.reason]; }
            resp = r;
        } else if ([cmd isEqualToString:@"front"]) {
            @try { resp = cmd_front(); }
            @catch (NSException *ex) { resp = [NSString stringWithFormat:@"ERR|front: %@", ex.reason]; }
        } else if ([cmd isEqualToString:@"applock"]) {
            // applock <bundleId>|<title>|<subtitle>|<button>  （title/subtitle/button 可选）
            if (parts.count < 2) { resp = @"ERR|usage: applock <bundleId>|<title>|<subtitle>|<button>"; }
            else {
                NSString *seg = [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)]
                                 componentsJoinedByString:@" "];
                NSArray *fields = [seg componentsSeparatedByString:@"|"];
                if (fields.count < 1 || [fields[0] length] == 0) { resp = @"ERR|applock: empty bundleId"; }
                else {
                    NSString *bid = fields[0];
                    NSMutableDictionary *dict = [lock_load() mutableCopy];
                    NSMutableDictionary *cfg = [NSMutableDictionary dictionary];
                    if (fields.count > 1 && [fields[1] length] > 0) cfg[@"title"] = fields[1];
                    if (fields.count > 2 && [fields[2] length] > 0) cfg[@"subtitle"] = fields[2];
                    if (fields.count > 3 && [fields[3] length] > 0) cfg[@"button"] = fields[3];
                    dict[bid] = cfg;
                    resp = lock_save(dict) ? [NSString stringWithFormat:@"OK|locked %@ (%ld apps)", bid, (long)dict.count]
                                           : @"ERR|applock: 写名单失败";
                }
            }
        } else if ([cmd isEqualToString:@"appunlock"]) {
            if (parts.count < 2) { resp = @"ERR|usage: appunlock <bundleId>"; }
            else {
                NSString *bid = parts[1];
                NSMutableDictionary *dict = [lock_load() mutableCopy];
                if (dict[bid]) {
                    [dict removeObjectForKey:bid];
                    resp = lock_save(dict) ? [NSString stringWithFormat:@"OK|unlocked %@", bid]
                                           : @"ERR|appunlock: 写名单失败";
                } else {
                    resp = [NSString stringWithFormat:@"OK|%@ 不在锁名单", bid];
                }
            }
        } else if ([cmd isEqualToString:@"applock_list"]) {
            NSDictionary *dict = lock_load();
            if (dict.count == 0) { resp = @"OK|empty"; }
            else {
                NSMutableArray *lines = [NSMutableArray array];
                for (NSString *bid in dict) {
                    NSDictionary *cfg = dict[bid];
                    [lines addObject:[NSString stringWithFormat:@"%@|%@|%@|%@", bid,
                                      cfg[@"title"] ?: @"", cfg[@"subtitle"] ?: @"", cfg[@"button"] ?: @""]];
                }
                resp = [NSString stringWithFormat:@"OK|%ld|%@", (long)dict.count,
                        [lines componentsJoinedByString:@"\n"]];
            }
        } else if ([cmd isEqualToString:@"notif_clear"]) {
            // notif_clear <bundleId>：把通知中心里该 app 的已有通知全部清掉（官方锁定时同款）
            if (parts.count < 2) { resp = @"ERR|usage: notif_clear <bundleId>"; }
            else {
                NSString *bid = parts[1];
                if (notif_clear_section(bid)) {
                    resp = [NSString stringWithFormat:@"OK|cleared %@", bid];
                } else {
                    resp = [NSString stringWithFormat:@"ERR|clear %@ failed (no observer?)", bid];
                }
            }
        }
    } @catch (NSException *ex) {
        resp = [NSString stringWithFormat:@"ERR|handle: %@", ex.reason];
    } @finally {
        NSString *logline = [NSString stringWithFormat:@"cmd=%@ -> %s", cmd, [resp UTF8String]];
        oc_log("%s", [logline UTF8String]);
        const char *r = [resp UTF8String];
        if (r) send(fd, r, (size_t)strlen(r), 0);
        close(fd);
    }
}

static void *server_thread(void *unused) {
    (void)unused;
    while (1) {
        int c = accept(g_listen, NULL, NULL);
        if (c < 0) continue;
        handle_conn(c);
    }
    return NULL;
}

static void start_server(void) {
    ensure_sock_dir();
    unlink([g_sockpath UTF8String]);
    g_listen = socket(AF_UNIX, SOCK_STREAM, 0);
    if (g_listen < 0) return;
    struct sockaddr_un a;
    memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, [g_sockpath UTF8String], sizeof(a.sun_path) - 1);
    if (bind(g_listen, (struct sockaddr *)&a, sizeof(a)) < 0) { close(g_listen); g_listen = -1; return; }
    listen(g_listen, 8);
    chmod([g_sockpath UTF8String], 0666);   // 允许 mobile（守护进程 / App）连 root 创建的 socket
    pthread_t t;
    pthread_create(&t, NULL, server_thread, NULL);
}

// ---- app lock：前台监控拦截 ----
// iOS 16.7 实测：用户点图标不走 FrontBoard 三个启动入口（FBSSystemService /
// FBSystemService / FBSOpenApplicationService 均无调用记录）。改为后台线程轮询
// FBSceneManager（必须在 SpringBoard 主线程调用，否则触发 safe mode）。
// 权衡：dispatch_sync(main) 在 app 启动动画期间会等主线程空闲，最大延迟约 1-2s
//（app 启动本身时间 + 主线程繁忙），但稳定可靠。

// 必须在主线程调（FBSceneManager 要求）。拆出纯主线程版，供 timer / socket 两用。
static NSString *lock_front_bid_mainthread(void) {
    NSString *r = nil;
    @try {
        Class mgrCls = objc_getClass("FBSceneManager");
        id mgr = (mgrCls && [mgrCls respondsToSelector:@selector(sharedInstance)])
                     ? [mgrCls performSelector:@selector(sharedInstance)] : nil;
        SEL enumSel = sel_registerName("enumerateScenesWithBlock:");
        if (mgr && [mgr respondsToSelector:enumSel]) {
            NSMutableArray *fgApps = [NSMutableArray new];
            void (^enumBlock)(id, BOOL *) = ^(id scene, BOOL *stop) {
                @try {
                    NSNumber *fg = [scene valueForKeyPath:@"settings.isForeground"];
                    if (![fg boolValue]) return;
                    NSString *bid = [[scene valueForKey:@"identity"] valueForKey:@"identifier"];
                    if ([bid hasPrefix:@"sceneID:"]) bid = [bid substringFromIndex:8];
                    if ([bid hasSuffix:@"-default"]) bid = [bid substringToIndex:bid.length - 8];
                    if (!bid || bid.length == 0) return;
                    // 跳过系统 UI scene（键盘/搜索等），它们会抢占 fg=1 导致枚举提前 stop
                    if ([bid isEqualToString:@"com.apple.springboard"]) return;
                    if ([bid isEqualToString:@"com.apple.UIKit.remote-keyboard"]) return;
                    if ([bid isEqualToString:@"searchScreen"]) return;
                    // 不提前 stop：收集所有前台 app scene，最后取第一个
                    [fgApps addObject:bid];
                } @catch (NSException *ex) {
                    oc_log("lock_front: enum block threw %s", ex.reason.UTF8String ?: "");
                }
            };
            [mgr performSelector:enumSel withObject:enumBlock];
            if (fgApps.count > 0) r = fgApps[0];
        }
    } @catch (NSException *ex) {
        oc_log("lock_front: fbscenemgr threw %s", ex.reason.UTF8String ?: "");
    }
    return r;
}

// 线程安全包装：主线程直接跑（timer 用），非主线程 dispatch_sync（socket 用）。
static NSString *lock_front_bid(void) {
    if ([NSThread isMainThread]) return lock_front_bid_mainthread();
    __block NSString *r = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{ r = lock_front_bid_mainthread(); });
    return r;
}

static void lock_kill_app(NSString *bid) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 1) 从 FBSceneManager 找前台 scene → clientHandle.pid → kill(SIGKILL)
            //    （最直接可靠，不依赖 SBApplicationController/FBSSystemService 的 iOS16 方法）
            Class mgrCls = objc_getClass("FBSceneManager");
            id mgr = (mgrCls && [mgrCls respondsToSelector:@selector(sharedInstance)])
                         ? [mgrCls performSelector:@selector(sharedInstance)] : nil;
            SEL enumSel = sel_registerName("enumerateScenesWithBlock:");
            if (mgr && [mgr respondsToSelector:enumSel]) {
                __block BOOL killed = NO;
                void (^enumBlock)(id, BOOL *) = ^(id scene, BOOL *stop) {
                    @try {
                        NSNumber *fg = [scene valueForKeyPath:@"settings.isForeground"];
                        if (![fg boolValue]) return;
                        NSString *sceneBid = [[scene valueForKey:@"identity"] valueForKey:@"identifier"];
                        if ([sceneBid hasPrefix:@"sceneID:"]) sceneBid = [sceneBid substringFromIndex:8];
                        if ([sceneBid hasSuffix:@"-default"]) sceneBid = [sceneBid substringToIndex:sceneBid.length - 8];
                        if (![sceneBid isEqualToString:bid]) return;
                        // 拿 pid：FBProcessHandle.pid（原始类型，用 NSInvocation 安全读取）
                        pid_t pid = -1;
                        id handle = nil;
                        @try {
                            SEL chSel = sel_registerName("clientHandle");
                            handle = [scene respondsToSelector:chSel] ? [scene performSelector:chSel] : nil;
                        } @catch (NSException *ex) {
                            oc_log("KILL: clientHandle threw %s", ex.reason.UTF8String ?: "");
                        }
                        if (handle) {
                            // 1) 直接 pid（FBProcessHandle 类才有）
                            SEL pidSel = sel_registerName("pid");
                            if ([handle respondsToSelector:pidSel]) {
                                NSMethodSignature *sig = [handle methodSignatureForSelector:pidSel];
                                if (sig) {
                                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                                    [inv setTarget:handle]; [inv setSelector:pidSel]; [inv invoke];
                                    [inv getReturnValue:&pid];
                                }
                            } else {
                                // 2) legacyProcess（FBSceneClientHandle → FBProcessHandle → pid）
                                SEL lpSel = sel_registerName("legacyProcess");
                                id proc = ([handle respondsToSelector:lpSel]) ? [handle performSelector:lpSel] : nil;
                                if (proc && [proc respondsToSelector:pidSel]) {
                                    NSMethodSignature *sig = [proc methodSignatureForSelector:pidSel];
                                    if (sig) {
                                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                                        [inv setTarget:proc]; [inv setSelector:pidSel]; [inv invoke];
                                        [inv getReturnValue:&pid];
                                    }
                                } else {
                                    oc_log("KILL: handle(%s) no pid, legacyProcess=%s",
                                           NSStringFromClass([handle class]).UTF8String ?: "?", proc ? "Y" : "N");
                                }
                            }
                        } else {
                            oc_log("KILL: no clientHandle");
                        }
                        if (pid > 0) {
                            kill(pid, SIGKILL);
                            oc_log("KILL: SIGKILL pid=%d bid=%s", pid, bid.UTF8String);
                            killed = YES;
                        } else {
                            oc_log("KILL: bad pid=%d for %s", pid, bid.UTF8String);
                        }
                        if (stop) *stop = YES;
                    } @catch (NSException *ex) {
                        oc_log("KILL: enum threw %s", ex.reason.UTF8String ?: "");
                    }
                };
                [mgr performSelector:enumSel withObject:enumBlock];
                if (!killed) oc_log("KILL: no pid for %s", bid.UTF8String);
                return;
            }
            // 2) 回退：SBApplicationController → SBApplication → exit
            Class appCtlCls = objc_getClass("SBApplicationController");
            id appCtl = appCtlCls ? [appCtlCls performSelector:@selector(sharedInstance)] : nil;
            SEL findSel = sel_registerName("applicationWithBundleIdentifier:");
            id app = (appCtl && [appCtl respondsToSelector:findSel])
                         ? [appCtl performSelector:findSel withObject:bid] : nil;
            SEL exitSel = sel_registerName("exit");
            if (app && [app respondsToSelector:exitSel]) {
                [app performSelector:exitSel];
                oc_log("KILL: exited %s", bid.UTF8String);
            } else {
                oc_log("KILL: no kill method for %s", bid.UTF8String);
            }
        } @catch (NSException *ex) {
            oc_log("lock_kill_app threw: %s", ex.reason.UTF8String ?: "");
        }
    });
}

// ---- 前台使用时间记录（AI 读取）----
// 每次前台 app 变化，把上一个 app 的 {bid,start_ts,end_ts} 追加到
// /var/mobile/.operit/usage.json（AI 可算"什么时候用了什么、用了多久"）。
// 结构：{"active":{"bid","since_ts"},"history":[{bid,start,end}...]}，history≤500 条。
// 前台来源与锁监控同一个 lock_front_bid()（FBSceneManager，必须在主线程）。
static NSString *g_usagePath; // 由 operit_tweak_init_paths() 解析

// 在主线程调（FBSceneManager 要求）；记录当前前台并返回新 front bid。
static NSString *usage_tick(void) {
    static NSString *g_activeBid = nil;
    static time_t g_activeSince = 0;
    NSString *bid = lock_front_bid();
    if (!bid || bid.length == 0) return nil;
    time_t now = time(NULL);
    if (g_activeBid && ![g_activeBid isEqualToString:bid]) {
        // 前台切换：把上一个 app 的使用段落落盘
        @try {
            NSMutableDictionary *root = [NSMutableDictionary new];
            NSData *d = [NSData dataWithContentsOfFile:g_usagePath];
            if (d) {
                id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                if ([obj isKindOfClass:[NSDictionary class]]) root = [obj mutableCopy];
            }
            NSMutableArray *hist = [NSMutableArray new];
            id h = root[@"history"];
            if ([h isKindOfClass:[NSArray class]]) hist = [h mutableCopy];
            if (g_activeSince > 0 && (now - g_activeSince) >= 1) {
                [hist insertObject:@{
                    @"bid": g_activeBid,
                    @"start": @((long long)g_activeSince),
                    @"end": @((long long)now),
                } atIndex:0];
                if (hist.count > 500) [hist removeObjectsInRange:NSMakeRange(500, hist.count - 500)];
                root[@"history"] = hist;
            }
            root[@"active"] = @{ @"bid": bid, @"since": @((long long)now) };
            NSData *out = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
            if (out) [out writeToFile:g_usagePath atomically:YES];
        } @catch (NSException *ex) {
            oc_log("usage_tick threw: %s", ex.reason.UTF8String ?: "");
        }
    }
    g_activeBid = bid;
    g_activeSince = now;
    return bid;
}

// 锁屏/解锁会话记录：usage.json 的 sessions 数组 [{lock, unlock}, ...] 新在前。
// AI 可据此知道"几点锁屏、几点解锁、中间用了多久"（手机使用时段）。
static void usage_record_session(time_t lockTs, time_t unlockTs) {
    @try {
        if (lockTs <= 0 || unlockTs <= lockTs) return;
        NSMutableDictionary *root = [NSMutableDictionary new];
        NSData *d = [NSData dataWithContentsOfFile:g_usagePath];
        if (d) {
            id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) root = [obj mutableCopy];
        }
        NSMutableArray *sess = [NSMutableArray new];
        id s = root[@"sessions"];
        if ([s isKindOfClass:[NSArray class]]) sess = [s mutableCopy];
        [sess insertObject:@{
            @"lock": @((long long)lockTs),
            @"unlock": @((long long)unlockTs),
        } atIndex:0];
        if (sess.count > 200) [sess removeObjectsInRange:NSMakeRange(200, sess.count - 200)];
        root[@"sessions"] = sess;
        NSData *out = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
        if (out) [out writeToFile:g_usagePath atomically:YES];
        oc_log("SESSION: locked %lld → unlocked %lld (%llds)", (long long)lockTs,
               (long long)unlockTs, (long long)(unlockTs - lockTs));
    } @catch (NSException *ex) {
        oc_log("usage_record_session threw: %s", ex.reason.UTF8String ?: "");
    }
}

// ---- 锁屏检测（fail-open：拿不到就视为未锁屏，继续轮询，绝不误停）----
// iOS 16 SpringBoard 的 SBLockScreenManager + lockScreenController.isLocked。
// 全部探测失败 → 返回 NO（不锁屏），宁可多轮询也不漏拦截。
static BOOL device_is_locked(void) {
    @try {
        Class cls = objc_getClass("SBLockScreenManager");
        if (!cls) return NO;
        id mgr = [cls respondsToSelector:@selector(sharedInstance)]
                     ? [cls performSelector:@selector(sharedInstance)] : nil;
        if (!mgr) return NO;
        @try {
            id lsc = [mgr valueForKey:@"lockScreenController"];
            if (lsc) {
                id locked = [lsc valueForKey:@"isLocked"];
                if (locked) return [locked boolValue];
            }
        } @catch (NSException *ex) {}
        @try {
            id uiLocked = [mgr valueForKey:@"isUILocked"];
            if (uiLocked) return [uiLocked boolValue];
        } @catch (NSException *ex) {}
        @try {
            id locked = [mgr valueForKey:@"isLocked"];
            if (locked) return [locked boolValue];
        } @catch (NSException *ex) {}
    } @catch (NSException *ex) {}
    return NO;
}

// 前台监控：主线程 dispatch_source timer（无 dispatch_sync 阻塞）。
// 间隔自适应：锁屏 → 5s；前台无 app（主屏/搜索）→ 1s；前台有 app → 150ms。
// 手势拦截仍是 0 延迟主力；本监控只兜底"已在运行的 app 切回前台"。
static dispatch_source_t g_lockTimer = NULL;
static NSString *g_lastFront = nil;
static NSString *g_lastBid = nil;
static time_t g_lastBlockAt = 0;

static void lock_monitor_tick(void) {
    @autoreleasepool {
        @try {
            static BOOL g_wasLocked = NO;      // 锁屏状态（状态切换时记会话）
            static time_t g_lockSince = 0;     // 本次锁屏开始时间
            BOOL locked = device_is_locked();
            if (locked != g_wasLocked) {
                oc_log("LOCKSCREEN: %s", locked ? "device locked, monitor sleeping 5s" : "device unlocked, monitor active");
                if (locked) {
                    g_lockSince = time(NULL);   // 锁屏：记开始时间
                } else if (g_lockSince > 0) {
                    usage_record_session(g_lockSince, time(NULL)); // 解锁：写完整会话
                    g_lockSince = 0;
                }
                g_wasLocked = locked;
            }
            if (locked) {
                dispatch_source_set_timer(g_lockTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                                          DISPATCH_TIME_FOREVER, 0);
                return; // 锁屏：不枚举，睡 5s
            }
            if (!operit_cfg_bool(@"usageEnabled", YES)) {
                // 面板关前台感知：不记录 usage、monitor 兜底锁定也停（手势 hook 仍在），低频轮询省电
                dispatch_source_set_timer(g_lockTimer, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                                          DISPATCH_TIME_FOREVER, 0);
                return;
            }
            NSString *bid = usage_tick(); // 前台记录 + 返回当前前台（主线程直跑，无阻塞）
            if (bid && bid.length) {
                if (![bid isEqualToString:g_lastFront]) {
                    oc_log("FRONT: %s", bid.UTF8String);
                    g_lastFront = bid;
                }
                // 前台有 app → 150ms 高频（快速兜底切回）
                dispatch_source_set_timer(g_lockTimer, dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                                          DISPATCH_TIME_FOREVER, 0);
                NSDictionary *cfg = lock_cfg_for(bid);
                if (cfg) {
                    time_t now = time(NULL);
                    if (g_lastBid && [g_lastBid isEqualToString:bid] && (now - g_lastBlockAt) < 5) return;
                    oc_log("LOCK: front=%s blocked", bid.UTF8String);
                    g_lastBid = bid;
                    g_lastBlockAt = now;
                    lock_show_alert(bid, cfg);
                    lock_kill_app(bid);
                    notif_clear_section(bid); // 锁定即清历史通知（官方同款）
                }
            } else {
                // 前台无 app（主屏/搜索/键盘）→ 1s 低频（省电；主屏点击由手势 hook 0 延迟兜住）
                dispatch_source_set_timer(g_lockTimer, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                                          DISPATCH_TIME_FOREVER, 0);
            }
        } @catch (NSException *ex) {
            oc_log("lock_monitor threw: %s", ex.reason.UTF8String ?: "");
        }
    }
}

// ---- 锁屏/解锁 Darwin 信号（iOS 16 可靠主信号；轮询 KVC 兜底保留）----
// com.apple.springboard.lockstate 在锁屏/解锁时必广播，notify_get_state 直接给状态，
// 不依赖私有 KVC key（SBLockScreenManager.isLocked 在 iOS 16.7 实测拿不到）。
static BOOL g_notifLocked = NO;
static time_t g_notifLockSince = 0;

static void register_lockstate_notify(void) {
    int token = 0;
    notify_register_dispatch("com.apple.springboard.lockstate", &token, dispatch_get_main_queue(), ^(int t) {
        uint64_t state = UINT64_MAX;
        notify_get_state(t, &state);
        BOOL locked = (state != 0);
        if (state == UINT64_MAX) locked = device_is_locked(); // 通知未带状态 → KVC 兜底
        if (locked != g_notifLocked) {
            g_notifLocked = locked;
            if (locked) {
                g_notifLockSince = time(NULL);
                oc_log("LOCKSTATE: locked (darwin)");
            } else if (g_notifLockSince > 0) {
                usage_record_session(g_notifLockSince, time(NULL));
                g_notifLockSince = 0;
                oc_log("LOCKSTATE: unlocked, session recorded (darwin)");
            }
        }
    });
    oc_log("LOCKSTATE: darwin notify registered");
}

static void lock_monitor_start(void) {
    if (g_lockTimer) return;
    register_lockstate_notify();
    g_lockTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(g_lockTimer, dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                              DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(g_lockTimer, ^{ lock_monitor_tick(); });
    dispatch_resume(g_lockTimer);
}

// ---- 图标点击拦截：SBIconView.performTap（iOS 16 点击图标执行启动的方法）----
// 穷举确认：SBIconController 类 iOS 16 已不存在；SBIconView 有 performTap（无参）。
// 命中锁名单 → 拦截（不启动 app，弹全屏屏蔽页），与官方"锁 app 本身"一致。

@interface SBIconView : UIView
- (void)performTap;
- (id)icon;
- (BOOL)_delegateTapAllowed;
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event;
- (void)setIcon:(id)icon;
- (UIGestureRecognizer *)tapGestureRecognizer;
@end

%hook SBIconView
- (void)setIcon:(id)icon {
    %orig;
}

- (void)performTap {
    NSString *bid = nil;
    @try {
        id icon = [self valueForKey:@"icon"];
        if (icon) {
            bid = sbicon_bundle_id(icon);
        }
    } @catch (NSException *ex) { bid = nil; }
    oc_log("TAP: performTap bid=%s", bid.UTF8String ?: "?");
    if (lock_try_block(bid)) {
        oc_log("TAP: blocked %s", bid.UTF8String ?: "?");
        return; // 拦截：不启动，屏蔽页已弹
    }
    %orig;
}

- (BOOL)_delegateTapAllowed {
    BOOL r = %orig;
    NSString *bid = nil;
    @try {
        id icon = [self valueForKey:@"icon"];
        if (icon) {
            bid = sbicon_bundle_id(icon);
        }
    } @catch (NSException *ex) { bid = nil; }
    oc_log("TAPD: _delegateTapAllowed=%d bid=%s", r ? 1 : 0, bid.UTF8String ?: "?");
    // 命中锁名单 → 不允许点击启动（先只记录，确认路径后启用拦截）
    // if (lock_try_block(bid)) return NO;
    return r;
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    %orig;
    NSString *bid = nil;
    @try {
        id icon = [self valueForKey:@"icon"];
        if (icon) {
            bid = sbicon_bundle_id(icon);
        }
    } @catch (NSException *ex) { bid = nil; }
    oc_log("TAPT: touchesEnded bid=%s", bid.UTF8String ?: "?");
}
%end

// ---- 手势级拦截：UIGestureRecognizer.setState ----
// iOS 16.7 点图标由 tap 手势识别器接管（SBIconView 的 touchesEnded/performTap 不触发）。
// 手势进入 Began 时若 self.view 是 SBIconView 且命中锁名单 → 手势设 Failed（action 不触发
// → app 不启动）+ 弹屏蔽页。fail-open：任何异常只放行。

%hook UIGestureRecognizer
- (void)setState:(UIGestureRecognizerState)state {
    if (state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateEnded) {
        @try {
            UIView *v = [self valueForKey:@"view"];
            if (v && [NSStringFromClass([v class]) isEqualToString:@"SBIconView"]) {
                id icon = [v valueForKey:@"icon"];
                NSString *bid = nil;
                if (icon) {
                    bid = sbicon_bundle_id(icon);
                }
                if (bid && bid.length && lock_try_block(bid)) {
                    oc_log("GESTURE: blocked %s at state=%ld", bid.UTF8String, (long)state);
                    // 拦截：手势失败 → 不触发启动 action
                    state = UIGestureRecognizerStateFailed;
                    %orig(state);
                    return;
                }
            }
        } @catch (NSException *ex) {
            oc_log("GESTURE setState threw: %s", ex.reason.UTF8String ?: "");
        }
    }
    %orig(state);
}
%end

// ---- 通知拦截：BBObserver ----
// iOS 16 通知进 SpringBoard 的汇聚点：UserNotificationsServer 推送每条通知经
// BBObserver 的 _queue_updateBulletin:withReply:（或 updateBulletin:withReply:）。
// ⚠️ iOS 16 参数是 BBBulletinUpdateTransaction（不是 BBBulletin），sectionID 要
// 从 txn.bulletin.sectionID 取（txn 本身无 sectionID，真机 valueForUndefinedKey 实锤）。
// 命中锁名单 → 丢弃（不 %orig）→ 横幅/锁屏/通知中心全不显示，声音也不响。
// fail-open：异常只放行，不进安全模式。
// 从 BBBulletinUpdateTransaction 取 bulletin 对象（iOS 16 三层结构：
// txn.bulletinUpdate.bulletin，真机属性 dump 实锤：txn 只有 bulletinUpdate+transactionID，
// bulletinUpdate 里才有 bulletin，bulletin 有 sectionID 方法）
static id notif_bulletin(id obj) {
    if (!obj) return nil;
    @try {
        id bu = [obj valueForKey:@"bulletinUpdate"];
        if (bu) {
            @try {
                id b = [bu valueForKey:@"bulletin"];
                if (b) return b;
            } @catch (NSException *ex) {}
        }
    } @catch (NSException *ex) {}
    // 兜底：obj 直接是 bulletinUpdate 或 bulletin
    @try {
        id b = [obj valueForKey:@"bulletin"];
        if (b) return b;
    } @catch (NSException *ex) {}
    return obj;
}

static NSString *notif_section_id(id obj) {
    if (!obj) return nil;
    id bulletin = notif_bulletin(obj);
    @try {
        NSString *s = [bulletin valueForKey:@"sectionID"];
        if (s && s.length) return s;
    } @catch (NSException *ex) {}
    // 再兜底一层：section 方法（BULL2 有 sectionID 方法，非属性）
    @try {
        SEL sel = sel_registerName("sectionID");
        if (bulletin && [bulletin respondsToSelector:sel]) {
            id s = [bulletin performSelector:sel];
            if (s && [s isKindOfClass:[NSString class]] && [(NSString *)s length]) return s;
        }
    } @catch (NSException *ex) {}
    return nil;
}

// ---- 通知记录（AI 读取）----
// 每条通知（无论是否拦截）追加到 /var/mobile/.operit/notifications.json，
// AI 用文件工具读。格式：{"bid","title","body","ts"} 数组，新在前，最多 50 条。
// 去重：queue/update 对同一条通知会各触发一次，与上一条相同(bid+title+body)则只更新时间。
static NSString *g_notifPath; // 由 operit_tweak_init_paths() 解析
static NSMutableArray *g_notifs = nil;
static NSLock *g_notifLock = nil;

static void notif_record(NSString *bid, NSString *title, NSString *body) {
    if (!bid || bid.length == 0) return;
    @try {
        if (!g_notifLock) g_notifLock = [NSLock new];
        [g_notifLock lock];
        if (!g_notifs) {
            NSData *d = [NSData dataWithContentsOfFile:g_notifPath];
            if (d) {
                id arr = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                if ([arr isKindOfClass:[NSArray class]]) g_notifs = [arr mutableCopy];
            }
            if (!g_notifs) g_notifs = [NSMutableArray new];
        }
        NSDictionary *last = g_notifs.firstObject;
        if (last && [last[@"bid"] isEqualToString:bid]
            && [last[@"title"] isEqualToString:title ?: @""]
            && [last[@"body"] isEqualToString:body ?: @""]) {
            // 同一条重复触发：只更新时间戳，不新增
            NSMutableDictionary *m = [last mutableCopy];
            m[@"ts"] = @((long long)time(NULL));
            [g_notifs replaceObjectAtIndex:0 withObject:m];
        } else {
            [g_notifs insertObject:@{
                @"bid": bid,
                @"title": title ?: @"",
                @"body": body ?: @"",
                @"ts": @((long long)time(NULL)),
            } atIndex:0];
        }
        if (g_notifs.count > 50) {
            [g_notifs removeObjectsInRange:NSMakeRange(50, g_notifs.count - 50)];
        }
        NSData *out = [NSJSONSerialization dataWithJSONObject:g_notifs options:0 error:nil];
        if (out) [out writeToFile:g_notifPath atomically:YES];
        [g_notifLock unlock];
        oc_log("NOTIF: recorded %s", bid.UTF8String);
    } @catch (NSException *ex) {
        oc_log("NOTIF: record threw %s", ex.reason.UTF8String ?: "");
        @try { [g_notifLock unlock]; } @catch (NSException *e2) {}
    }
}

// ---- 通知拦截名单（独立于 app 锁定）----
// /var/mobile/.operit/notif_block.plist：{ "<bundleId>": { "ts": ... }, ... }
// Swift NotifyServer 的 notif_block/notif_unblock 读写；tweak 只读。
// 命中 → 该 app 通知不显示（横幅/锁屏/声音全无），但 app 本身不受影响。
static NSString *g_notifBlockPath; // 由 operit_tweak_init_paths() 解析
static NSDictionary *g_notifBlockCache = nil;

static BOOL notif_blocked_for(NSString *bid) {
    if (!operit_cfg_bool(@"notifBlockEnabled", YES)) return NO; // 面板总开关
    if (!bid || bid.length == 0) return NO;
    @try {
        if (!g_notifBlockCache) {
            g_notifBlockCache = [NSDictionary dictionaryWithContentsOfFile:g_notifBlockPath] ?: @{};
        }
        return g_notifBlockCache[bid] != nil;
    } @catch (NSException *ex) {
        return NO;
    }
}

// ---- 历史通知清除（锁定 app 时把通知中心已有通知清掉，官方同款）----
// BBObserver 有 clearSection:/removeBulletins:inSection: 等方法（真机 dump 实锤）；
// 保存一个实例引用（updateBulletin hook 里捕获 self），主线程调 clearSection:。
static __weak id g_bbObserver = nil;

static BOOL notif_clear_section(NSString *bid) {
    if (!bid || bid.length == 0) return NO;
    __block BOOL done = NO;
    void (^run)(void) = ^{
        @try {
            id observer = g_bbObserver;
            if (!observer) {
                // 兜底：从类拿 sharedObserver（若存在）
                Class cls = objc_getClass("BBObserver");
                if (cls && [cls respondsToSelector:@selector(sharedObserver)]) {
                    observer = [cls performSelector:@selector(sharedObserver)];
                }
            }
            if (!observer) { oc_log("CLEAR: no observer for %s", bid.UTF8String); return; }
            SEL sel = sel_registerName("clearSection:");
            if (![observer respondsToSelector:sel]) {
                oc_log("CLEAR: clearSection: missing");
                return;
            }
            [observer performSelector:sel withObject:bid];
            oc_log("CLEAR: cleared %s", bid.UTF8String);
            done = YES;
        } @catch (NSException *ex) {
            oc_log("CLEAR: threw %s", ex.reason.UTF8String ?: "");
        }
    };
    // 主线程直跑（主线程 timer 调用时防死锁）；非主线程才 dispatch_sync
    if ([NSThread isMainThread]) { run(); } else { dispatch_sync(dispatch_get_main_queue(), run); }
    return done;
}

%hook BBObserver
- (void)_queue_updateBulletin:(id)txn withReply:(id)reply {
    @try {
        NSString *section = notif_section_id(txn);
        oc_log("NOTIF: queue section=%s", section.UTF8String ?: "?");
        if (section && section.length && (lock_cfg_for(section) || notif_blocked_for(section))) {
            oc_log("NOTIF: BLOCKED %s (locked app)", section.UTF8String);
            return; // 丢弃：不显示横幅/锁屏/通知中心
        }
    } @catch (NSException *ex) {
        oc_log("NOTIF: queue threw %s", ex.reason.UTF8String ?: "");
    }
    %orig;
}
- (void)updateBulletin:(id)txn withReply:(id)reply {
    @try {
        g_bbObserver = self; // 保存实例供 notif_clear_section 清除历史通知
        NSString *section = notif_section_id(txn);
        oc_log("NOTIF: update section=%s", section.UTF8String ?: "?");
        // 记录到 JSON（AI 读取用）；被锁的也记（AI 知道"谁发了但被拦"）
        id bulletin = notif_bulletin(txn);
        NSString *title = nil, *body = nil;
        if (bulletin) {
            @try { title = [bulletin valueForKey:@"title"]; } @catch (NSException *ex) {}
            @try {
                body = [bulletin valueForKey:@"message"];
                if (!body || body.length == 0) { @try { body = [bulletin valueForKey:@"body"]; } @catch (NSException *ex) {} }
            } @catch (NSException *ex) {}
        }
        notif_record(section, title, body);
        if (section && section.length && (lock_cfg_for(section) || notif_blocked_for(section))) {
            oc_log("NOTIF: BLOCKED %s (locked app)", section.UTF8String);
            return;
        }
    } @catch (NSException *ex) {
        oc_log("NOTIF: update threw %s", ex.reason.UTF8String ?: "");
    }
    %orig;
}
%end

// ---- 剪贴板监听（默认关闭，隐私功能）----
// 开关：/var/mobile/.operit/clipboard_enabled（存在=开）。AI 用文件工具切换。
// 开启时监听 UIPasteboardChangedNotification，把复制内容写 clipboard.json（AI 读取）。
// 只记文本；非文本（图片等）跳过。最多 100 条。
static NSString *g_clipboardPath; // 由 operit_tweak_init_paths() 解析
static NSString *g_clipboardEnablePath; // 由 operit_tweak_init_paths() 解析

// 数据路径统一在 dylib 加载时解析为真实根 /var/mobile/.operit（rootless）。
__attribute__((constructor)) static void operit_tweak_init_paths(void) {
    g_lockPath = @"/var/mobile/.operit/app_lock.plist";
    g_usagePath = @"/var/mobile/.operit/usage.json";
    g_notifPath = @"/var/mobile/.operit/notifications.json";
    g_notifBlockPath = @"/var/mobile/.operit/notif_block.plist";
    g_clipboardPath = @"/var/mobile/.operit/clipboard.json";
    g_clipboardEnablePath = @"/var/mobile/.operit/clipboard_enabled";
}

static BOOL clipboard_is_enabled(void) {
    // 面板开关（com.operit clipboardEnabled）或 AI 文件开关（clipboard_enabled 存在）任一开 = 开
    if (operit_cfg_bool(@"clipboardEnabled", NO)) return YES;
    return [[NSFileManager defaultManager] fileExistsAtPath:g_clipboardEnablePath];
}

static void clipboard_record(NSString *text) {
    if (!text || text.length == 0) return;
    NSString *clean = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (clean.length == 0 || clean.length > 2000) return; // 空 / 超长（可能是图片 base64）跳过
    @try {
        NSMutableArray *arr = [NSMutableArray new];
        NSData *d = [NSData dataWithContentsOfFile:g_clipboardPath];
        if (d) {
            id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            if ([obj isKindOfClass:[NSArray class]]) arr = [obj mutableCopy];
        }
        // 去重：与上一条相同则只更新时间
        NSDictionary *last = arr.firstObject;
        if (last && [last[@"text"] isEqualToString:clean]) {
            NSMutableDictionary *m = [last mutableCopy];
            m[@"ts"] = @((long long)time(NULL));
            [arr replaceObjectAtIndex:0 withObject:m];
        } else {
            [arr insertObject:@{
                @"ts": @((long long)time(NULL)),
                @"text": clean,
                @"app": @"(剪贴板)",
            } atIndex:0];
        }
        if (arr.count > 100) [arr removeObjectsInRange:NSMakeRange(100, arr.count - 100)];
        NSData *out = [NSJSONSerialization dataWithJSONObject:arr options:0 error:nil];
        if (out) [out writeToFile:g_clipboardPath atomically:YES];
        oc_log("CLIP: recorded %lu chars", (unsigned long)clean.length);
    } @catch (NSException *ex) {
        oc_log("CLIP: record threw %s", ex.reason.UTF8String ?: "");
    }
}

static void clipboard_start(void) {
    @try {
        // 始终注册监听；回调里检查开关文件 → AI 随时创建/删除开关即生效，无需重启
        [[NSNotificationCenter defaultCenter] addObserverForName:UIPasteboardChangedNotification
                                                          object:nil queue:nil
                                                      usingBlock:^(NSNotification *note) {
            @try {
                if (!clipboard_is_enabled()) return;
                UIPasteboard *pb = [UIPasteboard generalPasteboard];
                if (pb.hasStrings) clipboard_record(pb.string);
            } @catch (NSException *ex) {
                oc_log("CLIP: notif threw %s", ex.reason.UTF8String ?: "");
            }
        }];
        oc_log("CLIP: listener registered (%s)", clipboard_is_enabled() ? "enabled" : "disabled");
    } @catch (NSException *ex) {
        oc_log("CLIP: start threw %s", ex.reason.UTF8String ?: "");
    }
}



%ctor {
    // @try 保护：dylib 初始化抛异常不让 SpringBoard 进 safe mode
    @try {
        g_sockpath = @"/var/mobile/.operit/operit.sock";
        start_server();
        lock_monitor_start();
        clipboard_start();
        oc_log("operit-sb loaded, lockPath=%s", g_lockPath.UTF8String);
    } @catch (NSException *ex) {
        oc_log("ctor threw: %s", ex.reason.UTF8String ?: "");
    }
}

// ========== SIRI 集成 v1（probe）：识别 → AI → Siri 朗读 ==========
// 链路已验证：AFUISiriSession 识别回调拿文本 → DeepSeek 回答。
// 本轮：回答到达后主动调 AFUISpeechSynthesis.enqueueText: 朗读 + hook _handleText: 拦截替换。

// ========== Siri ↔ operit2 会话同步（sqlite） ==========
// operit2 会话库：runtime/data/database/operit2.sqlite（直接写主表，app 可读，已验证）。
// 当前会话 id：runtime/state/current_chat_id.preferences.json

static NSString *siri_db_path(void) {
    return @"/var/mobile/.operit/operit2/runtime/data/database/operit2.sqlite";
}

static NSString *siri_current_chat_id(void) {
    NSString *p = @"/var/mobile/.operit/operit2/runtime/state/current_chat_id.preferences.json";
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (!d) return nil;
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    NSString *cid = j[@"current_chat_id"];
    return (cid.length ? cid : nil);
}

// 读最近 limit 条 markdown 文本消息（旧→新），返回 {sender, content} 字典数组（跳过工具消息）
static NSArray *siri_load_history(NSString *cid, int limit) {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2([siri_db_path() UTF8String], &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) return @[];
    const char *sql = "SELECT m.sender, p.content FROM messages m JOIN message_parts p ON m.chatId=p.chatId AND m.timestamp=p.messageTimestamp "
                      "WHERE m.chatId=? AND p.kind='markdown' AND p.sequence=0 AND m.sender IN ('user','ai') ORDER BY m.timestamp DESC LIMIT ?";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) { sqlite3_close(db); return @[]; }
    sqlite3_bind_text(stmt, 1, [cid UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(stmt, 2, limit);
    NSMutableArray *rows = [NSMutableArray array];
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const char *sender = (const char *)sqlite3_column_text(stmt, 0);
        const char *content = (const char *)sqlite3_column_text(stmt, 1);
        if (sender && content) {
            [rows addObject:@{@"sender": @(sender), @"content": @(content)}];
        }
    }
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return [[rows reverseObjectEnumerator] allObjects]; // 旧→新
}

// 写一条消息（messages + message_parts），sender: user/ai
static BOOL siri_insert_message(NSString *cid, NSString *sender, NSString *content, NSString *modelName) {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2([siri_db_path() UTF8String], &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) return NO;
    long long now = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
    const char *sql = "INSERT INTO messages (chatId,sender,timestamp,orderIndex,roleName,selectedVariantIndex,provider,modelName,inputTokens,outputTokens,cachedInputTokens,sentAt,outputDurationMs,waitDurationMs,completedAt,displayMode,isFavorite) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) { sqlite3_close(db); return NO; }
    sqlite3_bind_text(stmt, 1, [cid UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, [sender UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 3, now);
    sqlite3_bind_int(stmt, 4, 0);
    NSString *role = [sender isEqualToString:@"ai"] ? @"Operit" : @"user";
    sqlite3_bind_text(stmt, 5, [role UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(stmt, 6, 0);
    sqlite3_bind_text(stmt, 7, "", -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 8, [modelName UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 9, 0);   // inputTokens
    sqlite3_bind_int64(stmt, 10, 0);  // outputTokens
    sqlite3_bind_int64(stmt, 11, 0);  // cachedInputTokens
    sqlite3_bind_int64(stmt, 12, now); // sentAt
    sqlite3_bind_int64(stmt, 13, 0);  // outputDurationMs
    sqlite3_bind_int64(stmt, 14, 0);  // waitDurationMs
    sqlite3_bind_int64(stmt, 15, 0);  // completedAt
    sqlite3_bind_text(stmt, 16, "NORMAL", -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(stmt, 17, 0);    // isFavorite
    BOOL ok = (sqlite3_step(stmt) == SQLITE_DONE);
    sqlite3_finalize(stmt);
    if (ok) {
        const char *sql2 = "INSERT INTO message_parts (chatId,messageTimestamp,variantIndex,partId,sequence,kind,content,toolCallId,toolName,attributesJson) VALUES (?,?,?,?,?,?,?,?,?,?)";
        sqlite3_stmt *s2 = NULL;
        if (sqlite3_prepare_v2(db, sql2, -1, &s2, NULL) == SQLITE_OK) {
            sqlite3_bind_text(s2, 1, [cid UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_int64(s2, 2, now);
            sqlite3_bind_int(s2, 3, 0);
            sqlite3_bind_text(s2, 4, "part-0", -1, SQLITE_TRANSIENT);
            sqlite3_bind_int(s2, 5, 0);
            sqlite3_bind_text(s2, 6, "markdown", -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(s2, 7, [content UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(s2, 8, "", -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(s2, 9, "", -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(s2, 10, "{}", -1, SQLITE_TRANSIENT);
            ok = (sqlite3_step(s2) == SQLITE_DONE);
            sqlite3_finalize(s2);
        } else {
            ok = NO;
        }
    }
    sqlite3_close(db);
    return ok;
}

// Markdown → Siri 纯文本：Siri 气泡只支持纯文本/emoji/换行，
// 表格转 "a | b"、标题去 #、代码块保留内容、加粗/链接/列表去标记。
static NSString *siri_clean_md(NSString *md) {
    if (!md.length) return md;
    NSMutableString *out = [NSMutableString string];
    BOOL inCode = NO;
    for (NSString *raw in [md componentsSeparatedByString:@"\n"]) {
        NSString *line = raw;
        if ([line hasPrefix:@"```"]) { inCode = !inCode; continue; }
        if (inCode) { [out appendFormat:@"%@\n", line]; continue; }
        // 表格分隔行（|---|）丢弃
        NSString *noPipes = [line stringByReplacingOccurrencesOfString:@"[|\\s:-]+" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, line.length)];
        if ([line containsString:@"|"] && noPipes.length == 0) continue;
        // 表格行：去空单元格，保留 | 分隔
        if ([line containsString:@"|"]) {
            NSMutableArray *cells = [NSMutableArray array];
            for (NSString *c in [line componentsSeparatedByString:@"|"]) {
                NSString *t = [c stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (t.length) [cells addObject:t];
            }
            [out appendFormat:@"%@\n", [cells componentsJoinedByString:@" | "]];
            continue;
        }
        line = [line stringByReplacingOccurrencesOfString:@"^(#{1,6})\\s*" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, line.length)];
        line = [line stringByReplacingOccurrencesOfString:@"^([\\s]*)[-*+]\\s+" withString:@"$1• " options:NSRegularExpressionSearch range:NSMakeRange(0, line.length)];
        line = [line stringByReplacingOccurrencesOfString:@"^\\s*>\\s?" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, line.length)];
        line = [line stringByReplacingOccurrencesOfString:@"\\*\\*([^*]+)\\*\\*" withString:@"$1" options:NSRegularExpressionSearch range:NSMakeRange(0, line.length)];
        line = [line stringByReplacingOccurrencesOfString:@"\\*([^*]+)\\*" withString:@"$1" options:NSRegularExpressionSearch range:NSMakeRange(0, line.length)];
        line = [line stringByReplacingOccurrencesOfString:@"`([^`]*)`" withString:@"$1" options:NSRegularExpressionSearch range:NSMakeRange(0, line.length)];
        line = [line stringByReplacingOccurrencesOfString:@"!\\[([^\\]]*)\\]\\([^)]*\\)" withString:@"$1" options:NSRegularExpressionSearch range:NSMakeRange(0, line.length)];
        line = [line stringByReplacingOccurrencesOfString:@"\\[([^\\]]+)\\]\\([^)]*\\)" withString:@"$1" options:NSRegularExpressionSearch range:NSMakeRange(0, line.length)];
        [out appendFormat:@"%@\n", line];
    }
    return [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// 读 operit2 角色卡 + 记忆，构造与 operit2 一致的 system prompt
//（角色 intro = characterSetting + otherContentChat + advancedCustomPrompt，\n\n 连接；
//   记忆 = 该角色的 USER.md，拼在末尾 "USER.md:\n<内容>"，与 ConversationService 一致）
static NSString *siri_build_system_prompt(void) {
    NSString *prefsPath = @"/var/mobile/.operit/operit2/runtime/config/preferences/character_cards.preferences.json";
    NSDictionary *cards = [NSDictionary dictionaryWithContentsOfFile:prefsPath];
    if (!cards) return @"你是 Operit，一个全能 AI 助手。";
    NSString *activeId = cards[@"active_character_card_id"];
    if (![activeId isKindOfClass:[NSString class]] || !activeId.length) activeId = @"default_character";
    NSMutableArray *parts = [NSMutableArray array];
    NSString *setting = cards[[NSString stringWithFormat:@"character_card_%@_character_setting", activeId]];
    if (setting.length) [parts addObject:setting];
    NSString *chat = cards[[NSString stringWithFormat:@"character_card_%@_other_content_chat", activeId]];
    if (chat.length) [parts addObject:chat];
    NSString *adv = cards[[NSString stringWithFormat:@"character_card_%@_advanced_custom_prompt", activeId]];
    if (adv.length) [parts addObject:adv];
    NSString *intro = parts.count ? [parts componentsJoinedByString:@"\n\n"] : @"你是 Operit，一个全能 AI 助手。";
    NSString *mdPath = [NSString stringWithFormat:@"%@/operit2/runtime/data/memory/characters/%@/USER.md", @"/var/mobile/.operit", activeId];
    NSString *md = [NSString stringWithContentsOfFile:mdPath encoding:NSUTF8StringEncoding error:nil];
    if (md.length) {
        return [intro stringByAppendingFormat:@"\n\nUSER.md:\n%@", md];
    }
    return intro;
}

// 调 operit2 的 AI 后端（config.plist 凭证 + 角色记忆 system prompt + 会话历史）
static NSString *siri_ask_ai(NSString *prompt, NSArray *history) {
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/.operit/config.plist"];
    NSString *key = cfg[@"apiKey"];
    NSString *base = cfg[@"apiBaseUrl"];
    NSString *model = cfg[@"apiModel"] ?: @"deepseek-chat";
    if (!key.length || !base.length) return @"ERR|no ai config in /var/mobile/.operit/config.plist";
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:base]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", key] forHTTPHeaderField:@"Authorization"];
    NSString *sys = siri_build_system_prompt();
    // 历史（operit2 会话最近消息，旧→新）：保证上下文一致
    NSMutableArray *messages = [NSMutableArray arrayWithObject:@{@"role": @"system", @"content": sys}];
    for (NSDictionary *h in history) {
        NSString *role = [h[@"sender"] isEqualToString:@"ai"] ? @"assistant" : @"user";
        [messages addObject:@{@"role": role, @"content": h[@"content"]}];
    }
    [messages addObject:@{@"role": @"user", @"content": prompt}];
    NSDictionary *body = @{
        @"model": model,
        @"messages": messages,
        @"max_tokens": @800,
    };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    req.timeoutInterval = 30;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSString *out = nil;
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (d.length) {
            NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            NSArray *choices = j[@"choices"];
            out = choices.count ? choices[0][@"message"][@"content"] : [NSString stringWithFormat:@"ERR|no choices: %@", j];
        } else {
            out = [NSString stringWithFormat:@"ERR|%s", e.localizedDescription.UTF8String ?: "unknown"];
        }
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 35 * NSEC_PER_SEC));
    return out ?: @"ERR|timeout";
}

static NSString *g_siriAIAnswer = nil;
static BOOL g_siriAISpoken = NO;

// %hook 前向声明：允许编译期调用 [self speechSynthesis]
@interface AFUISiriSession : NSObject
- (id)speechSynthesis;
@end

// ========== AFConnection（连接层）hook —— 识别与命令回调在 SpringBoard 进程实测触发 ==========
// AFConnection（AssistantServices 连接层）的识别/命令回调是可靠 hook 点：
//   - _tellSpeechDelegateSpeechRecognized:  识别文本回调（17:35 实测触发）
//   - _handleCommand:reply:                 Siri 命令处理（SAUIAddViews 回答命令实测触发）
// 替换逻辑：收到 SAUIAddViews → 强引用保存 + 同步放行 → AI 回答到达 → 改 text → 重调 _handleCommand: 重新渲染。
static id g_siriAFConn = nil;   // AFConnection 实例（strong）
static id g_lastAddViews = nil; // 最近 SAUIAddViews 命令（strong）— AI 回答到达后改文本重渲染

// ---- AI 回答显示卡片（addSubview 到 Siri VC 视图层级）：先占位后更新 ----
static UIView *g_siriAnswerView = nil;   // 全屏覆盖卡片（strong）
static UILabel *g_siriBodyLabel = nil;   // 卡片内容 label（strong，回答到达后更新）
static id g_siriVC = nil;                // AFUISiriViewController 实例（strong）

static void siri_dismiss_card(void) {
    if (g_siriAnswerView.superview) [g_siriAnswerView removeFromSuperview];
    g_siriAnswerView = nil;
    g_siriBodyLabel = nil;
}

// 显示/更新全屏覆盖卡片：已有卡片则只更新文字；没有则创建（全屏不透明，完全盖住 Siri）
static void siri_show_cover_card(NSString *bodyText) {
    if (!g_siriVC || !bodyText.length) return;
    UIView *host = ((UIViewController *)g_siriVC).view;
    if (!host) return;
    // 已有卡片：只更新内容
    if (g_siriAnswerView && g_siriBodyLabel) {
        g_siriBodyLabel.text = bodyText;
        oc_log("SIRI_CARD_UPDATE len=%ld", (long)bodyText.length);
        return;
    }
    // 底部卡片：左右各 20 边距，底部 80（避开 Siri 麦克风条），高度自适应（v14 稳定版）
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.95];
    card.layer.cornerRadius = 16;
    card.layer.masksToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    // 标题（居中）
    UILabel *title = [[UILabel alloc] init];
    title.text = @"Operit";
    title.font = [UIFont boldSystemFontOfSize:15];
    title.textColor = [UIColor whiteColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    // 内容（占位或 AI 回答，多行左对齐）
    UILabel *body = [[UILabel alloc] init];
    body.text = bodyText;
    body.font = [UIFont systemFontOfSize:14];
    body.textColor = [UIColor whiteColor];
    body.numberOfLines = 0;
    body.textAlignment = NSTextAlignmentLeft;
    body.translatesAutoresizingMaskIntoConstraints = NO;
    g_siriBodyLabel = body;
    // 关闭按钮
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor colorWithRed:0.35 green:0.65 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    __weak UIView *weakCard = card;
    [close addAction:[UIAction actionWithHandler:^(UIAction *a) {
        if (weakCard.superview) [weakCard removeFromSuperview];
        g_siriAnswerView = nil;
        g_siriBodyLabel = nil;
    }] forControlEvents:UIControlEventTouchUpInside];
    // 垂直排列（宽度受卡片约束）
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, body, close]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.alignment = UIStackViewAlignmentFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [host addSubview:card];
    g_siriAnswerView = card;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
        [card.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:20],
        [card.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-20],
        [card.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-80],
        [card.topAnchor constraintGreaterThanOrEqualToAnchor:host.topAnchor constant:80],
    ]];
    oc_log("SIRI_CARD_SHOWN len=%ld", (long)bodyText.length);
}

%hook AFConnection

- (void)_tellSpeechDelegateSpeechRecognized:(id)arg1 {
    oc_log("AF_RECOG %s", [NSString stringWithFormat:@"%@", arg1].UTF8String);
    %orig;
}

- (void)_handleCommand:(id)arg1 reply:(id)arg2 {
    if ([arg1 isKindOfClass:NSClassFromString(@"SAUIAddViews")]) {
        g_lastAddViews = arg1;  // strong：AI 回答到达后改文本 + 重渲染
        g_siriAFConn = self;
        oc_log("SIRI_GOT_ADDVIEWS_AF");
    }
    %orig;
}

%end

// ---- Siri 视图控制器：保存实例（AI 回答卡片 addSubview 的宿主）+ 会话结束清卡片 ----
%hook AFUISiriViewController

- (void)viewDidAppear:(BOOL)animated {
    g_siriVC = self;
    oc_log("SIRI_VC_APPEAR");
    %orig;
}

- (void)viewWillDisappear:(BOOL)animated {
    siri_dismiss_card();
    g_siriVC = nil;
    oc_log("SIRI_VC_DISAPPEAR");
    %orig;
}

%end

%hook AFUISiriSession

// ---- Siri 回答替换 v5（安全版）：强引用 + 重渲染，无手动 swizzle/无野指针 ----
// 收到 SAUIAddViews（Siri 回答气泡）→ 强引用保存 → 同步放行（先正常显示）；
// AI 回答到达（主线程）→ 修改保存命令的 text → 再次调 _handleRequestUpdateViewsCommand:
//   （completion 传空 block 防 nil 崩溃）→ Siri 重新渲染，气泡换成 AI 回答。
static id g_siriSelf = nil;        // AFUISiriSession 实例（strong）

// 收到 SAUIAddViews：iOS 16.7 hook 此方法不生效（v8/v9 实测；原因待查）— v6+ 回答替换实验暂停
- (void)assistantConnection:(id)arg1 receivedCommand:(id)arg2 completion:(id)arg3 {
    %orig;
}

- (void)_handleRequestUpdateViewsCommand:(id)arg1 completion:(id)arg2 {
    %orig;
}

- (void)assistantConnection:(id)arg1 speechRecognized:(id)arg2 {
    %orig;
    if (!operit_cfg_bool(@"siriEnabled", YES)) return; // 设置面板总开关
    NSString *text = nil;
    @try {
        id best = [arg2 performSelector:NSSelectorFromString(@"af_bestTextInterpretation")];
        if (best) text = [NSString stringWithFormat:@"%@", best];
    } @catch (NSException *ex) {
        oc_log("PROBE_ERR af_best %s", ex.reason.UTF8String ?: "?");
    }
    if (!text.length) {
        @try {
            id rec = [arg2 valueForKey:@"recognition"];
            id phrases = [rec valueForKey:@"phrases"];
            if ([phrases isKindOfClass:[NSArray class]] && [phrases count]) {
                id textObj = [phrases[0] valueForKey:@"text"];
                if (textObj) text = [NSString stringWithFormat:@"%@", textObj];
            }
        } @catch (NSException *ex) {
            oc_log("PROBE_ERR phrases %s", ex.reason.UTF8String ?: "?");
        }
    }
    oc_log("PROBE_TEXT=%s", (text ?: @"(empty)").UTF8String);
    NSString *q = [text copy];
    g_siriAIAnswer = nil;
    g_siriAISpoken = NO;
    g_lastAddViews = nil;       // 新一轮：清旧命令
    g_siriSelf = self;          // strong：AI 到达后重渲染要用（在异步块外主线程设置）
    // 立即显示全屏占位卡片（盖住 Siri，让用户看到 AI 在响应；回答到了再更新）
    dispatch_async(dispatch_get_main_queue(), ^{
        siri_show_cover_card(@"思考中…");
    });
    // ① 先把用户的话写入 operit2 会话（同步 operit2 → Siri）
    // 限频：3 秒内重复写入同一 chat 跳过（防 Flutter ChatArea 状态堆积崩溃）
    static NSString *lastWriteCid = nil;
    static NSTimeInterval lastWriteTime = 0;
    NSString *cid = siri_current_chat_id();
    NSTimeInterval now_ts = [[NSDate date] timeIntervalSince1970];
    if (cid.length && q.length) {
        BOOL rateLimited = (cid == lastWriteCid || [cid isEqualToString:lastWriteCid]) && (now_ts - lastWriteTime) < 3.0;
        if (rateLimited) {
            oc_log("SIRI_SYNC_USER rate-limited");
        } else {
            siri_insert_message(cid, @"user", q, @"");
            oc_log("SIRI_SYNC_USER ok");
            lastWriteCid = cid;
            lastWriteTime = now_ts;
        }
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // ② 读 operit2 会话历史（含刚写入的 user）→ 带上下文调 AI
        NSArray *history = cid.length ? siri_load_history(cid, 20) : @[];
        NSString *ans = siri_ask_ai(q.length ? q : @"你好", history);
        g_siriAIAnswer = ans;
        oc_log("PROBE_AI_ANSWER=%s", ans.UTF8String);
        // ③ AI 回答写回 operit2 会话（同步 Siri → operit2）
        if (cid.length && ans.length) {
            NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/.operit/config.plist"];
            siri_insert_message(cid, @"ai", ans, cfg[@"apiModel"] ?: @"deepseek-chat");
            oc_log("SIRI_SYNC_AI ok");
        }
        // ④ 主线程：更新全屏卡片内容为 AI 回答（识别时已显示"思考中…"占位）
            dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                NSString *clean = siri_clean_md(ans);
                oc_log("SIRI_CLEAN=%s", clean.UTF8String);
                if (clean.length) {
                    siri_show_cover_card(clean);
                } else {
                    oc_log("SIRI_CARD_SKIP empty");
                }
            } @catch (NSException *ex) {
                oc_log("SIRI_CARD_ERR %s", ex.reason.UTF8String ?: "?");
            }
            // ⑤ 尝试朗读（speechSynthesis 不存在则无害）
            @try {
                id synth = [self speechSynthesis];
                if (synth) {
                    SEL sel = NSSelectorFromString(@"enqueueText:identifier:completion:");
                    if ([synth respondsToSelector:sel]) {
                        NSMethodSignature *sig = [synth methodSignatureForSelector:sel];
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        inv.target = synth;
                        inv.selector = sel;
                        __unsafe_unretained NSString *txt = ans;
                        [inv setArgument:&txt atIndex:2];
                        __unsafe_unretained NSString *ident = @"operit.ai";
                        [inv setArgument:&ident atIndex:3];
                        __unsafe_unretained id nilBlock = nil;
                        [inv setArgument:&nilBlock atIndex:4];
                        [inv invoke];
                        g_siriAISpoken = YES;
                        oc_log("PROBE_TTS_ENQUEUED class=%s", NSStringFromClass([synth class]).UTF8String);
                    } else {
                        oc_log("PROBE_TTS_NO_ENQUEUE");
                    }
                } else {
                    oc_log("PROBE_TTS_NO_SYNTH");
                }
            } @catch (NSException *ex) {
                oc_log("PROBE_TTS_ERR %s", ex.reason.UTF8String ?: "?");
            }
        });
    });
}

- (id)speechSynthesis {
    id s = %orig;
    oc_log("PROBE_TTS_CLASS %s", s ? NSStringFromClass([s class]).UTF8String : "nil");
    return s;
}

%end

%hook AFUISpeechSynthesis

// Siri 默认朗读入口：有 AI 回答时替换文本（双保险）
- (void)_handleText:(id)arg1 completion:(id)arg2 {
    if (g_siriAIAnswer.length && !g_siriAISpoken) {
        arg1 = g_siriAIAnswer;
        g_siriAISpoken = YES;
        oc_log("PROBE_TTS_REPLACED");
    } else {
        oc_log("PROBE_TTS_TEXT %s", [NSString stringWithFormat:@"%@", arg1].UTF8String);
    }
    %orig;
}

%end

