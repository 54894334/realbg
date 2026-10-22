//
//  RBProcesses.m — 应用枚举 / 进程枚举 / 杀进程 / 内存统计
//
//  原包这一层用了 task_for_pid + processor_set_tasks，也就是「拿到全系统所有
//  进程的 task 端口」——那是能读写任意 App 内存的能力，对「杀后台」这件事完全
//  没有必要。这里全部换成公开的 proc_listpids + proc_pidpath + kill()。
//
//  私有框架一律用 NSClassFromString 动态取类，不在链接期引用别家符号：
//  这样 SDK 里有没有 PrivateFrameworks 的 .tbd 都能编过、都能跑。
//
//  1.1.0 修掉的两处会直接闪退 / 让功能整体失效的问题：
//    · iconForPath 对 CFBundleIconFiles 的元素直接 .pathExtension —— 有的 App
//      这一项是 NSNumber，取到就 unrecognized selector。这段还在任何 @try 之外，
//      而 reload 在 viewDidLoad 就会在后台线程跑它 → 打开即闪退。
//    · bundleIDForPid 截路径时少加了 marker 的长度，截出来的永远是错位路径，
//      读不到 Info.plist，只能退化成用目录名当 bundleID → 「运行中」全部失效。
//
#import "RB.h"
#import "rbproc.h"
#import <signal.h>
#import <string.h>
#import <unistd.h>
#import <errno.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <mach/host_info.h>
#import <mach/vm_statistics.h>
#import <objc/message.h>

// 系统自带的、杀了会影响使用的进程/应用
static NSSet *RBProtectedBundleIDs(void) {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"com.apple.springboard",
            @"com.apple.Preferences",
            @"com.apple.mobilesafari",
            @"com.apple.mobilephone",
            @"com.apple.MobileSMS",
            @"com.apple.InCallService",
            @"com.apple.mobiletimer",
            @"com.apple.calculator",
            @"com.apple.Maps",
            @"com.apple.camera",
            @"com.apple.Passbook",
            @"com.apple.AppStore",
            @"com.apple.Music",
            @"com.apple.videos",
            @"com.apple.Photos",
            @"com.apple.MobileAddressBook",
            @"com.apple.Health",
            @"com.apple.DocumentsApp",
            @"com.apple.shortcuts",
            @"com.apple.mobilecal",
            @"com.apple.reminders",
            @"com.apple.news",
            @"com.apple.podcasts",
            @"com.apple.tv",
            @"com.apple.facetime",
            @"com.apple.Bridge",
            @"com.apple.SleepLockScreen",
            @"cn.bswbw.RealBG",
        ]];
    });
    return s;
}

/// 系统 App 一律不动 —— 白名单只能枚举有限个，系统 App 会随 iOS 版本增减，
/// 按前缀整片拦掉比逐个维护清单可靠。
static BOOL RBIsSystemBundle(NSString *bid) {
    if (bid.length == 0) return YES;
    return [bid hasPrefix:@"com.apple."] || [bid isEqualToString:@"cn.bswbw.RealBG"];
}

// 绝不能碰的系统守护进程（按可执行文件名判断）
static NSSet *RBProtectedExecNames(void) {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"launchd", @"SpringBoard", @"backboardd", @"runningboardd",
            @"frontboardd", @"securityd", @"configd", @"UserEventAgent",
            @"powerd", @"wifid", @"CommCenter", @"mediaserverd",
            @"sharingd", @"assertiond", @"lsd", @"installd", @"mobileassetd",
            @"nehelper", @"networkd", @"symptomsd", @"watchdogd",
            @"locationd", @"aggregated", @"identityservicesd", @"apsd",
            @"tccd", @"containermanagerd", @"siriknowledged",
            @"corespeechd", @"AudioSessionServer", @"distnoted",
            @"cfprefsd", @"logd", @"syslogd", @"kernelmanagerd",
        ]];
    });
    return s;
}

@implementation RBProcesses

#pragma mark - 应用枚举

