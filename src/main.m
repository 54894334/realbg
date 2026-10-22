//
//  main.m — 入口
//
//  启动顺序：装崩溃捕获 → 装 UI → 后台恢复「自启真后台」→ 可选地跑一次一键加速。
//
//  原包在这里做的是等待 SpringBoard 就绪、然后开 CFMessagePort 服务；那套 IPC
//  这次直接删掉：它用的端口名是 com.example.myPort（示例名，没改过），
//  任何进程都能连上去发指令，属于白送一个控制面。
//
#import "RB.h"

@interface RBAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
- (void)restoreAutoStart;
- (void)performSuicideCleanup;
@end

@implementation RBAppDelegate

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    RBLog(@"启动 %@ (%@) iOS %@", RB_VERSION,
          [[NSBundle mainBundle] bundleIdentifier],
          [[UIDevice currentDevice] systemVersion]);

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

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            [self restoreAutoStart];
        } @catch (NSException *e) {
            RBLog(@"自启恢复异常：%@", e.reason);
        }

        if ([[RBStore shared] boostOnLaunch]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                RBLog(@"启动加速");
                NSSet *protect = [[RBStore shared] allProtectedIDs];
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    @try {
                        [RBBooster boostProtecting:protect];
                    } @catch (NSException *e) {
                        RBLog(@"启动加速异常：%@", e.reason);
                    }
                });
            });
        }
    });
    return YES;
}

/// 把「自启」列表里正在运行的 App 重新拉进真后台。
/// 进程枚举放后台线程（读几十个 Info.plist），真正建 scene 回主线程（UIKit 相关）。
/// 锁定名单里的不恢复 —— 锁定的意思是「别管它」，别自己又去给它挂 scene。
- (void)restoreAutoStart {
    NSSet *autoStart = [[RBStore shared].autoStartIDs copy];
    if (autoStart.count == 0) return;
    NSSet *lock = [[RBStore shared].lockIDs copy];

    NSDictionary *running = [RBProcesses runningPids];
    NSMutableArray *hits = [NSMutableArray array];
    for (NSString *bid in autoStart) {
        if ([lock containsObject:bid]) continue;
        NSNumber *pid = running[bid];
        if (pid) [hits addObject:@[bid, pid]];
    }
    if (hits.count == 0) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSArray *pair in hits) {
            NSString *bid = pair[0];
            pid_t pid = (pid_t)[pair[1] intValue];
            NSError *err = nil;
            @try {
                if ([[RBBackstage shared] enableForBundle:bid pid:pid error:&err]) {
                    RBLog(@"自启真后台已恢复：%@", bid);
                } else {
                    RBLog(@"自启恢复失败：%@ (%@)", bid, err.localizedDescription);
                }
            } @catch (NSException *e) {
                RBLog(@"自启恢复异常：%@ %@", bid, e.reason);
            }
        }
    });
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    // 自己进后台时把真后台的 scene 保留着（本 App 被挂起后 scene 会断，
    // 所以这里不主动清理，交给系统按需回收）
    RBLog(@"进入后台，已挂载：%@", [[RBBackstage shared] enabledBundles]);
    @try {
        [self performSuicideCleanup];
    } @catch (NSException *e) {
        RBLog(@"退出清理异常：%@", e.reason);
    }
}

/// 「退出即杀」名单里的 App，在本 App 退到后台时清理掉。
/// 第一版这里只把选择存进 plist，没有任何代码读它 —— 开关点了等于没点。
///
/// 冲突时的优先级：锁定 > 真后台 > 退出即杀。
/// 锁定的 App 一律不碰；真后台名单里的也不杀（要保活就别同时配退出即杀）。
- (void)performSuicideCleanup {
    NSSet *suicide = [[RBStore shared].suicideIDs copy];
    if (suicide.count == 0) return;
    NSSet *lock = [[RBStore shared].lockIDs copy];
    NSSet *backstage = [[RBStore shared].backstageIDs copy];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *running = [RBProcesses runningPids];
        NSInteger n = 0;
        for (NSString *bid in suicide) {
            if ([lock containsObject:bid]) continue;          // 锁定优先
            if ([backstage containsObject:bid]) continue;     // 真后台优先于退出即杀
            NSNumber *pid = running[bid];
            if (!pid) continue;                               // 没在跑就不用管
            if ([RBProcesses killApp:bid pid:pid.intValue]) n++;
        }
        RBLog(@"退出清理：结束 %ld 个", (long)n);
    });
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // 第一件事就装崩溃捕获：越早装，越可能抓到崩溃现场。
        // 这里只做 signal / 异常处理器注册，不碰 UIKit。
        RBInstallCrashHandler();
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([RBAppDelegate class]));
    }
}
