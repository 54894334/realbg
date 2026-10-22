//
//  RBBooster.m — 一键加速
//
//  iOS 没有 swap，切后台的 App 占的就是实打实的物理内存。所谓「加速」就一件事：
//  把不在真后台白名单、也不在保留名单里的后台进程结束掉，把内存还给系统。
//
//  数字来源：
//    · 单进程占用 = proc_pid_rusage(pid, RUSAGE_INFO_V4).ri_phys_footprint
//    · 系统内存   = host_statistics64(HOST_VM_INFO64)
//    · 实际释放   = 杀之前和杀之后的已用内存差（比可用内存差更敏感）
//
//  1.3.0 修掉的三个「杀了没效果」的问题：
//
//  ① kill() 返回 0 不等于进程死了。
//     kill() 只把信号投出去，返回值只代表「内核没拒收」。1.2.x 拿它当成功，
//     于是界面报「结束 5 个」，实际一个没死。现在每一步都回读进程表确认。
//
//  ② 进程被杀后 SpringBoard 会立刻把它重新拉起来。
//     这是真后台 App 的正常行为：只要 App 还有后台场景，FrontBoard 就把它恢复到
//     后台继续跑。所以「杀一次」不够 —— 现在最多清三轮：杀一轮、重扫、把复活的
//     再杀一轮，直到没有新增。
//
//  ③ 复活后的进程占用很小，被 8MB 门槛挡掉了。
//     刚被拉起来的 App footprint 常常只有 2-6MB，第一轮的 8MB 过滤会把它漏掉，
//     结果就是「列表显示还在运行，点加速却说无需加速」。后续轮专门针对
//     「刚被我们杀过又活过来」的那些，不再看内存大小。
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

// 第一轮候选的最小占用门槛。太小的进程杀了也没收益，还会让结果列表噪音很大。
static const double RBMinWorthMB = 8.0;

// 最多清几轮。轮与轮之间系统会重新拉起一部分 App，多扫两轮能显著提高净效果。
static const int RBMaxRounds = 3;

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

#pragma mark - 候选

/// 能不能动这个 App（不含内存判断）。所有过滤理由集中在一处，
/// 保证「候选」「复活复扫」「锁定统计」三处判断完全一致。
+ (BOOL)canTouchBundle:(NSString *)bid
                   pid:(pid_t)pid
               protect:(NSSet *)protect
               lockSet:(NSSet *)lockSet
           systemNames:(NSSet *)sysNames {
    if (bid.length == 0) return NO;
    if (pid <= 0 || pid == getpid()) return NO;
    if ([RBProcesses isSystemBundle:bid]) return NO;
    if ([sysNames containsObject:bid]) return NO;
    if ([lockSet containsObject:bid]) return NO;
    if (protect && [protect containsObject:bid]) return NO;
    return YES;
}