/// 目录扫描兜底：返回 bundleID -> @{path, name}
+ (NSDictionary<NSString *, NSDictionary *> *)scanBundles {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *roots = @[ @"/var/containers/Bundle/Application", @"/Applications" ];

    for (NSString *root in roots) {
        NSArray<NSString *> *sub = [fm contentsOfDirectoryAtPath:root error:NULL];
        if (sub.count == 0) continue;
        BOOL flat = [root isEqualToString:@"/Applications"];

        NSMutableArray<NSString *> *appDirs = [NSMutableArray array];
        for (NSString *s in sub) {
            if (![s isKindOfClass:[NSString class]]) continue;
            NSString *p = [root stringByAppendingPathComponent:s];
            if (flat) {
                if ([p.pathExtension isEqualToString:@"app"]) [appDirs addObject:p];
            } else {
                NSArray<NSString *> *inner = [fm contentsOfDirectoryAtPath:p error:NULL];
                for (NSString *t in inner) {
                    if (![t isKindOfClass:[NSString class]]) continue;
                    if ([t.pathExtension isEqualToString:@"app"]) {
                        [appDirs addObject:[p stringByAppendingPathComponent:t]];
                    }
                }
            }
        }

        for (NSString *dir in appDirs) {
            @autoreleasepool {
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                      [dir stringByAppendingPathComponent:@"Info.plist"]];
                if (![info isKindOfClass:[NSDictionary class]]) continue;
                id bidRaw = info[@"CFBundleIdentifier"];
                if (![bidRaw isKindOfClass:[NSString class]] || [(NSString *)bidRaw length] == 0) continue;
                NSString *bid = bidRaw;
                id disp = info[@"CFBundleDisplayName"];
                id nm = info[@"CFBundleName"];
                NSString *name = [disp isKindOfClass:[NSString class]] ? disp
                               : ([nm isKindOfClass:[NSString class]] ? nm : bid);
                out[bid] = @{ @"path": dir, @"name": name };
            }
        }
    }
    return out;
}

+ (NSArray<RBAppInfo *> *)installedApps {
    @try {
        NSMutableDictionary<NSString *, NSString *> *names = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSString *> *paths = [NSMutableDictionary dictionary];

        // ① LSApplicationWorkspace（有就用，能给本地化名字和真实路径）
        Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
        if (wsCls) {
            @try {
                SEL sDefault = NSSelectorFromString(@"defaultWorkspace");
                if ([wsCls respondsToSelector:sDefault]) {
                    id ws = ((id (*)(id, SEL))objc_msgSend)(wsCls, sDefault);
                    NSArray *apps = nil;
                    SEL sAll = NSSelectorFromString(@"allInstalledApplications");
                    SEL sIns = NSSelectorFromString(@"installedApplications");
                    if ([ws respondsToSelector:sAll]) {
                        apps = ((id (*)(id, SEL))objc_msgSend)(ws, sAll);
                    } else if ([ws respondsToSelector:sIns]) {
                        apps = ((id (*)(id, SEL))objc_msgSend)(ws, sIns);
                    }
                    if ([apps isKindOfClass:[NSArray class]]) {
                        for (id p in apps) {
                            @autoreleasepool {
                                @try {
                                    id bidRaw = [p valueForKey:@"bundleIdentifier"];
                                    if (![bidRaw isKindOfClass:[NSString class]] || [bidRaw length] == 0) continue;
                                    NSString *bid = bidRaw;
                                    id name = [p valueForKey:@"localizedName"];
                                    if ([name isKindOfClass:[NSString class]] && [name length]) names[bid] = name;
                                    id url = [p valueForKey:@"bundleURL"];
                                    if ([url isKindOfClass:[NSURL class]]) paths[bid] = [(NSURL *)url path];
                                } @catch (NSException *e) {
                                    // 单个应用取值失败就跳过，不影响整体
                                }
                            }
                        }
                    }
                }
            } @catch (NSException *e) {
                RBLog(@"LSApplicationWorkspace 不可用：%@", e.reason);
            }
        }

        // ② 目录扫描兜底（LS 不可用，或某些 TrollStore 应用 LS 不收录）
        NSUInteger lsCount = paths.count;
        if (paths.count < 5) {
            NSDictionary *scan = [self scanBundles];
            for (NSString *bid in scan) {
                if (!paths[bid]) paths[bid] = scan[bid][@"path"];
                if (!names[bid]) names[bid] = scan[bid][@"name"];
            }
            RBLog(@"目录扫描：%lu 个应用（LS 只给了 %lu 个）",
                  (unsigned long)scan.count, (unsigned long)lsCount);
        }

        NSMutableArray<RBAppInfo *> *out = [NSMutableArray array];

        for (NSString *bid in paths) {
            @autoreleasepool {
                RBAppInfo *info = [RBAppInfo new];
                info.bundleID = bid;
                info.name = names[bid] ?: bid;
                info.isSystem = [bid hasPrefix:@"com.apple."];
                @try {
                    info.icon = [self iconForPath:paths[bid] bundleID:bid];
                } @catch (NSException *e) {
                    info.icon = nil;      // 图标拿不到就用占位图，不能让整页崩掉
                }
                [out addObject:info];
            }
        }

        [out sortUsingComparator:^NSComparisonResult(RBAppInfo *a, RBAppInfo *b) {
            if (a.isSystem != b.isSystem) return a.isSystem ? NSOrderedDescending : NSOrderedAscending;
            return [a.name localizedCaseInsensitiveCompare:b.name];
        }];
        return out;
    } @catch (NSException *e) {
        RBLog(@"installedApps 异常：%@ %@", e.name, e.reason);
        return @[];
    }
}

