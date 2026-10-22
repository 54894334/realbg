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
check("kill(pid, SIGTERM) == 0" in proc, "无权限时降级 SIGTERM 而非强杀")
check("[RBProtectedBundleIDs() containsObject:bundleID]" in strip_comments(proc), "killApp: 再拦一次系统 App")
clean_proc = strip_comments(proc)
check("RBIsSystemBundle" in clean_proc and 'hasPrefix:@"com.apple."' in clean_proc,
      "系统 App 按 com.apple. 前缀整片拦（不依赖清单是否写全）")
check("RBKillViaRunningBoard" in clean_proc and "terminateWithExplanation:" in clean_proc,
      "kill 失败时走 RunningBoard 正规终止")
check("[now isEqualToString:bundleID]" in clean_proc, "杀之前校验 pid 仍属于同一 bundle（防 pid 复用误杀）")

print("\n== 3. 一键加速过滤规则（用真实名单 + 真实阈值做判定） ==")
boost = read("RBBooster.m")
m = re.search(r"if \(mb < (\d+)\) continue", boost)
thresh = int(m.group(1)) if m else None
check(thresh == 8, "跳过占用 < 8MB 的进程", "（源码阈值 %s）" % thresh)
check('if (exclude && [exclude containsObject:bid]) continue;' in boost, "真后台/锁定名单在候选阶段就排除")
check('if ([protectedBundles containsObject:bid]) continue;' in boost, "系统应用不杀")
check('if ([RBProcesses isSystemBundle:bid]) continue;' in boost, "com.apple.* 在候选阶段就被排除")
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
    if bid.startswith("com.apple."):   # 系统应用（前缀整片拦）
        continue
    if bid in bundles:                 # 自己
        continue
    if bid in protect:            # 真后台白名单
        continue
    if mb < thresh:               # 太小
        continue
    kept.append(bid)
expect = ["com.tencent.xinWeChat", "com.netease.cloudmusic"]
check(kept == expect, "候选集正确（只留真该杀的）", "→ %s" % kept)

print("\n== 3.5 本轮修掉的问题（每条都是源码里可验证的守卫） ==")
root_src = {f: strip_comments(read(f)) for f in sorted(os.listdir(SRC)) if f.endswith((".m", ".h"))}
bt = root_src["RBBackstage.m"]
check("class_addMethod" in bt, "窗口层级 hook 用 class_addMethod，不波及父类 UIWindow")
check("method_exchangeImplementations" not in bt, "不再用 method_exchangeImplementations（会改到继承来的方法）")
check("destroyScene" in bt and bt.count("destroyScene") >= 2, "binder 不可用时回收已创建的 scene（不泄漏）")
check("dropIfStale" in bt and "RBIsAlive" in bt, "目标进程退出后清掉陈旧 scene，不假装已开启")

st = root_src["RBStore.m"]
check("RBSanitizeSet" in st and "isKindOfClass:[NSArray class]" in st, "配置项做类型校验（坏 plist 不会崩在启动）")

vc = root_src["RBRootVC.m"]
check("infoAtIndex:" in vc and "self.shown.count" in vc, "表格取值加越界保护")
check("idleTimerDisabled" not in "".join(root_src.values()), "去掉了全局常亮（原写法退出也不恢复）")
check("presentAlert:" in vc, "所有弹窗统一走 presentAlert:（避免 already presenting）")
_t1 = vc.index("- (void)tapBoost {")
_t2 = vc.index("- (void)doBoostWithCandidates:(NSArray *)cands {")
check("dispatch_get_global_queue" in vc[_t1:_t2], "一键加速的进程枚举放在后台线程（不卡主线程）")

check("RBHostPort" in root_src["RBProcesses.m"], "host 端口缓存复用（频繁 mach_host_self 会泄漏 send right）")
check("bundleIDForPid" in root_src["RBProcesses.m"], "进程枚举复用同一套 pid -> bundleID 解析")

mn = root_src["main.m"]
check("performSuicideCleanup" in mn and "applicationDidEnterBackground" in mn,
      "「退出即杀」名单真的执行（第一版只存不读，开关是摆设）")
