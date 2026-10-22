//
//  RBBooster.m — 一键加速（新增功能）
//
//  iOS 没有 swap，切后台的 App 占的就是实打实的物理内存。所谓「加速」就两件事：
//    1. 把不在真后台白名单里的后台进程结束掉，把内存还给系统；
//    2. 把被系统降频/挂起的进程重新拉到前台层级（本工程只做第 1 件，第 2 件
//       交给 RunningBoard，App 层强改有风险）。
//
//  内存统计用 proc_pid_rusage 拿每个进程的 phys_footprint，所以「预计释放」和
//  「实际释放」都是真实数字，不是编的。
//
#import "RB.h"
#import "rbproc.h"
#import <signal.h>
#import <string.h>
#import <unistd.h>

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
        if ([protectedBundles containsObject:bid]) continue;
        if ([protect containsObject:bid]) continue;

        double mb = [self footprintMBForPid:pid];
        if (mb < 8) continue;      // 太小的不值得动

        [out addObject:@{
            @"bundleID": bid,
            @"pid": @(pid),
            @"mb": @(mb),
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
    int n = 0;
    for (NSDictionary *d in cands) {
        pid_t pid = [d[@"pid"] intValue];
        if ([RBProcesses killPid:pid]) {
            n++;
            [killed addObject:d];
        } else {
            [failed addObject:d[@"bundleID"]];
        }
    }

    // 给系统一点时间回收页面，否则读到的还是旧数字
    usleep(600 * 1000);
    double after = [RBProcesses freeMemoryMB];
    double delta = after - before;
    double freed = delta < 0 ? 0 : delta;

    NSMutableArray *details = [NSMutableArray array];
    for (NSDictionary *d in killed) {
        [details addObject:[NSString stringWithFormat:@"%@ (-%@)",
                            d[@"bundleID"], RBHumanMB([d[@"mb"] doubleValue])]];
    }

    RBLog(@"一键加速：结束 %d 个进程，可用内存 %@ -> %@（+%@）",
          n, RBHumanMB(before), RBHumanMB(after), RBHumanMB(freed));

    return @{
        @"killed":   @(n),
        @"freedMB":  @(freed),
        @"beforeMB": @(before),
        @"afterMB":  @(after),
        @"skipped":  @(failed.count),
        @"details":  details,
    };
}

@end