/// 从 App 目录里读图标（只用 Info.plist + 文件，不碰任何私有 API）
+ (UIImage *)iconForPath:(NSString *)path bundleID:(NSString *)bid {
    static NSMutableDictionary<NSString *, id> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });

    if (bid.length == 0 || path.length == 0) return nil;

    @synchronized([RBProcesses class]) {
        id hit = cache[bid];
        if (hit) return hit == [NSNull null] ? nil : hit;
    }

    UIImage *img = nil;
    @try {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                              [path stringByAppendingPathComponent:@"Info.plist"]];

        NSMutableArray<NSString *> *names = [NSMutableArray array];
        // CFBundleIconFiles 里偶尔混着 NSNumber / NSNull，统一在这里过滤掉。
        // 直接对非字符串发 .pathExtension 就是 unrecognized selector 崩溃。
        void (^collect)(id) = ^(id v) {
            if (![v isKindOfClass:[NSArray class]]) return;
            for (id x in (NSArray *)v) {
                if ([x isKindOfClass:[NSString class]] && [(NSString *)x length] > 0) {
                    [names addObject:(NSString *)x];
                }
            }
        };

        id icons = info[@"CFBundleIcons"];
        if ([icons isKindOfClass:[NSDictionary class]]) {
            id primary = ((NSDictionary *)icons)[@"CFBundlePrimaryIcon"];
            if ([primary isKindOfClass:[NSDictionary class]]) {
                collect(((NSDictionary *)primary)[@"CFBundleIconFiles"]);
            }
            collect(((NSDictionary *)icons)[@"CFBundleIconFiles"]);
        }
        collect(info[@"CFBundleIconFiles"]);
        id single = info[@"CFBundleIconFile"];
        if ([single isKindOfClass:[NSString class]] && [(NSString *)single length]) {
            [names addObject:(NSString *)single];
        }

        NSArray<NSString *> *suffixes = @[ @"@3x", @"@2x", @"" ];
        for (NSString *n in names) {
            NSString *base = n.pathExtension.length ? [n stringByDeletingPathExtension] : n;
            if (base.length == 0) continue;
            for (NSString *sfx in suffixes) {
                NSString *file = [NSString stringWithFormat:@"%@%@.png", base, sfx];
                NSString *full = [path stringByAppendingPathComponent:file];
                if ([[NSFileManager defaultManager] fileExistsAtPath:full]) {
                    img = [UIImage imageWithContentsOfFile:full];
                    if (img) break;
                }
            }
            if (img) break;
        }

        // 都没命中：扫一遍目录里最大的那个 png 当图标
        if (!img) {
            NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL];
            NSString *best = nil;
            unsigned long long bestSize = 0;
            for (NSString *f in files) {
                if (![f isKindOfClass:[NSString class]]) continue;
                if (![[f.pathExtension lowercaseString] isEqualToString:@"png"]) continue;
                if (![f hasPrefix:@"AppIcon"] && ![f hasPrefix:@"Icon"]) continue;
                NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:
                                      [path stringByAppendingPathComponent:f] error:NULL];
                unsigned long long sz = [attr[NSFileSize] unsignedLongLongValue];
                if (sz > bestSize) { bestSize = sz; best = f; }
            }
            if (best) img = [UIImage imageWithContentsOfFile:[path stringByAppendingPathComponent:best]];
        }
    } @catch (NSException *e) {
        RBLog(@"图标读取异常（%@）：%@", bid, e.reason);
        img = nil;
    }

    @synchronized([RBProcesses class]) {
        cache[bid] = img ?: [NSNull null];
    }
    return img;
}