check("[lock containsObject:bid]" in mn and "[backstage containsObject:bid]" in mn,
      "退出清理时：锁定 > 真后台 > 退出即杀，优先级写在源码里")

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
check(len(ents) == 18, "权限条数 = 18", "（实际 %d）" % len(ents))
check("com.apple.private.security.no-container" not in ents,
      "不带 no-container（原包 1.5 没有这条；带上就没有沙盒容器，与 platform-application 组合更危险）")
check("com.apple.backboard.client" in ents,
      "带 backboard.client（platform-application 会让沙盒变严，缺它拿不到显示连接）")
check("com.apple.QuartzCore.displayable-context" in ents and "com.apple.QuartzCore.secure-mode" in ents,
      "带 QuartzCore 两条（图层可显示 / 可上屏）")
DANGER = ["task_for_pid-allow", "com.apple.system-task-ports", "proc_info-allow",
          "get-task-allow", "com.apple.private.persona-mgmt",
          "com.apple.private.kernel.jetsam", "com.apple.private.memorystatus"]
for d in DANGER:
    check(d not in ents, "无 %s" % d)
check(any(k.startswith("com.apple.private.hid") for k in ents) is False, "无 hid.* 权限")

print("\n== 7. 结构完整性 ==")
for f in ["RB.h", "rbproc.h", "main.m", "RBStore.m", "RBProcesses.m",
          "RBBackstage.m", "RBBooster.m", "RBRootVC.m", "RBCrash.m"]:
    check(os.path.exists(os.path.join(SRC, f)), "存在 src/%s" % f)
mk = open(os.path.join(ROOT, "Makefile"), encoding="utf-8").read()
check("ARCHS := arm64" in mk, "Makefile 出 arm64 切片")
_mk_code = "\n".join(l.split("#")[0] for l in mk.split("\n"))   # Makefile 注释是 #
check("arm64e" not in _mk_code,
      "不再出 arm64e（TrollStore 伪签名不覆盖 PAC，arm64e 是秒退高发区）")
check("application.mk" in mk, "Makefile 是 application 目标（不是 tweak）")

print("\n== 8. 1.1.0 新增：保留名单（锁定） ==")
st = strip_comments(root_src["RBStore.m"])
check('@"LockList"' in st, "配置里持久化 LockList（重启后锁定不丢）")
check("[RBSanitizeSet(d[@\"LockList\"])" in st, "LockList 也走类型校验（坏 plist 不崩）")
check("allProtectedIDs" in st and "unionSet:self.lockIDs" in st,
      "allProtectedIDs 合并真后台 + 锁定，加速与清理共用一份")

bo = strip_comments(root_src["RBBooster.m"])
check("rawCandidatesExcluding" in bo, "候选枚举抽成单一实现，两边数字不会对不上")
check("lockedCandidatesProtecting" in bo, "能算出「因为锁定才保住」的进程")
check("[excl minusSet:lock]" in bo, "故意不排除锁定项，才能把它们筛出来展示")
check('@"lockedSkipped"' in bo and '@"lockedKeptMB"' in bo,
      "加速结果带回锁定跳过数与保住的内存")
check("RBStore shared].lockIDs" in bo, "锁定名单直接取自 store，不靠调用方传")

pr = strip_comments(root_src["RBProcesses.m"])
check("[[RBStore shared].lockIDs containsObject:bundleID]" in pr,
      "killApp: 里再拦一次锁定（调用方漏传也杀不到）")

vc = strip_comments(root_src["RBRootVC.m"])
check("toggleLock:" in vc, "有独立的锁定/解锁动作")
check("@\"锁定保留\"" in vc and "@\"取消锁定\"" in vc, "右滑有「锁定保留 / 取消锁定」")
check("加速时保留" in vc, "详情菜单里也有一键锁定")
check('@[@"全部", @"运行", @"保活", @"自启", @"锁定"]' in vc, "分段里有「锁定」页")
check("self.tab == 4 && !i.locked" in vc, "「锁定」页只列已锁定的")
check("已锁定跳过" in vc, "加速前的弹窗明确写「已锁定跳过 N 个」")
check("锁定保留 %lu 个" in vc, "加速结果里也报锁定保留数量")
check("info.locked" in vc and "已锁定，先取消锁定" in vc, "锁定项手动「杀后台」也会被拦")

