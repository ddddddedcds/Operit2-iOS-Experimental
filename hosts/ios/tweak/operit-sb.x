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
#include "operit_log.h"
#import "roothide_compat.h"

// ---- app lock（启动拦截名单）----
// 名单文件：/var/mobile/.operit/app_lock.plist（真实根，SpringBoard mobile 可写/读；
// rootless app 无沙箱也可写同一路径；roothide 双视图问题由写端负责，见 ScreenTimeServer）。
// 格式：{ "<bundleId>": { "title": "...", "subtitle": "...", "button": "..." }, ... }
// 拦截点：FBSSystemService / FBSOpenApplicationService（FrontBoard 统一启动入口，
// SpringBoard 前台启动与外部请求都汇聚于此）+ 本 tweak 的 cmd_launch（AI 主动启动一致拦截）。

static NSString *g_lockPath = @"/var/mobile/.operit/app_lock.plist";

static NSDictionary *lock_load(void) {
    return [NSDictionary dictionaryWithContentsOfFile:g_lockPath] ?: @{};
}

static NSDictionary *lock_cfg_for(NSString *bid) {
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

// 统一拦截判定：命中锁名单 → 阻断 + 弹提示 + 返回 YES（已拦截）；否则 NO（放行）。
// fail-open：任何异常都视为"未命中"，保证拦截逻辑出问题只会放行、绝不进安全模式。
static BOOL lock_try_block(NSString *bid) {
    @try {
        if (!bid || bid.length == 0) return NO;
        NSDictionary *cfg = lock_cfg_for(bid);
        if (!cfg) return NO;
        oc_log("LOCK: blocking launch of %s", bid.UTF8String);
        lock_show_alert(bid, cfg);
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
    NSString *path = operit_env_path(@"/var/jb/var/mobile/.operit/screen.png");
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
    NSString *pidPath = operit_env_path(@"/var/jb/var/mobile/.operit/front.pid");
    NSString *pidStr = [NSString stringWithContentsOfFile:pidPath
                                                  encoding:NSUTF8StringEncoding error:nil];
    pidStr = [pidStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!pidStr || pidStr.length == 0) return @"ERR|type: no foreground app (front.pid empty)";
    NSString *sock = [NSString stringWithFormat:@"%@/app.%@.sock", operit_env_path(@"/var/jb/var/mobile/.operit"), pidStr];
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
// 前台 app（复用 cmd_front 的 SBWorkspace frontmostApplication 探测）：前台命中
// 锁名单 → 弹自定义提示页 + 杀进程回桌面。任何启动方式都能拦住。

static NSString *lock_front_bid(void) {
    __block NSString *r = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            // 1) 首选：FBSceneManager.enumerateScenesWithBlock（iOS 16 全局 scene 枚举）
            //    settings.isForeground 判定前台；identity.identifier 剥 sceneID:/-default 得 bundle id。
            @try {
                Class mgrCls = objc_getClass("FBSceneManager");
                id mgr = (mgrCls && [mgrCls respondsToSelector:@selector(sharedInstance)])
                             ? [mgrCls performSelector:@selector(sharedInstance)] : nil;
                SEL enumSel = sel_registerName("enumerateScenesWithBlock:");
                if (mgr && [mgr respondsToSelector:enumSel]) {
                    __block NSString *foundBid = nil;
                    void (^enumBlock)(id, BOOL *) = ^(id scene, BOOL *stop) {
                        @try {
                            NSNumber *fg = [scene valueForKeyPath:@"settings.isForeground"];
                            NSString *bid = [[scene valueForKey:@"identity"] valueForKey:@"identifier"];
                            // sceneID:<bundleId>-default → <bundleId>
                            if ([bid hasPrefix:@"sceneID:"]) bid = [bid substringFromIndex:8];
                            if ([bid hasSuffix:@"-default"]) bid = [bid substringToIndex:bid.length - 8];
                            if ([fg boolValue] && bid && bid.length
                                && ![bid isEqualToString:@"com.apple.springboard"]) {
                                foundBid = bid;
                                if (stop) *stop = YES;
                            }
                        } @catch (NSException *ex) {
                            oc_log("lock_front: enum block threw %s", ex.reason.UTF8String ?: "");
                        }
                    };
                    [mgr performSelector:enumSel withObject:enumBlock];
                    if (foundBid) { r = foundBid; return; }
                }
            } @catch (NSException *ex) {
                oc_log("lock_front: fbscenemgr threw %s", ex.reason.UTF8String ?: "");
            }
            // 2) 兜底：SBWorkspace frontmostApplication（iOS 16 实测多返回 nil，保留兼容）
            @try {
                Class wsCls = objc_getClass("SBWorkspace") ?: objc_getClass("FBWorkspace");
                id ws = nil;
                if (wsCls && [wsCls respondsToSelector:@selector(sharedInstance)])
                    ws = [wsCls performSelector:@selector(sharedInstance)];
                else if (wsCls && [wsCls respondsToSelector:@selector(mainWorkspace)])
                    ws = [wsCls performSelector:@selector(mainWorkspace)];
                SEL frontSel = sel_registerName("frontmostApplication");
                id front = (ws && [ws respondsToSelector:frontSel]) ? [ws performSelector:frontSel] : nil;
                r = [front valueForKey:@"bundleIdentifier"];
            } @catch (NSException *ex) { r = nil; }
        } @catch (NSException *ex) { r = nil; }
    });
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

static void *lock_monitor_thread(void *unused) {
    (void)unused;
    static NSString *g_lastBid = nil;
    static NSString *g_lastFront = nil;
    static time_t g_lastBlockAt = 0;
    while (1) {
        usleep(500000); // 0.5s 轮询
        @autoreleasepool {
            @try {
                NSString *bid = lock_front_bid();
                if (!bid || bid.length == 0) continue; // 前台取不到：静默
                if (![bid isEqualToString:g_lastFront]) {
                    oc_log("FRONT: %s", bid.UTF8String);
                    g_lastFront = bid;
                }
                NSDictionary *cfg = lock_cfg_for(bid);
                if (!cfg) continue; // 未锁：静默（FRONT 已记录变化）
                time_t now = time(NULL);
                if (g_lastBid && [g_lastBid isEqualToString:bid] && (now - g_lastBlockAt) < 5) continue;
                oc_log("LOCK: front=%s blocked", bid.UTF8String);
                g_lastBid = bid;
                g_lastBlockAt = now;
                lock_show_alert(bid, cfg);
                lock_kill_app(bid);
            } @catch (NSException *ex) {
                oc_log("lock_monitor threw: %s", ex.reason.UTF8String ?: "");
            }
        }
    }
    return NULL;
}

%ctor {
    g_sockpath = operit_env_path(@"/var/jb/var/mobile/.operit/operit.sock");
    start_server();
    pthread_t lockT;
    pthread_create(&lockT, NULL, lock_monitor_thread, NULL);
    oc_log("operit-sb loaded, lockPath=%s, roothide=%d", g_lockPath.UTF8String, operit_is_roothide());
}