#pragma mark - 进程枚举

/// 单个 pid -> bundleID。不在 /Bundle/Application/ 下（系统守护进程、系统 App）一律返回 nil。
+ (NSString *)bundleIDForPid:(pid_t)pid {
    if (pid <= 0) return nil;

    char path[PROC_PIDPATHINFO_MAXSIZE];
    memset(path, 0, sizeof(path));
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return nil;

    NSString *exe = [NSString stringWithUTF8String:path];
    if (exe.length == 0) return nil;                      // 非 UTF8 路径

    static NSString *const kMarker = @"/Bundle/Application/";
    NSRange r = [exe rangeOfString:kMarker];
    if (r.location == NSNotFound) return nil;

    NSUInteger afterMarker = r.location + r.length;
    if (afterMarker >= exe.length) return nil;

    // tail = "<UUID>/<Name>.app/<可执行文件>"
    NSString *tail = [exe substringFromIndex:afterMarker];
    NSArray<NSString *> *parts = [tail componentsSeparatedByString:@"/"];
    if (parts.count < 2) return nil;

    NSString *uuidDir = parts[0];
    NSString *appDir  = parts[1];
    if (uuidDir.length == 0 || appDir.length == 0) return nil;

    // 拼接而不是算索引：索引算术一旦少加一段，截出来的路径就是错位的
    // （1.0.x 就是这样：读不到 Info.plist，全部退化成目录名）。
    NSString *bundlePath = [NSString stringWithFormat:@"%@%@/%@",
                            [exe substringToIndex:afterMarker], uuidDir, appDir];

    NSString *bid = nil;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                          [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    if ([info isKindOfClass:[NSDictionary class]]) {
        id v = info[@"CFBundleIdentifier"];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) bid = v;
    }
    if (bid.length == 0) {
        bid = [appDir stringByDeletingPathExtension];
    }
    return bid.length ? bid : nil;
}

+ (NSDictionary<NSString *, NSNumber *> *)runningPids {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];

    int n = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (n <= 0) return map;
    int cap = n / (int)sizeof(pid_t) + 64;
    pid_t *pids = calloc((size_t)cap, sizeof(pid_t));
    if (!pids) return map;
    n = proc_listpids(PROC_ALL_PIDS, 0, pids, cap * (int)sizeof(pid_t));
    if (n <= 0) { free(pids); return map; }
    int count = n / (int)sizeof(pid_t);
    if (count > cap) count = cap;

    for (int i = 0; i < count; i++) {
        @autoreleasepool {
            pid_t pid = pids[i];
            if (pid <= 0) continue;
            NSString *bid = [self bundleIDForPid:pid];
            if (bid.length && !map[bid]) map[bid] = @(pid);
        }
    }
    free(pids);
    return map;
}

#pragma mark - 杀进程

