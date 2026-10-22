#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
test_realbg_logic.py — 源码级自动化测试（不需要真机，也不需要 iOS 编译环境）

不是「看一眼觉得没问题」，而是从**真实源文件**里把白名单/阈值/守卫解析出来，
再拿这些真实数据跑判定，最后对源码做后门关键字回归。

跑法：
    python test_realbg_logic.py [realbg 目录]
"""
import re, os, sys, plistlib

SRC = os.path.join(sys.argv[1] if len(sys.argv) > 1 else ".", "src")
ROOT = os.path.dirname(SRC) if os.path.basename(SRC) == "src" else SRC

passed, failed = [], []


def check(cond, name, extra=""):
    if cond:
        passed.append(name)
        print("  \033[32mPASS\033[0m %s %s" % (name, extra))
    else:
        failed.append(name)
        print("  \033[31mFAIL\033[0m %s %s" % (name, extra))


def strip_comments(src):
    """去掉 // 与 /* */ 注释，只留代码（避免把文档里的关键字当成代码）"""
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    out = []
    for line in src.split("\n"):
        # 粗略处理：不在字符串里的 // 之后全丢
        q = None
        cut = len(line)
        for i, ch in enumerate(line):
            if q:
                if ch == q and line[i - 1] != "\\":
                    q = None
            elif ch in "\"'":
                q = ch
            elif ch == "/" and i + 1 < len(line) and line[i + 1] == "/":
                cut = i
                break
        out.append(line[:cut])
    return "\n".join(out)


def read(fn):
    with open(os.path.join(SRC, fn), encoding="utf-8") as f:
        return f.read()


def str_array(src, anchor):
    """从 @[ ... ] 里抠出所有 @"..." 字面量"""
    i = src.index(anchor)
    j = src.index("@[", i)
    depth, k = 0, j
    while k < len(src):
        if src[k] == "[":
            depth += 1
        elif src[k] == "]":
            depth -= 1
            if depth == 0:
                break
        k += 1
    block = src[j:k]
    return re.findall(r'@"([^"]+)"', block)


print("== 1. 白名单完整性（数据直接来自 RBProcesses.m） ==")
proc = read("RBProcesses.m")
bundles = set(str_array(proc, "RBProtectedBundleIDs"))
execs = set(str_array(proc, "RBProtectedExecNames"))

CRIT_EXEC = ["launchd", "SpringBoard", "backboardd", "runningboardd", "frontboardd",
             "securityd", "tccd", "cfprefsd", "installd", "watchdogd"]
for n in CRIT_EXEC:
    check(n in execs, "守护进程受保护: %s" % n)

CRIT_BUNDLE = ["com.apple.springboard", "com.apple.mobilesafari", "com.apple.Preferences",
               "com.apple.mobilephone", "com.apple.MobileSMS", "cn.bswbw.RealBG"]
for n in CRIT_BUNDLE:
    check(n in bundles, "应用受保护: %s" % n)

check(len(execs) >= 30, "守护进程名单条数 >= 30", "（实际 %d）" % len(execs))
check(len(bundles) >= 25, "系统应用名单条数 >= 25", "（实际 %d）" % len(bundles))

print("\n== 2. 杀进程守卫 ==")
check("if (pid <= 1) return NO;" in proc, "拒绝 pid<=1（内核/launchd）")
check("if (pid == getpid()) return NO;" in proc, "拒绝杀自己")
check("if (errno == EPERM) return kill(pid, SIGTERM) == 0;" in proc, "无权限时降级 SIGTERM 而非强杀")
check("[RBProtectedBundleIDs() containsObject:bundleID]" in strip_comments(proc), "killApp: 再拦一次系统 App")

print("\n== 3. 一键加速过滤规则（用真实名单 + 真实阈值做判定） ==")
boost = read("RBBooster.m")
m = re.search(r"if \(mb < (\d+)\) continue", boost)
thresh = int(m.group(1)) if m else None
check(thresh == 8, "跳过占用 < 8MB 的进程", "（源码阈值 %s）" % thresh)
check('if ([protect containsObject:bid]) continue;' in boost, "真后台白名单不杀")
check('if ([protectedBundles containsObject:bid]) continue;' in boost, "系统应用不杀")
check('if (pid <= 0 || pid == me) continue;' in boost, "跳过非法 pid 与自身")
check("usleep(600 * 1000)" in boost, "杀完等待 600ms 再读内存（避免读到旧值）")
check("ri_phys_footprint" in boost, "单进程占用用 phys_footprint（真实值）")