mn = strip_comments(root_src["main.m"])
check("[lock containsObject:bid]" in mn, "退出清理尊重锁定（锁定优先于退出即杀）")
check("if ([lock containsObject:bid]) continue;" in mn and "restoreAutoStart" in mn,
      "自启恢复也会跳过锁定的 App")

print("\n== 9. 1.1.0 修掉的两处闪退 / 功能失效 ==")
check("collect(((NSDictionary *)primary)[@\"CFBundleIconFiles\"])" in pr,
      "图标名走 collect 过滤（原来 addObjectsFromArray 直接把非字符串塞进去）")
check("[x isKindOfClass:[NSString class]]" in pr,
      "CFBundleIconFiles 的元素逐个校验类型（NSNumber/NSNull 不再 unrecognized selector）")
check("addObjectsFromArray:legacy" not in pr, "不再有未过滤的 addObjectsFromArray")
check("@synchronized([RBProcesses class])" in pr, "图标缓存加锁（并发刷新不撞 NSMutableDictionary）")
check("stringWithFormat:@\"%@%@/%@\"" in pr,
      "bundle 路径用拼接，不用索引算术（1.0.x 少加 marker 长度导致全部解析失败）")
check("installedApps 异常" in pr, "installedApps 整体兜底，枚举出错也不让进程死")
check("runningPids 异常" in pr, "runningPids 也兜底，进程枚举出错不会炸整条刷新链")

bt = strip_comments(root_src["RBBackstage.m"])
check("__attribute__((constructor))" not in bt,
      "不再在 pre-main 的构造函数里碰 UIKit（改成懒加载）")
check("RBInstallSceneWindowHooksIfNeeded" in bt and "dispatch_once" in bt,
      "窗口 hook 改为首次使用时安装一次")

print("\n== 10. 1.1.0 新增：崩溃捕获 / 安全模式 ==")
cr = strip_comments(root_src["RBCrash.m"])
check("NSSetUncaughtExceptionHandler" in cr, "捕获未抛出的 ObjC 异常")
check("sa_sigaction = RBSignalHandler" in cr, "捕获致命信号")
check("SA_ONSTACK" in cr and "sigaltstack" in cr, "独立信号栈（栈溢出也能写日志）")
check("dladdr" in cr, "把返回地址反解成函数名，日志能直接看出崩在哪")
check("pthread_mutex_lock(&lock)" in cr and "pthread_mutex_unlock(&lock)" in cr,
      "写日志加锁（多线程同时触发滚动时不会关掉别人正在用的 fd）")
check("void RBAppendRaw" not in cr, "日志写入只有一条路径，不存在绕开锁的第二条写入口")
check("UIFileSharingEnabled" in open(os.path.join(ROOT, "RealBG", "Info.plist"), encoding="utf-8").read(),
      "Info.plist 开了文件共享，日志能从「文件」App 取出来")
check("RBInstallCrashHandler();" in mn and mn.index("RBInstallCrashHandler();") < mn.index("UIApplicationMain"),
      "main 里在 UIApplicationMain 之前就装好捕获")
check("safeMode" in vc and "RBReadLastCrash().length > 0" in vc,
      "上次崩过就进安全模式，不自动枚举（保证界面能打开）")
check("if (!self.safeMode) [self reload];" in vc, "安全模式下不自动 reload")
check("if (apps.count > 0) self.safeMode = NO;" in vc, "枚举成功才退出安全模式")

print("\n== 11. 1.1.0 打包配置 ==")
ipl = open(os.path.join(ROOT, "RealBG", "Info.plist"), encoding="utf-8").read()
check("CFBundleSupportedPlatforms" in ipl, "声明 CFBundleSupportedPlatforms（缺了有的安装路径判为非法包）")
check("<key>UIRequiresFullScreen</key>" not in ipl,
      "去掉 UIRequiresFullScreen（iPad 上强制四方向，只声明竖屏会断言崩溃）")
