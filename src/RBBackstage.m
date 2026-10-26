//
//  RBBackstage.m — 真后台
//
//  从 1.5 原包还原出来的实现路径（方法名与调用序均来自静态分析）：
//      FBSMutableSceneDefinition.definition
//        identity      = [FBSSceneIdentity identityForIdentifier:...]
//        clientIdentity= [FBSSceneClientIdentity identityForEmbeddedApplicationIdentifier:<bid>]
//        specification = [UIApplicationSceneSpecification specification]
//      FBMutableSceneParameters.parametersForSpecification:
//        settings      = UIMutableApplicationSceneSettings(foreground=YES, ignoreOcclusionReasons)
//        clientSettings= UIMutableApplicationSceneClientSettings
//      [FBSceneManager.sharedInstance createSceneWithDefinition:initialParameters:]
//      [UIRootWindowScenePresentationBinder addScene:]   <- 把别人的 scene 挂到自己窗口上
//
//  挂上之后 FrontBoard 认为该 App 正在前台渲染，于是不会因切后台被挂起。
//  scene 方案失败时退回 RunningBoard 的 Background 断言（保活，但 UI 状态可能被丢）。
//
#import "RB.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <signal.h>
#import <errno.h>

#pragma mark - 私有接口声明（只声明，不链接头文件）

@interface FBSSceneIdentity : NSObject
+ (instancetype)identityForIdentifier:(NSString *)identifier;
@end

@interface FBSSceneClientIdentity : NSObject
+ (instancetype)identityForEmbeddedApplicationIdentifier:(NSString *)bundleID;
+ (instancetype)localIdentity;
@end

@interface FBSMutableSceneDefinition : NSObject
+ (instancetype)definition;
@property (nonatomic, copy) id identity;
@property (nonatomic, copy) id clientIdentity;
@property (nonatomic, copy) id specification;
@property (nonatomic, copy) NSString *workspaceIdentifier;
@end

@interface FBMutableSceneParameters : NSObject
+ (instancetype)parametersForSpecification:(id)spec;
@property (nonatomic, copy) id settings;
@property (nonatomic, copy) id clientSettings;
@end

@interface FBSceneManager : NSObject
+ (instancetype)sharedInstance;
- (id)createSceneWithDefinition:(id)def initialParameters:(id)params;
- (void)destroyScene:(id)scene withTransitionContext:(id)ctx;
@end

@interface UIRootWindowScenePresentationBinder : NSObject
- (instancetype)initWithPriority:(long long)priority displayConfiguration:(id)config;
- (void)addScene:(id)scene;
- (void)removeScene:(id)scene;
- (NSArray *)scenes;
@end

@interface RBSDomainAttribute : NSObject
+ (instancetype)attributeWithDomain:(NSString *)domain name:(NSString *)name;
@end

@interface RBSTarget : NSObject
+ (instancetype)targetWithPid:(pid_t)pid;
@end

@interface RBSAssertion : NSObject
- (instancetype)initWithExplanation:(NSString *)explanation
                             target:(RBSTarget *)target
                         attributes:(NSArray *)attributes;
- (BOOL)acquireWithError:(NSError **)error;
- (void)invalidate;
@end

#pragma mark - 安全调用小工具

