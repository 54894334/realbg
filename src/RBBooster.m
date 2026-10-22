//
//  RBBooster.m — 一键加速（新增功能）
//
//  iOS 没有 swap，切后台的 App 占的就是实打实的物理内存。所谓「加速」就一件事：
//  把不在真后台白名单、也不在保留名单里的后台进程结束掉，把内存还给系统。
//
//  数字来源：
//    · 单进程占用 = proc_pid_rusage(pid, RUSAGE_INFO_V4).ri_phys_footprint
//    · 系统可用内存 = host_statistics64(HOST_VM_INFO64) 的 free + inactive + speculative
//    · 实际释放 = 全部杀完之后释放内存 - 杀之前，中间 usleep 让系统回收页面
//
//  三条安全线：
//    · com.apple.* 一律不碰（系统 App 会随 iOS 版本增减，按前缀整片拦比维护清单可靠）
//    · 杀之前重新确认 pid 还属于同一个 bundle（防 pid 复用误杀）
//    · 保留名单（LockList）里的 App 在候选阶段就剔除，锁住的 App 永远不会被加速碰到
//
#import "RB.h"
#import "rbproc.h"
#import <signal.h>
#import <string.h>
#import <unistd.h>
#import <dlfcn.h>

// proc_pid_rusage 对不同 uid 的进程可能返回 EPERM。真拿不到就按这个值估，
// 而不是当成 0 —— 否则 <8MB 的过滤会把所有候选都筛掉，按钮永远「没有可清理的进程」。
static const double RBFallbackFootprintMB = 24.0;

@implementation RBBooster

+ (double)footprintMBForPid:(pid_t)pid {
    if (pid <= 0) return 0;

    // 这里刻意用 dlsym 取函数指针，而不是直接调用 proc_pid_rusage。
    //
    // 直接调用会在二进制里留下对 _proc_pid_rusage 的未定义引用。这个符号存在
    // 版本差异，而上一版 Makefile 带了 -Wl,-undefined,dynamic_lookup ——
    // 链接器完全不检查它是否存在，到设备上 dyld 解析失败就直接杀进程，
    // 崩在 main 之前：图标闪一下就回桌面，App 自己一行日志都写不出来。
    //
    // 走 dlsym 之后：符号不存在只是「拿不到真实占用」，功能降级、不会崩。
    static int (*rusageFn)(int, int, rusage_info_t *);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rusageFn = (int (*)(int, int, rusage_info_t *))dlsym(RTLD_DEFAULT, "proc_pid_rusage");
        if (!rusageFn) {
            RBLog(@"当前系统没有 proc_pid_rusage，单进程占用按估值显示");
        }
    });
    if (!rusageFn) return 0;

    struct rusage_info_v4 ri;
    memset(&ri, 0, sizeof(ri));
    if (rusageFn(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return 0;
    return (double)ri.ri_phys_footprint / (1024.0 * 1024.0);
}

/// 全量候选：只排除系统 App、自己、系统保护清单、以及传入的 exclude。
/// 锁定名单不在这里面判断，交给调用方 —— 这样「哪些会被杀」「哪些是因为锁定才留下」
/// 用的是同一份枚举结果，不会出现两边数字对不上。
+ (NSArray<NSDictionary *> *)rawCandidatesExcluding:(NSSet *)exclude {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSDictionary *running = [RBProcesses runningPids];
    NSSet *protectedBundles = [RBProcesses protectedBundleIDs];
    pid_t me = getpid();

    for (NSString *bid in running) {
        @autoreleasepool {
            pid_t pid = [running[bid] intValue];
            if (pid <= 0 || pid == me) continue;
            if ([RBProcesses isSystemBundle:bid]) continue;          // com.apple.* 整片跳过
            if ([protectedBundles containsObject:bid]) continue;
            if (exclude && [exclude containsObject:bid]) continue;

            double mb = [self footprintMBForPid:pid];
            BOOL estimated = NO;
            if (mb <= 0) { mb = RBFallbackFootprintMB; estimated = YES; }
            if (mb < 8) continue;                                    // 太小的不值得动

            [out addObject:@{
                @"bundleID": bid,
                @"pid": @(pid),
                @"mb": @(mb),
                @"estimated": @(estimated),
            }];
        }
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"mb"] compare:a[@"mb"]];
    }];
    return out;
}

