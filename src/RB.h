//
//  RB.h — 真后台 Pro（RealBG）
//
//  基于对 cn.bswbw.RealBackstage 1.5 的静态还原重写：
//    · 保留「真后台 / 杀后台 / 自启」三件事的实现思路（FBScene + UIScenePresenter）
//    · 去掉原包里的通用 CFMessagePort 端口（com.example.myPort，无鉴权，任何进程可连）
//    · 去掉 task_for_pid / system-task-ports / hid.* 等与功能无关的高危权限
//    · 不引入任何网络代码（原包也无外发，只有 t.me / PayPal / 支付宝三个跳转按钮）
//    · 修掉原包写死 com.thefool.app.plist 的配置路径 bug
//    · 新增「一键加速」：批量结束后台进程并统计释放内存
//    · 新增「保留名单（锁定）」：锁住的 App 永远不会被加速/退出清理碰到
//    · 新增崩溃捕获与运行日志：闪退现场落盘，下次启动界面直接显示
//
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#define RB_VERSION @"1.3.0"
#define RB_BUNDLE @"cn.bswbw.RealBG"

// 配置：/var/mobile/Library/Preferences/cn.bswbw.RealBG.plist
#define RB_PREFS_DIR  @"/var/mobile/Library/Preferences"
#define RB_PREFS_NAME @"cn.bswbw.RealBG.plist"

#pragma mark - 数据模型

@interface RBAppInfo : NSObject
@property (nonatomic, copy)   NSString *bundleID;
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, strong) UIImage  *icon;
@property (nonatomic, assign) BOOL      isSystem;
@property (nonatomic, assign) BOOL      isRunning;
@property (nonatomic, assign) pid_t     pid;
@property (nonatomic, assign) BOOL      hasBackstage;   // 已开真后台
@property (nonatomic, assign) BOOL      hasAutoStart;   // 已加自启
@property (nonatomic, assign) BOOL      hasSuicide;     // 退出本 App 时结束
@property (nonatomic, assign) BOOL      locked;         // 已锁定：加速永不清理
@end

#pragma mark - 配置

@interface RBStore : NSObject
@property (nonatomic, strong) NSMutableSet *backstageIDs;
@property (nonatomic, strong) NSMutableSet *autoStartIDs;
@property (nonatomic, strong) NSMutableSet *suicideIDs;
/// 保留名单。一键加速、退出清理都不会碰这里面的 App。
@property (nonatomic, strong) NSMutableSet *lockIDs;
@property (nonatomic, assign) BOOL boostOnLaunch;   // 启动时自动加速一次
+ (instancetype)shared;
- (void)save;
- (void)reload;
/// 加速/清理时应当保护的全部 bundleID（真后台 + 锁定，合并后返回）
- (NSSet *)allProtectedIDs;
@end

#pragma mark - 进程层

@interface RBProcesses : NSObject
/// 已安装应用（含系统应用），系统应用排在后面
+ (NSArray<RBAppInfo *> *)installedApps;
/// 正在运行的 pids（bundleID -> pid）
+ (NSDictionary<NSString *, NSNumber *> *)runningPids;
/// 进程是否真的还活着。kill(pid,0) 只能证明「信号投递没被拒」，
/// 僵尸进程同样会回 0；这里再加一层 proc_pidpath 确认，僵尸取不到路径。
+ (BOOL)isPidAlive:(pid_t)pid;
/// 等进程真正退出（轮询），返回是否已死
+ (BOOL)waitPidDead:(pid_t)pid timeoutMS:(int)ms;
/// 结束单个进程；返回「进程确实已经不在了」而不是「信号发出去了」
+ (BOOL)killPid:(pid_t)pid;
/// 结束整个 App（含子进程）
+ (BOOL)killApp:(NSString *)bundleID pid:(pid_t)pid;
/// 当前可用内存（MB）
+ (double)freeMemoryMB;
/// 当前已用内存（MB）
+ (double)usedMemoryMB;
/// 单个 pid -> bundleID（不在 /Bundle/Application/ 下返回 nil）
+ (NSString *)bundleIDForPid:(pid_t)pid;
/// 是不是系统 App（com.apple.* 或本 App 自己）—— 这类一律不杀
+ (BOOL)isSystemBundle:(NSString *)bundleID;
/// 系统关键进程判断（按可执行名）
+ (BOOL)isProtectedExec:(NSString *)exe;
+ (NSSet *)protectedBundleIDs;
@end

#pragma mark - 真后台

@interface RBBackstage : NSObject
+ (instancetype)shared;
/// 为目标 App 挂 scene（真后台）；失败自动退回 RBS assertion
- (BOOL)enableForBundle:(NSString *)bundleID pid:(pid_t)pid error:(NSError **)error;
- (void)disableForBundle:(NSString *)bundleID;
- (BOOL)isEnabledForBundle:(NSString *)bundleID;
- (NSArray<NSString *> *)enabledBundles;
/// 一键加速用：把「我们挂上去的」保活全撤掉。只 kill 进程而不撤保活，
/// SpringBoard 会立刻把 App 拉回来，表现就是「加速完了它还在运行」。
/// 注意：默认保护的名单里本来就含真后台 App，这里只是兜底清理。
+ (void)releaseOwnedBackstage;
@end

#pragma mark - 一键加速

@interface RBBooster : NSObject
/// 批量结束后台进程。protect: 不杀的 bundleID（真后台 + 锁定名单）
/// 返回 @{@"killed", @"failed", @"relaunched", @"freedMB", @"beforeMB", @"afterMB",
///        @"lockedSkipped", @"lockedKeptMB", @"lockedNames", @"details", @"killedIDs", @"groups"}
/// killed 只统计「杀完验证确实消失」的；relaunched 是「杀掉了又被系统拉起来」的数量。
+ (NSDictionary *)boostProtecting:(NSSet *)protect;
/// 可清理候选（按占用内存降序），元素：@{bundleID, pid, mb, estimated}
+ (NSArray<NSDictionary *> *)candidatesProtecting:(NSSet *)protect;
/// 被保留名单挡下、本来会被清理的进程（用来在界面上说明「省下了多少」）
+ (NSArray<NSDictionary *> *)lockedCandidatesProtecting:(NSSet *)protect;
/// 单个进程的真实物理占用（phys_footprint，MB）
+ (double)footprintMBForPid:(pid_t)pid;
@end

#pragma mark - UI

@interface RBRootVC : UIViewController
@end

#pragma mark - 工具

FOUNDATION_EXPORT void RBLog(NSString *fmt, ...);
FOUNDATION_EXPORT NSString *RBHumanMB(double mb);

#pragma mark - 崩溃捕获

/// 装未捕获异常 + 致命信号的处理。越早调用越好（main 第一行）。
FOUNDATION_EXPORT void RBInstallCrashHandler(void);
/// 上一次运行留下的崩溃记录（没有则 nil）。main 启动时读，界面显示。
FOUNDATION_EXPORT NSString *RBReadLastCrash(void);
/// 用户看完后清掉
FOUNDATION_EXPORT void RBDismissCrash(void);
FOUNDATION_EXPORT NSString *RBCrashLogPath(void);
FOUNDATION_EXPORT NSString *RBRunLogPath(void);
/// 日志所在目录（界面上要告诉用户去哪找）
FOUNDATION_EXPORT NSString *RBLogDirPath(void);