static id RBMsg0(id obj, NSString *selName) {
    if (!obj) return nil;
    SEL s = NSSelectorFromString(selName);
    if (![obj respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, s);
}

static id RBMsg1(id obj, NSString *selName, id a) {
    if (!obj) return nil;
    SEL s = NSSelectorFromString(selName);
    if (![obj respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(obj, s, a);
}

static BOOL RBIsAlive(pid_t pid) {
    if (pid <= 0) return NO;
    return kill(pid, 0) == 0 || errno == EPERM;
}

#pragma mark - hook：让挂上来的 scene 窗口盖在正常层级之上
//
//  这里不能给 UIRootSceneWindow 写 @implementation —— 那个类由 UIKit 提供，
//  自己实现一个同名类会和系统类打架。
//  也不能简单 method_exchangeImplementations：windowLevel / _canShowWhileLocked 如果
//  是 UIRootSceneWindow 从 UIWindow 继承来的，class_getInstanceMethod 返回的是
//  父类的方法，换 IMP 等于把整个进程所有 UIWindow 的层级都改了（弹窗、键盘一起遭殃）。
//  正确做法：先 class_addMethod 给子类补一份自己的实现；只有子类本来就实现了，
//  才动它自己的 IMP。这样影响范围严格限制在 UIRootSceneWindow 实例上。

static double RBHookWindowLevel(id self, SEL _cmd) { return 10000000.0; }
static BOOL   RBHookCanShowWhileLocked(id self, SEL _cmd) { return YES; }

static void RBInstallHookOn(Class cls, NSString *selName, IMP imp, const char *fallbackTypes) {
    if (!cls) return;
    SEL sel = NSSelectorFromString(selName);

    Method own = class_getInstanceMethod(cls, sel);
    const char *types = own ? method_getTypeEncoding(own) : fallbackTypes;
    if (!types) return;

    if (class_addMethod(cls, sel, imp, types)) return;          // 子类此前只有继承实现

    // 子类自己实现了：直接改它自己的 IMP（不会波及父类）
    Method m = class_getInstanceMethod(cls, sel);
    if (m && method_getImplementation(m) != imp) {
        method_setImplementation(m, imp);
    }
}

/// 注意：这里原来是 __attribute__((constructor))，也就是在 main 之前就跑。
/// 那是最危险的时机 —— 当时 UIKit 还没完成自己的 +load / 初始化，去 NSClassFromString
/// 摸它的私有类、再 class_addMethod 改方法表，任何一点意外都是「打开即闪退」，
/// 而且崩在 pre-main，连崩溃日志都来不及装。
/// 改成懒加载：第一次真的要挂 scene 时才装，那时 UIKit 早就准备好了。
static void RBInstallSceneWindowHooksIfNeeded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"UIRootSceneWindow");
        if (!cls) {
            RBLog(@"UIRootSceneWindow 不存在，跳过层级 hook（iOS 版本差异）");
            return;
        }
        RBInstallHookOn(cls, @"windowLevel", (IMP)RBHookWindowLevel, "d16@0:8");
        RBInstallHookOn(cls, @"_canShowWhileLocked", (IMP)RBHookCanShowWhileLocked, "B16@0:8");
        RBLog(@"scene 窗口层级 hook 已安装：%@", cls);
    });
}

#pragma mark -

@interface RBBackstage ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *scenes;      // bid -> FBScene
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *assertions;  // bid -> RBSAssertion
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *pids; // bid -> pid
@property (nonatomic, strong) id binder;
/// v1.4.2：scene / assertion 各自失败到最后一步的原因，弹窗直接告诉用户，
/// 不再只给一句「scene 与 assertion 都失败了」让人干瞪眼。
@property (nonatomic, copy) NSString *lastSceneReason;
@property (nonatomic, copy) NSString *lastAssertionReason;
@end

@implementation RBBackstage

+ (instancetype)shared {
    static RBBackstage *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [RBBackstage new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _scenes = [NSMutableDictionary dictionary];
        _assertions = [NSMutableDictionary dictionary];
        _pids = [NSMutableDictionary dictionary];
    }
    return self;
}

- (id)ensureBinder {
    if (self.binder) return self.binder;
    Class cls = NSClassFromString(@"UIRootWindowScenePresentationBinder");
    if (!cls) {
        RBLog(@"UIRootWindowScenePresentationBinder 不可用（系统版本不支持）");
        return nil;
    }
    @try {
        id screen = [UIScreen mainScreen];
        id config = RBMsg0(screen, @"displayConfiguration") ?: RBMsg0(screen, @"_displayConfiguration");
        if (!config) {
            RBLog(@"取不到 displayConfiguration，binder 不创建");
            return nil;
        }
        SEL initSel = NSSelectorFromString(@"initWithPriority:displayConfiguration:");
        if ([cls instancesRespondToSelector:initSel]) {
            id binder = ((id (*)(id, SEL, long long, id))objc_msgSend)(
                ((id (*)(id, SEL))objc_msgSend)(cls, @selector(alloc)), initSel, 0, config);
            self.binder = binder;
        }
    } @catch (NSException *e) {
        RBLog(@"binder 创建失败：%@", e.reason);
    }
    return self.binder;
}

