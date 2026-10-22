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
//
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#define RB_VERSION @"1.0.0"
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
@property (nonatomic, assign) BOOL      hasSuicide;     // 切后台即杀（省内存）
@end

#pragma mark - 配置

@interface RBStore : NSObject
@property (nonatomic, strong) NSMutableSet *backstageIDs;
@property (nonatomic, strong) NSMutableSet *autoStartIDs;
@property (nonatomic, strong) NSMutableSet *suicideIDs;
@property (nonatomic, assign) BOOL boostOnLaunch;   // 启动时自动加速一次
+ (instancetype)shared;
- (void)save;
- (void)reload;
@end

#pragma mark - 进程层

@interface RBProcesses : NSObject
/// 已安装应用（含系统应用），按 bundleID 排序
+ (NSArray<RBAppInfo *> *)installedApps;
/// 正在运行的 pids（bundleID -> pid）
+ (NSDictionary<NSString *, NSNumber *> *)runningPids;
/// 结束单个进程；返回是否成功
+ (BOOL)killPid:(pid_t)pid;
/// 结束整个 App（含子进程）
+ (BOOL)killApp:(NSString *)bundleID pid:(pid_t)pid;
/// 当前可用内存（MB）
+ (double)freeMemoryMB;
/// 当前已用内存（MB）
+ (double)usedMemoryMB;
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
@end

#pragma mark - 一键加速

@interface RBBooster : NSObject
/// 批量结束后台进程。protect: 不杀的 bundleID（真后台白名单）
/// 返回 @{@"killed": @(n), @"freedMB": @(x), @"skipped": @(y), @"details": @[...]}
+ (NSDictionary *)boostProtecting:(NSSet *)protect;
/// 预估可释放内存
+ (double)estimatedReclaimMB;
/// 可清理候选（按占用内存降序），元素：@{bundleID, pid, mb}
+ (NSArray<NSDictionary *> *)candidatesProtecting:(NSSet *)protect;
/// 单个进程的真实物理占用（phys_footprint，MB）
+ (double)footprintMBForPid:(pid_t)pid;
@end

#pragma mark - UI

@interface RBRootVC : UIViewController
@end

#pragma mark - 工具

FOUNDATION_EXPORT void RBLog(NSString *fmt, ...);
FOUNDATION_EXPORT NSString *RBHumanMB(double mb);