/// 全量候选：只排除系统 App、自己、系统保护清单、锁定名单、以及传入的 exclude。
+ (NSArray<NSDictionary *> *)rawCandidatesExcluding:(NSSet *)exclude minMB:(double)minMB {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSDictionary *running = [RBProcesses runningPids];
    NSSet *sysNames = [RBProcesses protectedBundleIDs];
    NSSet *lockSet = [RBStore shared].lockIDs;

    for (NSString *bid in running) {
        @autoreleasepool {
            pid_t pid = [running[bid] intValue];
            if (![self canTouchBundle:bid pid:pid protect:exclude lockSet:lockSet systemNames:sysNames]) continue;

            double raw = [self footprintMBForPid:pid];
            BOOL estimated = (raw <= 0);
            double mb = estimated ? RBFallbackFootprintMB : raw;
            if (mb < minMB) continue;

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
    return [self rawCandidatesExcluding:protect minMB:RBMinWorthMB];
}

/// 「本来会被清理、但因为锁定而保住」的进程。用来在加速前的弹窗里明确告诉用户：
/// 你锁的那几个我看得见，我不动它们。
+ (NSArray<NSDictionary *> *)lockedCandidatesProtecting:(NSSet *)protect {
    NSSet *lock = [RBStore shared].lockIDs;
    if (lock.count == 0) return @[];

    NSMutableSet *excl = [NSMutableSet setWithSet:protect ?: [NSSet set]];
    [excl minusSet:lock];            // 故意不排除锁定项，才能把它们筛出来

    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSDictionary *d in [self rawCandidatesExcluding:excl minMB:RBMinWorthMB]) {
        if ([lock containsObject:d[@"bundleID"]]) [out addObject:d];
    }
    return out;
}

/// 复扫：只看「刚才杀过、现在又活了」的 bundleID。
/// 这里故意不设内存门槛 —— 复活初期的进程占用小，设门槛就会把它们当成不存在，
/// 那正是「列表还在转圈但按钮说无需加速」的来源。
+ (NSArray<NSDictionary *> *)revivedFrom:(NSSet *)killedIDs protect:(NSSet *)protect {
    if (killedIDs.count == 0) return @[];

    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSDictionary *running = [RBProcesses runningPids];
    NSSet *sysNames = [RBProcesses protectedBundleIDs];
    NSSet *lockSet = [RBStore shared].lockIDs;

    for (NSString *bid in killedIDs) {
        @autoreleasepool {
            NSNumber *pn = running[bid];
            if (!pn) continue;
            pid_t pid = pn.intValue;
            if (![self canTouchBundle:bid pid:pid protect:protect lockSet:lockSet systemNames:sysNames]) continue;

            double raw = [self footprintMBForPid:pid];
            BOOL estimated = (raw <= 0);
            double mb = estimated ? RBFallbackFootprintMB : raw;
            [out addObject:@{
                @"bundleID": bid,
                @"pid": @(pid),
                @"mb": @(mb),
                @"estimated": @(estimated),
            }];
        }
    }
    return out;
}

#pragma mark - 加速

+ (NSDictionary *)boostProtecting:(NSSet *)protect {
    NSSet *p = protect ?: [NSSet set];

    // 我们自己挂上去的保活如果不撤，等于一边杀一边托着，白干。
    // 正常情况保护名单里已经含真后台 App，这里是兜底。
    [RBBackstage releaseOwnedBackstage];

    double beforeFree = [RBProcesses freeMemoryMB];
    double beforeUsed = [RBProcesses usedMemoryMB];

    // 锁定项必须在杀之前统计，杀完就查不到了
    NSArray *locked = [self lockedCandidatesProtecting:p];

    NSMutableOrderedSet<NSString *> *killedIDs = [NSMutableOrderedSet orderedSet];
    NSMutableDictionary<NSString *, NSDictionary *> *infoByID = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *failed = [NSMutableSet set];
    NSMutableSet<NSString *> *relaunched = [NSMutableSet set];
    NSMutableSet<NSString *> *tried = [NSMutableSet set];      // 第一轮出现过的（= 我们动过的）
    int rounds = 0;
    int consecutiveFail = 0;

    for (int round = 0; round < RBMaxRounds; round++) {
        rounds = round + 1;

        NSArray *cands = (round == 0)
            ? [self candidatesProtecting:p]
            : [self revivedFrom:tried protect:p];
        if (cands.count == 0) break;

        BOOL didWork = NO;
        for (NSDictionary *d in cands) {
            @autoreleasepool {
                NSString *bid = d[@"bundleID"];
                pid_t pid = [d[@"pid"] intValue];

                if (round == 0) {
                    [tried addObject:bid];
                } else if ([tried containsObject:bid]) {
                    [relaunched addObject:bid];        // 杀过又活了 → 记一次复活
                    RBLog(@"%@ 被系统重新拉起（pid %d），再清一次", bid, pid);
                }

                if ([RBProcesses killApp:bid pid:pid]) {
                    didWork = YES;
                    consecutiveFail = 0;
                    if (![killedIDs containsObject:bid]) {
                        [killedIDs addObject:bid];
                        infoByID[bid] = d;
                    }
                } else {
                    [failed addObject:bid];
                    // 连续三个都杀不掉，说明当前环境没权限，别一个个耗时间
                    if (++consecutiveFail >= 3) {
                        RBLog(@"连续 %d 个进程杀不掉，本轮提前结束", consecutiveFail);
                        break;
                    }
                }
            }
        }
        if (!didWork) break;
        usleep(round == 0 ? 420 * 1000 : 300 * 1000);
    }

    // 终局校验：把所有轮次都跑完之后再扫一遍进程表。
    // 凡是「现在已经不在了」才算成功 —— 中途记录的成功一律以这一次为准。
    NSDictionary *finalRunning = [RBProcesses runningPids];
    for (NSString *bid in [killedIDs array]) {
        if (finalRunning[bid]) {
            [killedIDs removeObject:bid];
            [infoByID removeObjectForKey:bid];
            [failed addObject:bid];
            [relaunched addObject:bid];
        }
    }

    // 给系统一点时间回收页面，否则读到的还是旧数字
    usleep(500 * 1000);
    double afterFree = [RBProcesses freeMemoryMB];
    double afterUsed = [RBProcesses usedMemoryMB];

    double freed = beforeUsed - afterUsed;
    if (freed < 0) freed = 0;
    double gained = afterFree - beforeFree;
    if (gained < 0) gained = 0;

    double freedByKill = 0;
    NSMutableArray *details = [NSMutableArray array];
    NSMutableArray *killedInfo = [NSMutableArray array];
    for (NSString *bid in killedIDs) {
        NSDictionary *d = infoByID[bid];
        double mb = [d[@"mb"] doubleValue];
        freedByKill += mb;
        [killedInfo addObject:d ?: @{@"bundleID": bid, @"mb": @0, @"estimated": @YES}];
        [details addObject:[NSString stringWithFormat:@"%@ (-%@%@)",
                            bid,
                            [d[@"estimated"] boolValue] ? @"~" : @"",
                            RBHumanMB(mb)]];
    }

    double keptMB = 0;
    NSMutableArray *lockedNames = [NSMutableArray array];
    for (NSDictionary *d in locked) {
        keptMB += [d[@"mb"] doubleValue];
        [lockedNames addObject:d[@"bundleID"]];
    }

    RBLog(@"一键加速：%d 轮，结束 %lu 个（失败 %lu，复活 %lu），锁定保留 %lu 个（约 %@）；"
          @"已用 %@ -> %@，可用 %@ -> %@",
          rounds,
          (unsigned long)killedIDs.count, (unsigned long)failed.count,
          (unsigned long)relaunched.count,
          (unsigned long)locked.count, RBHumanMB(keptMB),
          RBHumanMB(beforeUsed), RBHumanMB(afterUsed),
          RBHumanMB(beforeFree), RBHumanMB(afterFree));

    return @{
        @"killed":        @(killedIDs.count),
        @"failed":        @(failed.count),
        @"relaunched":    @(relaunched.count),
        @"rounds":        @(rounds),
        @"freedMB":       @(freed),            // 实测：已用内存下降量
        @"gainedMB":      @(gained),           // 实测：可用内存上升量
        @"freedByKillMB": @(freedByKill),      // 被杀进程占用之和（估值上限）
        @"beforeMB":      @(beforeFree),
        @"afterMB":       @(afterFree),
        @"beforeUsedMB":  @(beforeUsed),
        @"afterUsedMB":   @(afterUsed),
        @"lockedSkipped": @(locked.count),
        @"lockedKeptMB":  @(keptMB),
        @"lockedNames":   lockedNames,
        @"killedIDs":     [killedIDs array],
        @"killedInfo":    killedInfo,
        @"failedIDs":     [failed allObjects],
        @"details":       details,
    };
}

@end
