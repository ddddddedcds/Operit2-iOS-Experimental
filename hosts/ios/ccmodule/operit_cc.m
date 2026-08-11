// OperitCC —— 控制中心 AI 按钮（CCSupport 模块）
// 点击 = 启动 operit2（AI 助手 app）。CCUIAppLauncherModule 是 ControlCenterUIKit
// 的运行时类（私有框架，无需链接，动态派发）。安装位置 /Library/CCSupport/OperitCC.bundle。
#import <UIKit/UIKit.h>

// 运行时类声明（私有框架，仅编译期需要）
@interface CCUIAppLauncherModule : NSObject
- (NSString *)applicationIdentifier;
- (UIImage *)iconGlyph;
@end

@interface UIImage ()
+ (UIImage *)imageNamed:(NSString *)name inBundle:(NSBundle *)bundle;
@end

@interface OperitCCModule : CCUIAppLauncherModule
@end

@implementation OperitCCModule

- (UIImage *)iconGlyph {
    return [UIImage imageNamed:@"Icon" inBundle:[NSBundle bundleForClass:[self class]]];
}

- (NSString *)applicationIdentifier {
    // 控制中心一键启动 operit2
    return @"com.ai.assistance.operit2";
}

@end