/// RunningBoard 正规终止路径。kill() 只对同 uid 进程有效，遇到跨 uid 或系统托管的
/// 进程会被 EPERM 挡住；这条走的是 runningboard.terminateprocess 权限，成功率高得多。
static BOOL RBKillViaRunningBoard(pid_t pid) {
    Class handleCls = NSClassFromString(@"RBSProcessHandle");
    if (!handleCls) return NO;

    id handle = nil;
    SEL sForPid = NSSelectorFromString(@"handleForPid:");
    SEL sLookup = NSSelectorFromString(@"lookupHandleForPid:error:");
    @try {
        if ([handleCls respondsToSelector:sForPid]) {
            handle = ((id (*)(id, SEL, int))objc_msgSend)(handleCls, sForPid, pid);
        } else if ([handleCls respondsToSelector:sLookup]) {
            NSError *err = nil;
            handle = ((id (*)(id, SEL, int, NSError **))objc_msgSend)(handleCls, sLookup, pid, &err);
        }
    } @catch (NSException *e) {
        return NO;
    }
    if (!handle) return NO;

    SEL sTerm = NSSelectorFromString(@"terminateWithExplanation:");
    if (![handle respondsToSelector:sTerm]) return NO;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(handle, sTerm, @"RealBG 一键加速");
        return YES;
    } @catch (NSException *e) {
        return NO;
    }
}

+ (BOOL)killPid:(pid_t)pid {
    if (pid <= 1) return NO;
    if (pid == getpid()) return NO;

    if (kill(pid, SIGKILL) == 0) return YES;
    // 没有权限时退回 SIGTERM（个别进程只吃 TERM）
    if (errno == EPERM && kill(pid, SIGTERM) == 0) return YES;
    // 两条信号都不行，走 RunningBoard
    return RBKillViaRunningBoard(pid);
}

+ (BOOL)killApp:(NSString *)bundleID pid:(pid_t)pid {
    if (pid <= 1) return NO;
    if (pid == getpid()) return NO;
    if (RBIsSystemBundle(bundleID)) return NO;                  // com.apple.* 一律不动
    if (bundleID.length && [RBProtectedBundleIDs() containsObject:bundleID]) return NO;
    // 保留名单在这里也必须过一遍：万一调用方漏传，也不能杀掉锁住的 App
    if (bundleID.length && [[RBStore shared].lockIDs containsObject:bundleID]) return NO;

    // pid 复用防护：枚举到执行之间进程可能已经退出、pid 被别的进程占用，
    // 这种情况直接放弃，宁可少杀一个也不误杀。
    NSString *now = [self bundleIDForPid:pid];
    if (now.length && bundleID.length && ![now isEqualToString:bundleID]) {
        RBLog(@"pid %d 已被 %@ 复用，跳过 %@", pid, now, bundleID);
        return NO;
    }
    return [self killPid:pid];
}

+ (BOOL)isSystemBundle:(NSString *)bundleID { return RBIsSystemBundle(bundleID); }

#pragma mark - 内存

/// mach_host_self() 每次调用都会多一个 send right，用完不 deallocate 就是慢性泄漏。
/// 统计内存是每秒都在做的事，这里缓存一个端口反复用。
static mach_port_t RBHostPort(void) {
    static mach_port_t host;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ host = mach_host_self(); });
    return host;
}

+ (double)freeMemoryMB {
    mach_port_t host = RBHostPort();
    vm_size_t pageSize = 0;
    host_page_size(host, &pageSize);

    vm_statistics64_data_t vmstat;
    mach_msg_type_number_t cnt = HOST_VM_INFO64_COUNT;
    if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vmstat, &cnt) != KERN_SUCCESS) {
        return 0;
    }
    // free + inactive + speculative 都算「现在就能用」
    uint64_t freePages = (uint64_t)vmstat.free_count + vmstat.inactive_count + vmstat.speculative_count;
    return (double)freePages * pageSize / (1024.0 * 1024.0);
}

+ (double)usedMemoryMB {
    mach_port_t host = RBHostPort();
    vm_size_t pageSize = 0;
    host_page_size(host, &pageSize);
    vm_statistics64_data_t vmstat;
    mach_msg_type_number_t cnt = HOST_VM_INFO64_COUNT;
    if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vmstat, &cnt) != KERN_SUCCESS) {
        return 0;
    }
    uint64_t active = (uint64_t)vmstat.active_count + vmstat.wire_count + vmstat.compressor_page_count;
    return (double)active * pageSize / (1024.0 * 1024.0);
}

#pragma mark - 保护名单

+ (BOOL)isProtectedExec:(NSString *)exe {
    return [RBProtectedExecNames() containsObject:exe.lastPathComponent];
}

+ (NSSet *)protectedBundleIDs { return RBProtectedBundleIDs(); }

@end
