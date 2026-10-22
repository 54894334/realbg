//
//  RBCrash.m — 崩溃捕获 + 运行日志落盘
//
//  为什么需要这个：
//    App 在别人手机上闪退时，我这边看不到任何现场。控制台日志只有接电脑才能读，
//    而「设置 → 隐私 → 分析与改进 → 分析数据」里的 .ips 需要用户自己去找、还要会看懂。
//
//  文件放哪：
//    优先 App 容器的 Documents —— Info.plist 里开了 UIFileSharingEnabled 与
//    LSSupportsOpeningDocumentsInPlace，用户可以在「文件」App 的「我的 iPhone」
//    里直接看到并分享出来，不需要连电脑、不需要越狱工具。
//    取不到容器（极端情况）就退回 /var/mobile/Library/Preferences。
//
//  写什么：
//    · 未捕获的 Objective-C 异常：异常名、原因、完整调用栈符号
//    · 致命信号（SIGSEGV / SIGABRT / SIGBUS / SIGILL / SIGFPE / SIGTRAP）：
//      信号号 + backtrace，每个地址用 dladdr 反解成函数名（二进制没 strip，能解出来）
//
#import "RB.h"
#import <execinfo.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <signal.h>
#import <string.h>
#import <stdlib.h>
#import <limits.h>
#import <pthread.h>

// 信号处理里不能做内存分配 / Objective-C 调用，所以路径提前算成 C 字符串。
static char gCrashPath[PATH_MAX];
static char gLogPath[PATH_MAX];
static char gLogDirDoc[PATH_MAX];

// backtrace 的函数指针，在安装阶段取好。
// 用 dlsym 而不是直接调用：iOS 上 execinfo 不是官方承诺的稳定接口，
// 直接引用 _backtrace 会让 dyld 在缺符号时于 main 之前杀进程 ——
// 那正是「点开就闪退、日志都写不出来」的死循环。
static int (*gBacktraceFn)(void **, int);

static NSString *RBLogDirectory(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray<NSString *> *ds = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *doc = ds.count ? ds[0] : nil;
        if (doc.length) {
            [fm createDirectoryAtPath:doc withIntermediateDirectories:YES attributes:nil error:NULL];
            NSString *probe = [doc stringByAppendingPathComponent:@".rbprobe"];
            if ([[NSData data] writeToFile:probe atomically:YES]) {
                [fm removeItemAtPath:probe error:NULL];
                dir = doc;
            }
        }
        if (!dir) dir = @"/var/mobile/Library/Preferences";
    });
    return dir;
}

NSString *RBCrashLogPath(void) {
    return [RBLogDirectory() stringByAppendingPathComponent:@"RealBG-crash.txt"];
}
NSString *RBRunLogPath(void) {
    return [RBLogDirectory() stringByAppendingPathComponent:@"RealBG-log.txt"];
}
NSString *RBLogDirPath(void) { return RBLogDirectory(); }

/// 上一次运行留下的崩溃记录。main 里读一次，界面直接显示。
static NSString *RBCrashLastText = nil;
static volatile sig_atomic_t RBCrashWriting = 0;

#pragma mark - 信号处理（只允许 async-signal-safe 调用）

static void RBSignalHandler(int sig, siginfo_t *info, void *uap) {
    (void)info; (void)uap;
    if (RBCrashWriting) _exit(sig);
    RBCrashWriting = 1;

    if (gCrashPath[0] == 0) _exit(sig);
    int fd = open(gCrashPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) _exit(sig);

    char buf[512];
    const char *name = "UNKNOWN";
    switch (sig) {
        case SIGSEGV: name = "SIGSEGV"; break;
        case SIGABRT: name = "SIGABRT"; break;
        case SIGBUS:  name = "SIGBUS";  break;
        case SIGILL:  name = "SIGILL";  break;
        case SIGFPE:  name = "SIGFPE";  break;
        case SIGTRAP: name = "SIGTRAP"; break;
    }
    int n = snprintf(buf, sizeof(buf), "SIGNAL %d (%s)\n", sig, name);
    ssize_t ignored = write(fd, buf, (size_t)n);
    (void)ignored;

    // backtrace 在信号上下文里不是严格 async-signal-safe，但栈还没被破坏时
    // 这是唯一能拿到调用栈的办法（crash reporter 普遍这么做）。
    //
    // 函数指针必须在安装阶段（安全上下文）取好。信号处理里不能调 dispatch_once
    // 或 dlsym —— 前者有锁，信号恰好打断持锁线程就是死锁；后者内部也有锁。
    void *frames[64];
    int cnt = gBacktraceFn ? gBacktraceFn(frames, 64) : 0;
    for (int i = 0; i < cnt && i < 64; i++) {
        Dl_info di;
        if (dladdr(frames[i], &di) && di.dli_sname) {
            n = snprintf(buf, sizeof(buf), "#%-2d %p  %s\n", i, frames[i], di.dli_sname);
        } else if (dladdr(frames[i], &di) && di.dli_fname) {
            n = snprintf(buf, sizeof(buf), "#%-2d %p  %s+%ld\n", i, frames[i],
                         di.dli_fname,
                         (long)((char *)frames[i] - (char *)di.dli_fbase));
        } else {
            n = snprintf(buf, sizeof(buf), "#%-2d %p  ???\n", i, frames[i]);
        }
        ignored = write(fd, buf, (size_t)n);
    }
    close(fd);

    // 恢复默认处理并重发，让系统也留一份 .ips（不影响我们的文件）
    signal(sig, SIG_DFL);
    raise(sig);
    _exit(sig);
}