/// 已记录的目标进程如果已经退出（用户手动杀了 / 系统回收了），旧 scene 就是死的，
/// 必须先清掉再重新挂，否则 isEnabled 会一直返回 YES 但实际没保护。
- (void)dropIfStale:(NSString *)bundleID {
    NSNumber *p = nil;
    @synchronized (self) { p = self.pids[bundleID]; }
    if (!p) return;
    if (RBIsAlive((pid_t)p.intValue)) return;
    RBLog(@"目标进程已退出，清理旧记录：%@", bundleID);
    [self disableForBundle:bundleID];
}

- (BOOL)enableForBundle:(NSString *)bundleID pid:(pid_t)pid error:(NSError **)error {
    if (bundleID.length == 0) return NO;
    [self dropIfStale:bundleID];
    @synchronized (self) {
        if (self.scenes[bundleID] || self.assertions[bundleID]) return YES;
    }

    BOOL ok = [self attachSceneFor:bundleID];
    if (!ok) ok = [self acquireAssertionFor:bundleID pid:pid];

    if (ok) {
        pid_t real = pid > 0 ? pid : [[RBProcesses runningPids][bundleID] intValue];
        @synchronized (self) { self.pids[bundleID] = @(real); }
        return YES;
    }
    if (error) {
        NSString *why = [NSString stringWithFormat:@"scene：%@；assertion：%@",
                         self.lastSceneReason ?: @"未知",
                         self.lastAssertionReason ?: @"未知"];
        *error = [NSError errorWithDomain:@"RealBG" code:1
                                 userInfo:@{NSLocalizedDescriptionKey: why}];
    }
    return NO;
}

- (BOOL)attachSceneFor:(NSString *)bundleID {
    RBInstallSceneWindowHooksIfNeeded();
    Class defCls = NSClassFromString(@"FBMutableSceneDefinition");
    Class idCls = NSClassFromString(@"FBSSceneIdentity");
    Class cidCls = NSClassFromString(@"FBSSceneClientIdentity");
    Class parCls = NSClassFromString(@"FBMutableSceneParameters");
    Class mgrCls = NSClassFromString(@"FBSceneManager");
    Class specCls = NSClassFromString(@"UIApplicationSceneSpecification");
    Class setCls = NSClassFromString(@"UIMutableApplicationSceneSettings");
    Class csetCls = NSClassFromString(@"UIMutableApplicationSceneClientSettings");
    if (!defCls || !mgrCls || !specCls || !parCls) {
        RBLog(@"FrontBoard scene 相关类缺失");
        self.lastSceneReason = @"FrontBoard scene 相关类缺失（iOS 版本差异）";
        return NO;
    }

    id scene = nil;
    @try {
        NSString *sceneID = [NSString stringWithFormat:@"realbg.%@", bundleID];

        id def = RBMsg0(defCls, @"definition");
        if (!def) {
            self.lastSceneReason = @"+definition 取不到（FBSMutableSceneDefinition 变了）";
            return NO;
        }
        [def setValue:RBMsg1(idCls, @"identityForIdentifier:", sceneID) forKey:@"identity"];
        [def setValue:RBMsg1(cidCls, @"identityForEmbeddedApplicationIdentifier:", bundleID)
               forKey:@"clientIdentity"];
        id spec = RBMsg0(specCls, @"specification");
        if (!spec) {
            RBLog(@"UIApplicationSceneSpecification 取不到");
            self.lastSceneReason = @"UIApplicationSceneSpecification 取不到";
            return NO;
        }
        [def setValue:spec forKey:@"specification"];

        id params = RBMsg1(parCls, @"parametersForSpecification:", spec);
        if (!params) {
            self.lastSceneReason = @"parametersForSpecification: 返回 nil";
            return NO;
        }

        // settings：让它以「前台」姿态运行，并忽略遮挡导致的降级
        if (setCls) {
            id settings = RBMsg0(RBMsg0(setCls, @"alloc"), @"init");
            @try { [settings setValue:@YES forKey:@"foreground"]; } @catch (NSException *e) {}
            @try { [settings setValue:@YES forKey:@"ignoreOcclusionReasons"]; } @catch (NSException *e) {}
            @try { [settings setValue:@(0) forKey:@"interfaceOrientation"]; } @catch (NSException *e) {}
            if (settings) [params setValue:settings forKey:@"settings"];
        }
        if (csetCls) {
            id cs = RBMsg0(RBMsg0(csetCls, @"alloc"), @"init");
            if (cs) [params setValue:cs forKey:@"clientSettings"];
        }

        id mgr = RBMsg0(mgrCls, @"sharedInstance");
        if (!mgr) {
            self.lastSceneReason = @"FBSceneManager.sharedInstance 取不到";
            return NO;
        }
        scene = ((id (*)(id, SEL, id, id))objc_msgSend)(
            mgr, NSSelectorFromString(@"createSceneWithDefinition:initialParameters:"), def, params);
        if (!scene) {
            RBLog(@"createScene 返回 nil：%@", bundleID);
            self.lastSceneReason = @"createScene 返回 nil";
            return NO;
        }

        id binder = [self ensureBinder];
        if (!binder || ![binder respondsToSelector:NSSelectorFromString(@"addScene:")]) {
            RBLog(@"binder 不可用，scene 无法上屏（回收刚创建的 scene）");
            self.lastSceneReason = @"窗口 binder 不可用，scene 挂不上屏";
            [self destroyScene:scene];          // 不回收就是一条泄漏的 scene
            return NO;
        }
        ((void (*)(id, SEL, id))objc_msgSend)(binder, NSSelectorFromString(@"addScene:"), scene);

        @synchronized (self) { self.scenes[bundleID] = scene; }
        RBLog(@"真后台(scene) 已挂载：%@", bundleID);
        return YES;
    } @catch (NSException *e) {
        RBLog(@"scene 方案异常：%@ %@", e.name, e.reason);
        self.lastSceneReason = [NSString stringWithFormat:@"异常：%@", e.reason];
        if (scene) [self destroyScene:scene];
        return NO;
    }
}

