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

#pragma mark - hook：让挂上来的 scene 窗口盖在正常层级之上
//
//  注意：这里不能给 UIRootSceneWindow 写 @implementation —— 那个类由 UIKit 提供，
//  自己实现一个同名类会和系统类打架（甚至把系统类顶掉）。用「替身类交换 IMP」的写法：
//  把替身类上的方法实现换给系统类，替身类本身不会被实例化。

@interface RBSceneWindowHook : NSObject
- (double)rb_windowLevel;
- (BOOL)rb_canShowWhileLocked;
@end

@implementation RBSceneWindowHook
- (double)rb_windowLevel { return 10000000.0; }
- (BOOL)rb_canShowWhileLocked { return YES; }
@end

__attribute__((constructor))
static void RBInstallSceneWindowHooks(void) {
    Class cls = NSClassFromString(@"UIRootSceneWindow");
    if (!cls) return;
    Method m1 = class_getInstanceMethod(cls, @selector(windowLevel));
    Method m2 = class_getInstanceMethod([RBSceneWindowHook class], @selector(rb_windowLevel));
    if (m1 && m2) method_exchangeImplementations(m1, m2);

    Method m3 = class_getInstanceMethod(cls, @selector(_canShowWhileLocked));
    Method m4 = class_getInstanceMethod([RBSceneWindowHook class], @selector(rb_canShowWhileLocked));
    if (m3 && m4) method_exchangeImplementations(m3, m4);
    RBLog(@"scene 窗口层级 hook 已安装：%@", cls);
}

#pragma mark -

@interface RBBackstage ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *scenes;      // bid -> FBScene
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *assertions;  // bid -> RBSAssertion
@property (nonatomic, strong) id binder;
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
        id config = nil;
        Class screenCls = NSClassFromString(@"UIScreen");
        if ([screenCls respondsToSelector:NSSelectorFromString(@"displayConfiguration")]) {
            config = ((id (*)(id, SEL))objc_msgSend)([UIScreen mainScreen], NSSelectorFromString(@"displayConfiguration"));
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

- (BOOL)enableForBundle:(NSString *)bundleID pid:(pid_t)pid error:(NSError **)error {
    if (bundleID.length == 0) return NO;
    if (self.scenes[bundleID] || self.assertions[bundleID]) return YES;

    if ([self attachSceneFor:bundleID]) {
        RBLog(@"真后台(scene) 已挂载：%@", bundleID);
        return YES;
    }
    if ([self acquireAssertionFor:bundleID pid:pid]) {
        RBLog(@"真后台(assertion) 已保活：%@", bundleID);
        return YES;
    }
    if (error) {
        *error = [NSError errorWithDomain:@"RealBG" code:1
                                 userInfo:@{NSLocalizedDescriptionKey: @"scene 与 assertion 都失败了"}];
    }
    return NO;
}

- (BOOL)attachSceneFor:(NSString *)bundleID {
    Class defCls = NSClassFromString(@"FBMutableSceneDefinition");
    Class idCls = NSClassFromString(@"FBSSceneIdentity");
    Class cidCls = NSClassFromString(@"FBSSceneClientIdentity");
    Class parCls = NSClassFromString(@"FBMutableSceneParameters");
    Class mgrCls = NSClassFromString(@"FBSceneManager");
    Class specCls = NSClassFromString(@"UIApplicationSceneSpecification");
    Class setCls = NSClassFromString(@"UIMutableApplicationSceneSettings");
    Class csetCls = NSClassFromString(@"UIMutableApplicationSceneClientSettings");
    if (!defCls || !mgrCls || !specCls) {
        RBLog(@"FrontBoard scene 相关类缺失");
        return NO;
    }

    @try {
        NSString *sceneID = [NSString stringWithFormat:@"realbg.%@", bundleID];

        id def = ((id (*)(id, SEL))objc_msgSend)(defCls, NSSelectorFromString(@"definition"));
        if (!def) return NO;
        [def setValue:((id (*)(id, SEL, id))objc_msgSend)(idCls, NSSelectorFromString(@"identityForIdentifier:"), sceneID)
               forKey:@"identity"];
        [def setValue:((id (*)(id, SEL, id))objc_msgSend)(cidCls, NSSelectorFromString(@"identityForEmbeddedApplicationIdentifier:"), bundleID)
               forKey:@"clientIdentity"];
        id spec = ((id (*)(id, SEL))objc_msgSend)(specCls, NSSelectorFromString(@"specification"));
        [def setValue:spec forKey:@"specification"];

        id params = ((id (*)(id, SEL, id))objc_msgSend)(parCls, NSSelectorFromString(@"parametersForSpecification:"), spec);
        if (!params) return NO;

        // settings：让它以「前台」姿态运行，并忽略遮挡导致的降级
        if (setCls) {
            id settings = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)(setCls, @selector(alloc)), @selector(init));
            @try { [settings setValue:@YES forKey:@"foreground"]; } @catch (NSException *e) {}
            @try { [settings setValue:@YES forKey:@"ignoreOcclusionReasons"]; } @catch (NSException *e) {}
            @try { [settings setValue:@(0) forKey:@"interfaceOrientation"]; } @catch (NSException *e) {}
            if (settings) [params setValue:settings forKey:@"settings"];
        }
        if (csetCls) {
            id cs = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)(csetCls, @selector(alloc)), @selector(init));
            if (cs) [params setValue:cs forKey:@"clientSettings"];
        }

        id mgr = ((id (*)(id, SEL))objc_msgSend)(mgrCls, NSSelectorFromString(@"sharedInstance"));
        id scene = ((id (*)(id, SEL, id, id))objc_msgSend)(
            mgr, NSSelectorFromString(@"createSceneWithDefinition:initialParameters:"), def, params);
        if (!scene) {
            RBLog(@"createScene 返回 nil：%@", bundleID);
            return NO;
        }

        id binder = [self ensureBinder];
        if (!binder || ![binder respondsToSelector:NSSelectorFromString(@"addScene:")]) {
            RBLog(@"binder 不可用，scene 无法上屏");
            return NO;
        }
        ((void (*)(id, SEL, id))objc_msgSend)(binder, NSSelectorFromString(@"addScene:"), scene);

        self.scenes[bundleID] = scene;
        return YES;
    } @catch (NSException *e) {
        RBLog(@"scene 方案异常：%@ %@", e.name, e.reason);
        return NO;
    }
}

