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

- (void)reload {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:RBPrefsPath()];
    if (!d) {
        // 兼容：原版 1.5 的配置放在 com.thefool.app.plist，能读到就迁过来
        NSString *legacy = [RB_PREFS_DIR stringByAppendingPathComponent:@"com.thefool.app.plist"];
        d = [NSDictionary dictionaryWithContentsOfFile:legacy];
        if (d) RBLog(@"从原版配置迁移：%@", legacy);
    }
    if (![d isKindOfClass:[NSDictionary class]]) return;

    self.backstageIDs = [NSMutableSet setWithArray:d[@"WhiteList"] ?: @[]];
    self.autoStartIDs = [NSMutableSet setWithArray:d[@"AutoStart"] ?: @[]];
    self.suicideIDs  = [NSMutableSet setWithArray:d[@"SuicideList"] ?: @[]];
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