# 模拟：给一张混合进程表，跑一遍过滤
procs = [
    # bundleID, mb
    ("com.apple.springboard", 220.0),
    ("cn.bswbw.RealBG", 40.0),
    ("com.tencent.xinWeChat", 480.0),
    ("com.apple.mobilesafari", 300.0),
    ("com.zhiliaoapp.musically", 6.0),      # 太小，应跳过
    ("com.example.backstage", 260.0),       # 在真后台白名单，应跳过
    ("com.netease.cloudmusic", 120.0),
]
protect = {"com.example.backstage"}
kept = []
for bid, mb in procs:
    if bid in bundles:            # 系统应用 / 自己
        continue
    if bid in protect:            # 真后台白名单
        continue
    if mb < thresh:               # 太小
        continue
    kept.append(bid)
expect = ["com.tencent.xinWeChat", "com.netease.cloudmusic"]
check(kept == expect, "候选集正确（只留真该杀的）", "→ %s" % kept)

print("\n== 4. 源码级后门回归（原包有、本包必须没有） ==")
all_src = "\n".join(strip_comments(read(f)) for f in sorted(os.listdir(SRC)) if f.endswith((".m", ".h")))
FORBIDDEN = [
    ("task_for_pid", "拿任意进程 task 端口（可读写内存）"),
    ("processor_set_tasks", "枚举全系统 task"),
    ("CFMessagePort", "mach 端口 IPC（原包 com.example.myPort 无鉴权）"),
    ("NSURLSession", "网络请求"),
    ("http://", "网络地址"),
    ("https://", "网络地址"),
    ("trollstorehelper", "调 TrollStore root helper（原包可卸载应用）"),
    ("MSHookFunction", "注入式 hook"),
    ("dlopen", "动态加载外部 dylib"),
]
for kw, why in FORBIDDEN:
    hit = kw in all_src
    check(not hit, "无 %-18s" % kw, "（%s）" % why if not hit else "← 出现了！")

print("\n== 5. 配置路径（修掉原包写死别人 plist 的 bug） ==")
store = read("RBStore.m")
check('RB_PREFS_NAME @"cn.bswbw.RealBG.plist"' in read("RB.h"), "写入自己 bundle 的 plist")
check("com.thefool.app.plist" in store, "只读兼容原版配置")
# 确认那处只用于读：定位 legacy 赋值语句，必须是 dictionaryWithContentsOfFile
clean_store = strip_comments(store)
m2 = re.search(r"NSString \*legacy = .*?;", clean_store, re.S)
check(m2 is not None and "dictionaryWithContentsOfFile:legacy" in clean_store, "旧路径仅用于 dictionaryWithContentsOfFile（只读）")
check("writeToFile:legacy" not in clean_store, "不写旧路径")

print("\n== 6. entitlements 数量与危险项 ==")
ents = plistlib.load(open(os.path.join(ROOT, "entitlements.plist"), "rb"))
check(len(ents) == 12, "权限条数 = 12", "（实际 %d）" % len(ents))
DANGER = ["task_for_pid-allow", "com.apple.system-task-ports", "proc_info-allow",
          "get-task-allow", "com.apple.private.persona-mgmt",
          "com.apple.private.kernel.jetsam", "com.apple.private.memorystatus"]
for d in DANGER:
    check(d not in ents, "无 %s" % d)
check(any(k.startswith("com.apple.private.hid") for k in ents) is False, "无 hid.* 权限")

print("\n== 7. 结构完整性 ==")
for f in ["RB.h", "rbproc.h", "main.m", "RBStore.m", "RBProcesses.m",
          "RBBackstage.m", "RBBooster.m", "RBRootVC.m"]:
    check(os.path.exists(os.path.join(SRC, f)), "存在 src/%s" % f)
mk = open(os.path.join(ROOT, "Makefile"), encoding="utf-8").read()
check("ARCHS := arm64 arm64e" in mk, "Makefile 同时出 arm64 + arm64e")
check("application.mk" in mk, "Makefile 是 application 目标（不是 tweak）")

print("\n" + "=" * 56)
print("通过 %d 项，失败 %d 项" % (len(passed), len(failed)))
if failed:
    for f in failed:
        print("  ✗ " + f)
    sys.exit(1)
print("\033[32m全部通过\033[0m")
