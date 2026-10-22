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

/// 按「自启」名单恢复：
///   · 已经在跑的 → 直接挂真后台
///   · 没在跑的   → 先把它启动起来，等进程就绪后再挂真后台
///
/// 1.2.x 只做了前一半，于是「自启」对没运行的 App 等于空转 —— 开关点了没效果。
/// 锁定名单里的不恢复：锁定的意思是「别管它」，别自己又去给它挂 scene。
- (void)restoreAutoStart {
    NSSet *autoStart = [[RBStore shared].autoStartIDs copy];
    if (autoStart.count == 0) return;
    NSSet *lock = [[RBStore shared].lockIDs copy];

    // 进程枚举要读几十个 Info.plist，绝不能在主线程做
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *running = [RBProcesses runningPids];
        NSMutableArray<NSDictionary *> *toAttach = [NSMutableArray array];
        NSMutableArray<NSString *> *toLaunch = [NSMutableArray array];

        for (NSString *bid in autoStart) {
            if ([lock containsObject:bid]) continue;
            NSNumber *pid = running[bid];
            if (pid) [toAttach addObject:@{ @"bid": bid, @"pid": pid }];
            else [toLaunch addObject:bid];
        }

        // 先把没在跑的拉起来
        NSMutableArray<NSString *> *launched = [NSMutableArray array];
        for (NSString *bid in toLaunch) {
            if ([RBProcesses launchApp:bid]) [launched addObject:bid];
            else RBLog(@"自启启动失败：%@", bid);
        }
        if (launched.count) usleep(1800 * 1000);     // 等进程真正起来

        // 重新取一遍 pid：刚启动的那批这时才有 pid
        NSDictionary *now = [RBProcesses runningPids];
        for (NSString *bid in launched) {
            NSNumber *pid = now[bid];
            if (pid) [toAttach addObject:@{ @"bid": bid, @"pid": pid }];
        }
        if (toAttach.count == 0) return;

        // 建 scene 是 UIKit 操作，回主线程
        dispatch_async(dispatch_get_main_queue(), ^{
            for (NSDictionary *d in toAttach) {
                NSString *bid = d[@"bid"];
                pid_t pid = (pid_t)[d[@"pid"] intValue];
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