+ (NSArray<NSDictionary *> *)candidatesProtecting:(NSSet *)protect {
    return [self rawCandidatesExcluding:protect];
}

/// 「本来会被清理、但因为锁定而保住」的进程。用来在加速前的弹窗里明确告诉用户：
/// 你锁的那几个我看得见，我不动它们。
+ (NSArray<NSDictionary *> *)lockedCandidatesProtecting:(NSSet *)protect {
    NSSet *lock = [RBStore shared].lockIDs;
    if (lock.count == 0) return @[];

    NSMutableSet *excl = [NSMutableSet setWithSet:protect ?: [NSSet set]];
    [excl minusSet:lock];            // 故意不排除锁定项，才能把它们筛出来

    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSDictionary *d in [self rawCandidatesExcluding:excl]) {
        if ([lock containsObject:d[@"bundleID"]]) [out addObject:d];
    }
    return out;
}

+ (NSDictionary *)boostProtecting:(NSSet *)protect {
    NSSet *p = protect ?: [NSSet set];
    double before = [RBProcesses freeMemoryMB];
    // 锁定项必须在杀之前统计，杀完就查不到了
    NSArray *locked = [self lockedCandidatesProtecting:p];
    NSArray *cands = [self candidatesProtecting:p];

    NSMutableArray *killed = [NSMutableArray array];
    NSMutableArray *failed = [NSMutableArray array];
    for (NSDictionary *d in cands) {
        NSString *bid = d[@"bundleID"];
        pid_t pid = [d[@"pid"] intValue];
        // 走 killApp: 而不是 killPid:，让它再过一遍系统白名单、锁定名单与 pid 复用校验
        if ([RBProcesses killApp:bid pid:pid]) {
            [killed addObject:d];
        } else {
            [failed addObject:bid];
        }
    }

    // 给系统一点时间回收页面，否则读到的还是旧数字
    usleep(600 * 1000);
    double after = [RBProcesses freeMemoryMB];
    double delta = after - before;
    double freed = delta < 0 ? 0 : delta;

    NSMutableArray *details = [NSMutableArray array];
    for (NSDictionary *d in killed) {
        [details addObject:[NSString stringWithFormat:@"%@ (-%@%@)",
                            d[@"bundleID"],
                            [d[@"estimated"] boolValue] ? @"~" : @"",
                            RBHumanMB([d[@"mb"] doubleValue])]];
    }

    double keptMB = 0;
    NSMutableArray *lockedNames = [NSMutableArray array];
    for (NSDictionary *d in locked) {
        keptMB += [d[@"mb"] doubleValue];
        [lockedNames addObject:d[@"bundleID"]];
    }

    RBLog(@"一键加速：结束 %lu 个（失败 %lu），锁定保留 %lu 个（约 %@），可用内存 %@ -> %@（+%@）",
          (unsigned long)killed.count, (unsigned long)failed.count,
          (unsigned long)locked.count, RBHumanMB(keptMB),
          RBHumanMB(before), RBHumanMB(after), RBHumanMB(freed));

    return @{
        @"killed":        @(killed.count),
        @"failed":        @(failed.count),
        @"freedMB":       @(freed),
        @"beforeMB":      @(before),
        @"afterMB":       @(after),
        @"lockedSkipped": @(locked.count),
        @"lockedKeptMB":  @(keptMB),
        @"lockedNames":   lockedNames,
        @"details":       details,
    };
}

@end
