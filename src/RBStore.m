//
//  RBStore.m — 配置持久化
//
//  原包的 bug：配置路径写死成 com.thefool.app.plist（不是自己的 bundle id），
//  所以两个不同的工具会互相覆盖配置。这里改回自己的 bundle id。
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
        _suicideIDs = [NSMutableSet set];
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
    self.boostOnLaunch = [d[@"BoostOnLaunch"] boolValue];
}

- (void)save {
    NSDictionary *d = @{
        @"WhiteList":    self.backstageIDs.allObjects ?: @[],
        @"AutoStart":    self.autoStartIDs.allObjects ?: @[],
        @"SuicideList":  self.suicideIDs.allObjects ?: @[],
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

@end

#pragma mark - 工具

void RBLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[RealBG] %@", s);
}

NSString *RBHumanMB(double mb) {
    if (mb >= 1024) return [NSString stringWithFormat:@"%.1f GB", mb / 1024.0];
    return [NSString stringWithFormat:@"%.0f MB", mb];
}