- (void)destroyScene:(id)scene {
    Class mgrCls = NSClassFromString(@"FBSceneManager");
    id mgr = RBMsg0(mgrCls, @"sharedInstance");
    if (!mgr) return;
    SEL sel = NSSelectorFromString(@"destroyScene:withTransitionContext:");
    if (![mgr respondsToSelector:sel]) return;
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, sel, scene, nil);
    } @catch (NSException *e) {
        RBLog(@"销毁 scene 异常：%@", e.reason);
    }
}

- (BOOL)acquireAssertionFor:(NSString *)bundleID pid:(pid_t)pid {
    if (pid <= 0) {
        pid = [[RBProcesses runningPids][bundleID] intValue];
    }
    if (pid <= 0) {
        self.lastAssertionReason = @"拿不到目标进程 pid（先打开它再开真后台）";
        return NO;
    }

    Class attrCls = NSClassFromString(@"RBSDomainAttribute");
    Class tgtCls = NSClassFromString(@"RBSTarget");
    Class asCls = NSClassFromString(@"RBSAssertion");
    if (!attrCls || !tgtCls || !asCls) {
        self.lastAssertionReason = @"RunningBoard 类不可用";
    } else {
        @try {
            id attr = ((id (*)(id, SEL, id, id))objc_msgSend)(
                attrCls, NSSelectorFromString(@"attributeWithDomain:name:"),
                @"com.apple.frontboard", @"Background");
            id target = ((id (*)(id, SEL, int))objc_msgSend)(tgtCls, NSSelectorFromString(@"targetWithPid:"), pid);
            id assertion = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
                ((id (*)(id, SEL))objc_msgSend)(asCls, @selector(alloc)),
                NSSelectorFromString(@"initWithExplanation:target:attributes:"),
                [NSString stringWithFormat:@"RealBG backstage for %@", bundleID],
                target, @[attr]);
            NSError *err = nil;
            BOOL ok = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(
                assertion, NSSelectorFromString(@"acquireWithError:"), &err);
            if (ok) {
                @synchronized (self) { self.assertions[bundleID] = assertion; }
                RBLog(@"真后台(assertion) 已保活：%@", bundleID);
                self.lastAssertionReason = nil;
                return YES;
            }
            RBLog(@"assertion 获取失败：%@", err.localizedDescription);
            self.lastAssertionReason = [NSString stringWithFormat:@"RunningBoard 拒绝：%@",
                                        err.localizedDescription ?: @"未知"];
        } @catch (NSException *e) {
            RBLog(@"assertion 异常：%@", e.reason);
            self.lastAssertionReason = [NSString stringWithFormat:@"RunningBoard 异常：%@", e.reason];
        }
    }

    // v1.4.2：RBS 拒绝（权限/域声明问题）时退回老的 BKSProcessAssertion ——
    // 这是 RunningBoard 出现之前 FrontBoard 就有的断言接口，走 backboardd，
    // 对目标 pid 同样有效。RBS 的原因（域声明）修好后走不到这里。
    @try {
        Class bks = NSClassFromString(@"BKSProcessAssertion");
        if (!bks) return NO;
        id raw = ((id (*)(id, SEL))objc_msgSend)((id)bks, @selector(alloc));
        SEL s = NSSelectorFromString(@"initWithPID:flags:reason:name:");
        if (![raw respondsToSelector:s]) {
            RBLog(@"BKS 接口签名变了，断言兜底不可用");
            return NO;
        }
        id a = ((id (*)(id, SEL, int, unsigned int, unsigned int, id))objc_msgSend)(
            raw, s, (int)pid, (unsigned int)0x1F, (unsigned int)1,
            [NSString stringWithFormat:@"RealBG backstage %@", bundleID]);
        SEL ac = NSSelectorFromString(@"acquire");
        if (![a respondsToSelector:ac]) return NO;
        ((void (*)(id, SEL))objc_msgSend)(a, ac);
        @synchronized (self) { self.assertions[bundleID] = a; }
        self.lastAssertionReason = nil;
        RBLog(@"真后台(BKS assertion) 已保活：%@ pid=%d", bundleID, pid);
        return YES;
    } @catch (NSException *e) {
        RBLog(@"BKS assertion 异常：%@", e.reason);
        return NO;
    }
}