check("UISupportedInterfaceOrientations~ipad" in ipl, "iPad 单独声明四个方向")
check("LSSupportsOpeningDocumentsInPlace" in ipl, "文件 App 可直接打开日志目录")
check("<string>1.2.0</string>" in ipl, "Info.plist 版本 1.2.0")

print("\n== 12. 1.2.0：消除「点开秒退」的全部已知成因 ==")
mk_code = "\n".join(l.split("#")[0] for l in mk.split("\n"))
check("dynamic_lookup" not in mk_code,
      "Makefile 不再用 -Wl,-undefined,dynamic_lookup（它让符号缺失推迟到 dyld，崩在 main 之前）")
check("ARCHS := arm64" in mk_code and "arm64e" not in mk_code,
      "只出 arm64，不出 arm64e")

bo_src = strip_comments(root_src["RBBooster.m"])
check('dlsym(RTLD_DEFAULT, "proc_pid_rusage")' in bo_src,
      "proc_pid_rusage 走 dlsym 取指针（符号缺失只降级，不会让 dyld 杀进程）")
check("rusageFn(pid, RUSAGE_INFO_V4" in bo_src, "调用前判空，取不到就不调用")

cr_src = strip_comments(root_src["RBCrash.m"])
check('dlsym(RTLD_DEFAULT, "backtrace")' in cr_src, "backtrace 也走 dlsym")
check("gBacktraceFn = (int (*)(void **, int))dlsym" in cr_src,
      "函数指针在安装阶段（安全上下文）取好")
check("dispatch_once" not in cr_src[cr_src.index("static void RBSignalHandler"):cr_src.index("static void RBExceptionHandler")],
      "信号处理里不调 dispatch_once（会死锁）")

check("__attribute__((constructor))" not in "".join(root_src.values()),
      "全工程没有 constructor（不在 pre-main 阶段执行任何东西）")

# lite 探针：必须真的存在，且不含任何私有 API / 私有框架
import os as _os
lite_main = _os.path.join(ROOT, "lite", "main.m")
lite_mk = _os.path.join(ROOT, "lite", "Makefile")
lite_ent = _os.path.join(ROOT, "lite", "entitlements.plist")
check(_os.path.exists(lite_main), "存在 lite 探针源码（用来二分：打包问题 vs 代码问题）")
if _os.path.exists(lite_main):
    lm = strip_comments(open(lite_main, encoding="utf-8").read())
    for bad_api in ("FBMutableSceneDefinition", "RBSDomainAttribute", "proc_listpids",
                    "NSClassFromString", "dlsym", "task_for_pid"):
        check(bad_api not in lm, "探针不含私有 API: %s" % bad_api)
if _os.path.exists(lite_mk):
    lmk = "\n".join(l.split("#")[0] for l in open(lite_mk, encoding="utf-8").read().split("\n"))
    check("PRIVATE_FRAMEWORKS" not in lmk, "探针不链接私有框架")
    check("dynamic_lookup" not in lmk, "探针也不用 dynamic_lookup")
if _os.path.exists(lite_ent):
    import plistlib as _pl
    le = _pl.loads(open(lite_ent, "rb").read())
    check(len(le) == 2, "探针只用 2 条权限（platform-application + no-sandbox）", "（实际 %d）" % len(le))

# 产物校验器本身要能拦住「依赖私有框架」这种致命问题
vt = open(_os.path.join(ROOT, "tests", "verify_tipa.py"), encoding="utf-8").read()
check("ALLOWED_DYLIB_PREFIXES" in vt, "verify 会逐个核对 LC_LOAD_DYLIB")
check("PrivateFrameworks" not in vt.split("ALLOWED_DYLIB_PREFIXES")[1].split(")")[0],
      "verify 的白名单里不放 PrivateFrameworks")
check("cryptid" in vt, "verify 检查 cryptid（非 0 说明还带 FairPlay 加密壳）")
check("LC_MAIN" in vt, "verify 检查 LC_MAIN（没有入口点会启动即退）")

print("\n" + "=" * 56)
print("通过 %d 项，失败 %d 项" % (len(passed), len(failed)))
if failed:
    for f in failed:
        print("  ✗ " + f)
    sys.exit(1)
print("\033[32m全部通过\033[0m")
