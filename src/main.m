//
//  main.m — 入口
//
//  启动顺序：装 UI → 后台恢复「自启真后台」→ 可选地跑一次一键加速。
//  原包在这里做的是等待 SpringBoard 就绪、然后开 CFMessagePort 服务；那套 IPC
//  这次直接删掉：它用的端口名是 com.example.myPort（示例名，没改过），
//  任何进程都能连上去发指令，属于白送一个控制面。
//
#import "RB.h"

@interface RBAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
- (void)restoreAutoStart;
@end

@implementation RBAppDelegate

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    RBLog(@"启动 %@ (%@)", RB_VERSION, [[NSBundle mainBundle] bundleIdentifier]);

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor blackColor];
    RBRootVC *root = [RBRootVC new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.navigationBar.translucent = NO;
    nav.navigationBar.barTintColor = [UIColor colorWithWhite:0.07 alpha:1];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];

    // 注意：这里不再设置 idleTimerDisabled = YES。
    // 原先把屏幕常亮写死在启动里，退出 App 后也不会恢复，纯粹耗电。

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self restoreAutoStart];

        if ([[RBStore shared] boostOnLaunch]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                RBLog(@"启动加速");
                [RBBooster boostProtecting:[RBStore shared].backstageIDs];
            });
        }
    });
    return YES;
}

/// 把「自启」列表里正在运行的 App 重新拉进真后台。
/// 进程枚举放后台线程（读几十个 Info.plist），真正建 scene 回主线程（UIKit 相关）。
- (void)restoreAutoStart {
    NSSet *autoStart = [[RBStore shared].autoStartIDs copy];
    if (autoStart.count == 0) return;

    NSDictionary *running = [RBProcesses runningPids];
    NSMutableArray *hits = [NSMutableArray array];
    for (NSString *bid in autoStart) {
        NSNumber *pid = running[bid];
        if (pid) [hits addObject:@[bid, pid]];
    }
    if (hits.count == 0) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSArray *pair in hits) {
            NSString *bid = pair[0];
            pid_t pid = (pid_t)[pair[1] intValue];
            NSError *err = nil;
            if ([[RBBackstage shared] enableForBundle:bid pid:pid error:&err]) {
                RBLog(@"自启真后台已恢复：%@", bid);
            } else {
                RBLog(@"自启恢复失败：%@ (%@)", bid, err.localizedDescription);
            }
        }
    });
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    // 自己进后台时把真后台的 scene 保留着（本 App 被挂起后 scene 会断，
    // 所以这里不主动清理，交给系统按需回收）
    RBLog(@"进入后台，已挂载：%@", [[RBBackstage shared] enabledBundles]);
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([RBAppDelegate class]));
    }
}
