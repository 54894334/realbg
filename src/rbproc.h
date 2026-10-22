//
//  rbproc.h — libproc 声明兜底
//
//  有的 iOS SDK 里没有 usr/include/libproc.h，直接 #import <libproc.h> 会编译失败。
//  这里做 __has_include 判断，缺了就自己声明。
//
//  重要的坑（1.2.0 修）：
//    proc_listpids / proc_pidpath 是 iOS 2.0 起就稳定的 API，直接调用没问题。
//    但 proc_pid_rusage 存在版本差异，而原来 Makefile 里有
//    -Wl,-undefined,dynamic_lookup，链接器完全不检查符号是否存在 ——
//    到设备上 dyld 找不到符号就是 "Symbol not found"，
//    进程在 main 之前被直接杀掉：点开图标闪一下回桌面，App 自己一行日志都写不出来。
//
//    现在 proc_pid_rusage 一律通过 dlsym 取函数指针（见 RBBooster.m），
//    dlsym 拿不到只是内存数字降级，不会影响加载。
//    同时 Makefile 去掉了 dynamic_lookup，符号问题在 CI 阶段就暴露。
//
#ifndef RB_PROC_H
#define RB_PROC_H

#import <sys/types.h>
#import <sys/resource.h>

#if __has_include(<libproc.h>)
#import <libproc.h>
#else
extern int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

#define PROC_ALL_PIDS            1
#define PROC_PIDPATHINFO_MAXSIZE (4 * 1024)
#endif

#ifndef RUSAGE_INFO_V4
#define RUSAGE_INFO_V4 4
#endif

#endif /* RB_PROC_H */