- (void)disableForBundle:(NSString *)bundleID {
    if (bundleID.length == 0) return;

    id scene = nil, assertion = nil;
    @synchronized (self) {
        scene = self.scenes[bundleID];
        assertion = self.assertions[bundleID];
    }

    if (scene) {
        id binder = self.binder;
        if (binder && [binder respondsToSelector:NSSelectorFromString(@"removeScene:")]) {
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(binder, NSSelectorFromString(@"removeScene:"), scene);
            } @catch (NSException *e) {}
        }
        [self destroyScene:scene];
        @synchronized (self) { [self.scenes removeObjectForKey:bundleID]; }
    }
    if (assertion) {
        @try { ((void (*)(id, SEL))objc_msgSend)(assertion, NSSelectorFromString(@"invalidate")); }
        @catch (NSException *e) {}
        @synchronized (self) { [self.assertions removeObjectForKey:bundleID]; }
    }
    @synchronized (self) { [self.pids removeObjectForKey:bundleID]; }
}

- (BOOL)isEnabledForBundle:(NSString *)bundleID {
    [self dropIfStale:bundleID];
    return [self levelForBundle:bundleID] > 0;
}

/// 2 = 场景，1 = 仅断言，0 = 没挂上。
/// 这两者不是一回事：断言只向 RunningBoard 声明「别回收这个进程」，
/// 系统照样能把它挂起；场景是让 FrontBoard 认为它在前台渲染，才真的不停顿。
/// 界面如果只显示「真后台」，降级成断言时就等于在骗用户。
- (NSInteger)levelForBundle:(NSString *)bundleID {
    if (bundleID.length == 0) return 0;
    @synchronized (self) {
        if (self.scenes[bundleID]) return 2;
        if (self.assertions[bundleID]) return 1;
        return 0;
    }
}

- (NSDictionary<NSString *, NSNumber *> *)levelSnapshot {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    @synchronized (self) {
        for (NSString *bid in self.assertions) d[bid] = @(1);
        for (NSString *bid in self.scenes) d[bid] = @(2);
    }
    return d;
}

- (NSArray<NSString *> *)enabledBundles {
    NSMutableSet *s = [NSMutableSet set];
    @synchronized (self) {
        [s addObjectsFromArray:self.scenes.allKeys];
        [s addObjectsFromArray:self.assertions.allKeys];
    }
    return s.allObjects;
}

+ (void)releaseOwnedBackstage {
    RBBackstage *bs = [RBBackstage shared];
    NSArray *own = [bs enabledBundles];
    for (NSString *bid in own) {
        @autoreleasepool {
            [bs disableForBundle:bid];
        }
    }
    if (own.count) RBLog(@"已撤销 %lu 个自挂保活", (unsigned long)own.count);
}

@end
