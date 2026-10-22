//
//  main.m — lite 探针版
//
//  这个 App 只做一件事：证明「打包链路能不能装出一个能打开的 App」。
//
//  它故意不含任何可能出问题的东西：
//    · 不调用任何私有 API（没有 FrontBoard / RunningBoard / libproc）
//    · 不链接任何私有框架（只有 UIKit + Foundation）
//    · 不开文件共享、不写日志、不装信号处理器
//    · entitlements 只用 TrollStore 官方推荐的最小集（platform-application + no-sandbox）
//
//  用途是二分定位：
//    lite 能打开、完整版闪退  → 问题在完整版的代码或权限
//    lite 也闪退              → 问题在打包 / 签名 / TrollStore 注册状态，跟代码无关
//
#import <UIKit/UIKit.h>

@interface LiteVC : UIViewController
@end

@implementation LiteVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.05 green:0.42 blue:0.24 alpha:1.0];
    self.title = @"探针";

    UILabel *title = [[UILabel alloc] init];
    title.text = @"LITE OK";
    title.font = [UIFont boldSystemFontOfSize:42];
    title.textColor = [UIColor whiteColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];

    UILabel *sub = [[UILabel alloc] init];
    sub.text = [NSString stringWithFormat:@"%@\niOS %@  ·  %@",
                [[NSBundle mainBundle] bundleIdentifier],
                [[UIDevice currentDevice] systemVersion],
                [[UIDevice currentDevice] model]];
    sub.numberOfLines = 0;
    sub.font = [UIFont systemFontOfSize:15];
    sub.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    sub.textAlignment = NSTextAlignmentCenter;
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:sub];

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-24],
        [sub.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:16],
        [sub.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [sub.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:20],
        [sub.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-20],
    ]];
}

@end

@interface LiteDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation LiteDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[LiteVC new]];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([LiteDelegate class]));
    }
}
