//
//  rbproc.h — libproc 声明兜底
//
//  有的 iOS SDK 里没有 usr/include/libproc.h，直接 #import <libproc.h> 会编译失败。
//  这里做 __has_include 判断，缺了就自己声明这几个函数（它们都在 libsystem_kernel /
//  libsystem_c 里，不需要额外链接私有库）。
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
extern int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);

#define PROC_ALL_PIDS            1
#define PROC_PIDPATHINFO_MAXSIZE (4 * 1024)
#endif

#ifndef RUSAGE_INFO_V4
#define RUSAGE_INFO_V4 4
#endif

#endif /* RB_PROC_H */