- (BOOL)acquireAssertionFor:(NSString *)bundleID pid:(pid_t)pid {
    if (pid <= 0) {
        pid = [[RBProcesses runningPids][bundleID] intValue];
    }
    if (pid <= 0) return NO;

    Class attrCls = NSClassFromString(@"RBSDomainAttribute");
    Class tgtCls = NSClassFromString(@"RBSTarget");
    Class asCls = NSClassFromString(@"RBSAssertion");
    if (!attrCls || !tgtCls || !asCls) return NO;

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
            self.assertions[bundleID] = assertion;
        } else {
            RBLog(@"assertion 获取失败：%@", err.localizedDescription);
        }
        return ok;
    } @catch (NSException *e) {
        RBLog(@"assertion 异常：%@", e.reason);
        return NO;
    }
}

- (void)disableForBundle:(NSString *)bundleID {
    id scene = self.scenes[bundleID];
    if (scene) {
        @try {
            id binder = self.binder;
            if (binder && [binder respondsToSelector:NSSelectorFromString(@"removeScene:")]) {
                ((void (*)(id, SEL, id))objc_msgSend)(binder, NSSelectorFromString(@"removeScene:"), scene);
            }
            Class mgrCls = NSClassFromString(@"FBSceneManager");
            id mgr = ((id (*)(id, SEL))objc_msgSend)(mgrCls, NSSelectorFromString(@"sharedInstance"));
            ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, NSSelectorFromString(@"destroyScene:withTransitionContext:"), scene, nil);
        } @catch (NSException *e) {
            RBLog(@"销毁 scene 异常：%@", e.reason);
        }
        [self.scenes removeObjectForKey:bundleID];
    }
    id assertion = self.assertions[bundleID];
    if (assertion) {
        @try { ((void (*)(id, SEL))objc_msgSend)(assertion, NSSelectorFromString(@"invalidate")); }
        @catch (NSException *e) {}
        [self.assertions removeObjectForKey:bundleID];
    }
}

- (BOOL)isEnabledForBundle:(NSString *)bundleID {
    return self.scenes[bundleID] != nil || self.assertions[bundleID] != nil;
}

- (NSArray<NSString *> *)enabledBundles {
    NSMutableSet *s = [NSMutableSet setWithArray:self.scenes.allKeys];
    [s addObjectsFromArray:self.assertions.allKeys];
    return s.allObjects;
}

@end
