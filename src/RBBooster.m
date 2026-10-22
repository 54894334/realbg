//
//  RBBooster.m — 一键加速（新增功能）
//
//  iOS 没有 swap，切后台的 App 占的就是实打实的物理内存。所谓「加速」就一件事：
//  把不在真后台白名单里的后台进程结束掉，把内存还给系统。
//
//  数字来源：
//    · 单进程占用 = proc_pid_rusage(pid, RUSAGE_INFO_V4).ri_phys_footprint
//    · 系统可用内存 = host_statistics64(HOST_VM_INFO64) 的 free + inactive + speculative
//    · 实际释放 = 全部杀完之后释放内存 - 杀之前，中间 usleep 让系统回收页面
//
//  两条安全线：
//    · com.apple.* 一律不碰（系统 App 会随 iOS 版本增减，按前缀整片拦比维护清单可靠）
//    · 杀之前重新确认 pid 还属于同一个 bundle（防 pid 复用误杀）
//
#import "RB.h"
#import "rbproc.h"
#import <signal.h>
#import <string.h>
#import <unistd.h>

// proc_pid_rusage 对不同 uid 的进程可能返回 EPERM。真拿不到就按这个值估，
// 而不是当成 0 —— 否则 <8MB 的过滤会把所有候选都筛掉，按钮永远「没有可清理的进程」。
static const double RBFallbackFootprintMB = 24.0;

@implementation RBBooster

+ (double)footprintMBForPid:(pid_t)pid {
    if (pid <= 0) return 0;
    struct rusage_info_v4 ri;
    memset(&ri, 0, sizeof(ri));
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return 0;
    return (double)ri.ri_phys_footprint / (1024.0 * 1024.0);
}

+ (NSArray<NSDictionary *> *)candidatesProtecting:(NSSet *)protect {
    NSMutableArray *out = [NSMutableArray array];
    NSDictionary *running = [RBProcesses runningPids];
    NSSet *protectedBundles = [RBProcesses protectedBundleIDs];
    pid_t me = getpid();

    for (NSString *bid in running) {
        pid_t pid = [running[bid] intValue];
        if (pid <= 0 || pid == me) continue;
        if ([RBProcesses isSystemBundle:bid]) continue;          // com.apple.* 整片跳过
        if ([protectedBundles containsObject:bid]) continue;
        if ([protect containsObject:bid]) continue;

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
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"mb"] compare:a[@"mb"]];
    }];
    return out;
}

+ (double)estimatedReclaimMB {
    NSSet *protect = [RBStore shared].backstageIDs;
    double sum = 0;
    for (NSDictionary *d in [self candidatesProtecting:protect]) {
        sum += [d[@"mb"] doubleValue];
    }
    return sum;
}

+ (NSDictionary *)boostProtecting:(NSSet *)protect {
    double before = [RBProcesses freeMemoryMB];
    NSArray *cands = [self candidatesProtecting:protect ?: [NSSet set]];

    NSMutableArray *killed = [NSMutableArray array];
    NSMutableArray *failed = [NSMutableArray array];
    for (NSDictionary *d in cands) {
        NSString *bid = d[@"bundleID"];
        pid_t pid = [d[@"pid"] intValue];
        // 走 killApp: 而不是 killPid:，让它再过一遍系统白名单与 pid 复用校验
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

    RBLog(@"一键加速：结束 %lu 个（失败 %lu），可用内存 %@ -> %@（+%@）",
          (unsigned long)killed.count, (unsigned long)failed.count,
          RBHumanMB(before), RBHumanMB(after), RBHumanMB(freed));

    return @{
        @"killed":   @(killed.count),
        @"failed":   @(failed.count),
        @"freedMB":  @(freed),
        @"beforeMB": @(before),
        @"afterMB":  @(after),
        @"details":  details,
    };
}

@end