static void RBExceptionHandler(NSException *e) {
    @autoreleasepool {
        NSMutableString *s = [NSMutableString string];
        [s appendFormat:@"EXCEPTION %@\n%@\n\n", e.name ?: @"(nil)", e.reason ?: @"(nil)"];
        NSArray<NSString *> *stack = e.callStackSymbols;
        for (NSUInteger i = 0; i < stack.count; i++) {
            [s appendFormat:@"#%-2lu %@\n", (unsigned long)i, stack[i]];
        }
        NSArray *addrs = e.callStackReturnAddresses;
        if (addrs.count) {
            [s appendString:@"\n-- addresses --\n"];
            for (id a in addrs) [s appendFormat:@"%@\n", a];
        }
        [s writeToFile:RBCrashLogPath() atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    }
}

#pragma mark - 公共接口

void RBInstallCrashHandler(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 先把路径算好（这步只能在安全上下文做）
        snprintf(gCrashPath, sizeof(gCrashPath), "%s", [RBCrashLogPath() UTF8String]);
        snprintf(gLogPath, sizeof(gLogPath), "%s", [RBRunLogPath() UTF8String]);
        snprintf(gLogDirDoc, sizeof(gLogDirDoc), "%s", [RBLogDirectory() UTF8String]);
        if (gCrashPath[0] == 0) return;      // 完全取不到路径就只报警告，不影响启动

        // 在安全上下文里取好 backtrace 的地址（信号处理里不能调 dlsym）
        gBacktraceFn = (int (*)(void **, int))dlsym(RTLD_DEFAULT, "backtrace");

        NSSetUncaughtExceptionHandler(&RBExceptionHandler);

        static char altstack[64 * 1024];
        stack_t ss;
        ss.ss_sp = altstack;
        ss.ss_size = sizeof(altstack);
        ss.ss_flags = 0;
        sigaltstack(&ss, NULL);

        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = RBSignalHandler;
        sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
        sigemptyset(&sa.sa_mask);

        int sigs[] = { SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP };
        for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
            sigaction(sigs[i], &sa, NULL);
        }
    });
}

NSString *RBReadLastCrash(void) {
    if (RBCrashLastText) return RBCrashLastText;
    NSString *s = [NSString stringWithContentsOfFile:RBCrashLogPath()
                                           encoding:NSUTF8StringEncoding error:NULL];
    if (s.length == 0) return nil;
    RBCrashLastText = s;
    return s;
}

void RBDismissCrash(void) {
    RBCrashLastText = nil;
    [[NSFileManager defaultManager] removeItemAtPath:RBCrashLogPath() error:NULL];
}

#pragma mark - 运行日志

/// 全程共用一个 fd，避免每条日志都要 open/close。
/// 超过 256KB 就滚动一次，防止长期使用把用户磁盘写满。
///
/// 必须加锁：RBLog 会被 reload 线程、加速线程、退出清理线程同时调用，
/// 而滚动时要做 close + open。不加锁的话两个线程可能同时判断「该滚动了」，
/// 一个 close 掉刚被另一个打开的 fd —— 轻则日志错乱，重则把别人的 fd 关掉。
/// 注意信号处理里绝对不能调 RBLog（会死锁），那里只用裸 write。
void RBLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"[RealBG] %@", body);

    static int fd = -1;
    static off_t written = 0;
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static dispatch_once_t once;

    static NSDateFormatter *df;
    static dispatch_once_t once2;
    dispatch_once(&once2, ^{
        df = [NSDateFormatter new];
        df.dateFormat = @"MM-dd HH:mm:ss.SSS";
    });

    NSString *line = [NSString stringWithFormat:@"%@  %@\n", [df stringFromDate:[NSDate date]], body];
    const char *utf8 = line.UTF8String;
    if (!utf8) return;

    pthread_mutex_lock(&lock);
    dispatch_once(&once, ^{
        if (gLogPath[0] == 0) {
            snprintf(gLogPath, sizeof(gLogPath), "%s", [RBRunLogPath() UTF8String]);
        }
        fd = open(gLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:RBRunLogPath() error:NULL];
        written = (off_t)[attr[NSFileSize] longLongValue];
    });
    if (fd >= 0) {
        if (written > 256 * 1024) {
            close(fd);
            fd = open(gLogPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            written = 0;
        }
        if (fd >= 0) {
            ssize_t n = write(fd, utf8, strlen(utf8));
            if (n > 0) written += n;
        }
    }
    pthread_mutex_unlock(&lock);
}

NSString *RBHumanMB(double mb) {
    if (mb >= 1024) return [NSString stringWithFormat:@"%.1f GB", mb / 1024.0];
    return [NSString stringWithFormat:@"%.0f MB", mb];
}
