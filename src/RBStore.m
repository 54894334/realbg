//
//  RBStore.m — 配置持久化
//
//  原包的 bug：配置路径写死成 com.thefool.app.plist（不是自己的 bundle id），
//  所以两个不同的工具会互相覆盖配置。这里改回自己的 bundle id。
//
//  四份名单：
//    WhiteList   真后台（开着的 App 会被保活）
//    AutoStart   自启（下次开本 App 时自动恢复真后台）
//    SuicideList 退出即杀（本 App 退到后台时结束）
//    LockList    保留名单（加速/清理永不碰）—— 与其它三项冲突时，锁定优先
//
#import "RB.h"

static NSString *RBPrefsPath(void) {
    return [RB_PREFS_DIR stringByAppendingPathComponent:RB_PREFS_NAME];
}

@implementation RBStore

+ (instancetype)shared {
    static RBStore *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [RBStore new];
        [s reload];
    });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _backstageIDs = [NSMutableSet set];
        _autoStartIDs = [NSMutableSet set];
        _suicideIDs   = [NSMutableSet set];
        _lockIDs      = [NSMutableSet set];
    }
    return self;
}

/// 只接受「非空字符串」组成的数组。plist 被写坏、或被别的进程改成字符串/字典时，
/// setWithArray: 会直接抛 NSInvalidArgumentException 把 App 崩在启动阶段。
static NSSet *RBSanitizeSet(id raw) {
    if (![raw isKindOfClass:[NSArray class]]) return [NSSet set];
    NSMutableSet *out = [NSMutableSet set];
    for (id v in (NSArray *)raw) {
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0 && [(NSString *)v length] < 256) {
            [out addObject:v];
        }
    }
    return out;
}

- (void)reload {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:RBPrefsPath()];
    if (![d isKindOfClass:[NSDictionary class]]) {
        // 兼容：原版 1.5 的配置放在 com.thefool.app.plist，能读到就迁过来（只读，不写回）
        NSString *legacy = [RB_PREFS_DIR stringByAppendingPathComponent:@"com.thefool.app.plist"];
        d = [NSDictionary dictionaryWithContentsOfFile:legacy];
        if ([d isKindOfClass:[NSDictionary class]]) RBLog(@"从原版配置迁移：%@", legacy);
    }
    if (![d isKindOfClass:[NSDictionary class]]) return;

    self.backstageIDs  = [RBSanitizeSet(d[@"WhiteList"]) mutableCopy];
    self.autoStartIDs  = [RBSanitizeSet(d[@"AutoStart"]) mutableCopy];
    self.suicideIDs    = [RBSanitizeSet(d[@"SuicideList"]) mutableCopy];
    self.lockIDs       = [RBSanitizeSet(d[@"LockList"]) mutableCopy];
    self.boostOnLaunch = [d[@"BoostOnLaunch"] boolValue];
}

- (void)save {
    NSDictionary *d = @{
        @"WhiteList":    self.backstageIDs.allObjects ?: @[],
        @"AutoStart":    self.autoStartIDs.allObjects ?: @[],
        @"SuicideList":  self.suicideIDs.allObjects ?: @[],
        @"LockList":     self.lockIDs.allObjects ?: @[],
        @"BoostOnLaunch": @(self.boostOnLaunch),
        @"Version":      RB_VERSION,
    };
    NSString *path = RBPrefsPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:RB_PREFS_DIR
                             withIntermediateDirectories:YES attributes:nil error:NULL];
    if (![d writeToFile:path atomically:YES]) {
        RBLog(@"配置写入失败：%@", path);
    }
}

/// 真后台名单 + 保留名单合并。加速与退出清理都拿这一份，避免两处各写一遍、
/// 以后改一处漏一处。
- (NSSet *)allProtectedIDs {
    NSMutableSet *s = [NSMutableSet setWithSet:self.backstageIDs ?: [NSSet set]];
    [s unionSet:self.lockIDs ?: [NSSet set]];
    [s addObject:RB_BUNDLE];
    return s;
}

@end
