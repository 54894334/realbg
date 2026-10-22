# 真后台 Pro（RealBG）

基于对 **巨魔真后台 1.5**（`cn.bswbw.RealBackstage`，`RealBackstage_1.5.tipa`，358,657 字节）的静态逆向，**重写**的同功能 App —— 不是改包，源码级重建，所以后门、冗余权限、写死的路径一个都不继承。

- 包名：`cn.bswbw.RealBG`　显示名：真后台 Pro　版本：1.0.0
- 目标系统：iOS 15.0+（arm64 / arm64e）
- 安装方式：TrollStore 直接装 `.tipa`，**不需要越狱**

---

## 一、逆向做了什么

二进制是 thin arm64 `MH_EXECUTE`（438,608 字节），用 **`LC_DYLD_CHAINED_FIXUPS`**（不是老的 rebase/bind 表）。`__objc_classlist` 里的指针是编码链指针，直接当地址读全是垃圾 —— 所以老工具链读出来是 0 方法。

为此写了一套自己的工具（`tools/m0_fixups.py` 起）：

| 脚本 | 作用 |
|---|---|
| `m0_fixups.py` | 解析 chained fixups，把任意槽解成 `rebase(target)` 或 `bind(符号, addend)` |
| `m2b_objc.py` | 在解好的指针上还原 ObjC 元数据（8 类 / 7 category / 102 方法） |
| `m4b_disasm.py` | 符号化反汇编（capstone），支持按函数 / 选择器 / 调用 / 字符串查 |
| `m5_sim.py` | Unicorn 模拟执行（用于跟踪加密字符串解密） |
| `m6_strdec.py` | 静态还原运行时 XOR 字符串（最终出 85 条） |

两个关键坑，记下来备用：

1. `dyld_chained_starts_in_segment` 头是 `<IHHQ>` = size/page_size/pointer_format/segment_offset，**+16 是 max_valid_pointer，+20 才是 page_count**，page_start[] 从 +22 开始。偏移写错就一个槽都解不出来。
2. iOS 16+ 的 `method_list_t` 如果 `entsize` 的 bit31 置位，就是 **relative method list**：每条是 3 个 int32 相对偏移。而且 name 偏移指向的是 `__objc_selrefs` 槽，槽本身还是链指针，**要再解一层**才是 `__objc_methname` 里的 cstring。

---

## 二、后门与风险清单（原包 1.5）

### 1. 通用 CFMessagePort 控制端口，无鉴权

还原出的 85 条加密字符串里有：

```
com.example.myPort          <- 端口名，示例代码里没改过
com.shadow.getEspDataQueue
trollstorehelper
```

`com.example.myPort` 是**全局命名**的 mach 端口，注册后系统内**任何进程**都能 `CFMessagePortCreateRemote` 连上来发消息。没有签名校验、没有权限判断、没有 nonce。等于给设备白送一个控制面 —— 任何拿到这个 bundle id 的代码都能跟它通话。

**本工程：一行 IPC 代码都没有。** 全部改成进程内直接调用，不监听任何端口。

### 2. entitlements 里一整套与功能无关的高危权限

原包签了 40+ 条，其中：

| 权限 | 实际能力 | 为什么不该有 |
|---|---|---|
| `task_for_pid-allow` | 拿任意进程 task 端口 → 读写任意 App 内存 | 开关真后台、杀进程都用不到 |
| `com.apple.system-task-ports{,.control}` | 同上，范围更大 | 同上 |
| `proc_info-allow` | 读全系统进程信息 | 用 `proc_listpids` 就够 |
| `com.apple.private.hid.client.event-monitor` 等 4 条 | 监听/注入 HID 事件（键盘、触摸） | 跟真后台毫无关系 |
| `com.apple.private.kernel.jetsam` | 影响系统内存回收策略 | 全局副作用，不该给 |
| `com.apple.private.memorystatus` | 改别的进程内存状态 | 杀进程不需要 |
| `com.apple.private.persona-mgmt` | 用户身份（persona）管理 | 完全无关 |
| `get-task-allow` | 可被调试器附加 | 发布包不该有 |

**本工程只保留 10 条，每条都对应一个具体功能**（见 `entitlements.plist`）：

```
platform-application                       TrollStore 运行前提
com.apple.private.security.no-sandbox      读 /var/mobile/Library/Preferences 存配置
...storage.AppBundles / AppDataContainers  枚举已装 App、读 Info.plist 拿图标
com.apple.springboard-ui.client            挂 scene 上屏
com.apple.runningboard.terminateprocess    杀进程
com.apple.runningboard.process-state       查进程状态
com.apple.runningboard.targetidentities    构造 target
com.apple.runningboard.assertions.frontboard  Background 断言兜底
com.apple.runningboard.launchprocess + frontboard.launchapplications  拉起 App
mach-lookup: frontboard.systemappservices / runningboardd  连这两个服务
```

`task_for_pid` / `system-task-ports` / `hid.*` / `jetsam` / `memorystatus` / `persona-mgmt` / `get-task-allow` **一条都没有**。

### 3. 写死别人的配置路径

原包把白名单存到 `/var/mobile/Library/Preferences/com.thefool.app.plist` —— 不是自己的 bundle id。两个不同工具会互相覆盖配置，卸载也留垃圾。

**本工程**：`/var/mobile/Library/Preferences/cn.bswbw.RealBG.plist`，键名沿用 `WhiteList` / `AutoStart` / `SuicideList`，首次启动如果发现老文件会自动迁移一次。

### 4. 网络外发

审计结论：**原包没有任何网络代码** —— 0 个 http/socket 符号，只有 `t.me`（TG 频道）、PayPal、支付宝三个「打开链接」的按钮字符串。所以这块不是后门，但本工程连这三个按钮也不带。

### 5. 具备卸载任意 App 的能力（未在本工程保留）

解密字符串里同时出现：

```
0x100053d90  'com.shadow.getEspDataQueue'
0x100053e40  'uninstall'
0x100053e54  'installd'
0x100053e70  'com.opa334.TrollStore'
0x100053ef0  'trollstorehelper'
0x100053f30  'applicationProxyForIdentifier:'
```

`trollstorehelper` + `uninstall` + `installd` 这一组说明原包能借 TrollStore 的 root helper 走 `installd` 卸载任意已安装应用。真后台不需要卸载能力，**本工程一行都没有**（只用 `kill()` 结束进程）。

### 6. 实测证据：解密出来的原包字符串（节选）

`tools/m6_strdec.py` 从原二进制静态还原 **85 条**运行时 XOR 加密字符串，其中与后门/配置相关的关键条目：

| 地址 | 字符串 | 含义 |
|---|---|---|
| `0x100054d40` | `com.example.myPort` | 全局 CFMessagePort 名，示例代码没改 → 无鉴权 IPC |
| `0x100053d90` | `com.shadow.getEspDataQueue` | 自建 GCD 队列名，带 `shadow` 前缀 |
| `0x100053ef0` | `trollstorehelper` | 调 TrollStore root helper |
| `0x100058760` | `/var/mobile/Library/Preferences/com.thefool.app.plist` | 写死别人的配置路径 |
| `0x100055492` | `WhiteList` | 真后台白名单键名 |
| `0x1000551b2` | `SuicideList` | 切走即杀列表键名 |
| `0x100058a60` | `[KillCheck] %@ (pid %d) -> role: %@ (%d)` | 杀进程日志格式 |
| `0x100059060`~`0x100059100` | `Darwinbg` `Throttle` `GfxServer` `Default` `Inactive` `Background` `Foreground` `Reniced` | RunningBoard 断言/进程角色名 |
| `0x100059ee0` | `RealBackstage://YFF` | URL scheme |

本工程的键名沿用 `WhiteList` / `AutoStart` / `SuicideList`，其余一个不带。

---

## 三、新增：一键加速

原版清内存只能一个个 App 点「杀后台」，没有批量。本工程底部常驻一条：

```
已用 3.2 GB · 可用 1.8 GB · 可清理约 1.4 GB        [ 一键加速 ]
```

点一下 → 弹出**待结束进程清单 + 每个进程真实占用 + 预计释放总量** → 确认 → 执行 → 再弹结果（结束几个 / 实际释放多少 / 可用内存 before→after）。

真实数字来源，没有估算：

- 单进程占用：`proc_pid_rusage(pid, RUSAGE_INFO_V4)` 的 `ri_phys_footprint`
- 系统可用/已用：`host_statistics64(HOST_VM_INFO64)`
  - 可用 = `free + inactive + speculative`
  - 已用 = `active + wire + compressor`
- 实际释放 = 杀完后 `usleep(600ms)` 再读一次可用内存，`after - before`（负数按 0 处理）

保护规则（**这些永远不杀**）：

- 28 个系统 App（SpringBoard、电话、短信、相机、设置…）+ 自己
- 35 个系统守护进程（`launchd`、`backboardd`、`runningboardd`、`securityd`、`tccd`、`cfprefsd`… 按可执行文件名匹配）
- 已开真后台的 App（在 `backstageIDs` 里）
- 占用 < 8MB 的（动了也省不出东西）

---

## 四、白苹果风险评估

结论：**不会白苹果**。逐条说明为什么：

1. **不注入系统进程。** 没有 MobileSubstrate / CydiaSubstrate / `MSHookFunction`，不改 SpringBoard 二进制，不往任何系统进程里塞 dylib。真后台走的是 FrontBoard 公开的 scene 挂载路径（`FBSceneManager` + `UIRootWindowScenePresentationBinder`），这是系统自己给「画中画 / CarPlay」用的正规接口。
2. **唯一的 hook 是进程内的。** 对 `UIRootSceneWindow` 的 `windowLevel` / `_canShowWhileLocked` 做 `method_exchangeImplementations`，只影响**本进程自己**加载的那份 UIKit 运行时，不落盘、不跨进程。
3. **杀进程有白名单兜底。** `killPid:` 直接拒绝 `pid <= 1`、拒绝自己；`killApp:` 再拒一次系统 App；候选列表先按守护进程名单过滤。就算点了「一键加速」，也动不到 `launchd`/`SpringBoard`。
4. **不改系统文件。** 全部写操作只落在 `/var/mobile/Library/Preferences/cn.bswbw.RealBG.plist` 这一个文件里。
5. **TrollStore 装的是普通 App。** 不替换系统 App、不改 `SpringBoard`、不装 LaunchDaemon，出问题删掉 App 就恢复。

真要说风险，只有一条：**杀后台太狠会让某些 App 冷启动变慢**（内存是省下来了，代价是重开要重新加载）。所以默认跳过系统 App、跳过 8MB 以下、跳过真后台白名单，把误伤面压到最小。

---

## 五、测试与验证（都是真实跑过的，不是"应该没问题"）

### 1. 产物硬校验 `tests/verify_tipa.py`（读真实字节）

对着 CI 出来的 `RealBG.tipa`（85,313 B）跑，结果：

```
V1 包结构            Info.plist 1620 B / RealBG 308560 B / 图标 3 个
V2 Info.plist        cn.bswbw.RealBG · 真后台 Pro · 1.0.0(1) · iOS15.0 · 1,2
V3 Mach-O            FAT 2 切片：arm64 MH_EXECUTE 146048 B
                                  arm64e MH_EXECUTE 144720 B
V4 签名 entitlements  两个切片各解出 12 条（解 LC_CODE_SIGNATURE -> SuperBlob type5）
V5 危险权限          12 项全部为 0
V6 后门标记          com.example.myPort / CFMessagePort* / com.shadow.getEspDataQueue 全无
```

`V4` 不是"搜字符串有没有"，是真的把代码签名里的 SuperBlob 解开、把 entitlements 反序列化出来看的，12 条逐条列在脚本输出里。

### 2. 源码逻辑测试 `tests/test_logic.py`（61 项，全通过）

不是复述代码，而是**从真实源文件里解析出白名单/阈值/守卫**，再用这些真实数据跑判定：

| 分组 | 覆盖 |
|---|---|
| 白名单完整性 | 从 `RBProcesses.m` 抠出 35 条守护进程 + 28 条系统 App，逐条断言 launchd / SpringBoard / backboardd / runningboardd / frontboardd / securityd / tccd / cfprefsd / installd / watchdogd 都在 |
| 杀进程守卫 | `pid<=1` 拒绝、`pid==getpid()` 拒绝、EPERM 降级 SIGTERM、`killApp:` 二次拦截 |
| 一键加速过滤 | 阈值读的是源码里的 `mb < 8`；用混合进程表验证「微信 480MB 留、抖音 6MB 跳过、真后台白名单跳过、SpringBoard 跳过」 |
| 后门回归 | 去注释后扫 `task_for_pid` / `processor_set_tasks` / `CFMessagePort` / `NSURLSession` / `http` / `trollstorehelper` / `MSHookFunction` / `dlopen`，全部为 0 |
| 配置路径 | 写入是 `cn.bswbw.RealBG.plist`；`com.thefool.app.plist` 只出现在 `dictionaryWithContentsOfFile:legacy` 一行，无 `writeToFile:legacy` |
| entitlements | 条数 = 12，7 项高危 + `hid.*` 全部不在 |
| 结构 | 8 个源文件齐、`ARCHS := arm64 arm64e`、application 目标（不是 tweak） |

CI 里两步都挂了：先跑 `test_logic.py`，出包后再跑 `verify_tipa.py`，任一失败就构建失败 —— 也就是说 dist 分支上的包，一定是这两关都过的。

### 3. 真机验收（需要你在 iPhone 上做，脚本没法代替）

以下 8 项必须真机点，静态分析无法覆盖：

| # | 步骤 | 期望 |
|---|---|---|
| 1 | TrollStore 装 `RealBG.tipa` | 出现在桌面，名字「真后台 Pro」，能打开不闪退 |
| 2 | 打开微信 → 回本 App，右滑微信 → **开启真后台** | 提示「微信 已进入真后台」 |
| 3 | 切回微信，再按 Home 回桌面，等 2 分钟 | 微信**没被回收**，切回来还在原页面 |
| 4 | 底部看内存标签 | 三个数字都非 0，且「可用」与「已用」之和接近物理内存 |
| 5 | 点 **一键加速** | 弹窗列出候选进程与各自 MB，数字非 0 |
| 6 | 确认加速 | 弹结果：结束 N 个、释放 X MB、可用 before→after |
| 7 | 加速后再看微信（若已加真后台） | **仍然活着**（白名单生效） |
| 8 | 重启手机，再打开本 App | 之前加「自启」的 App 若在运行，日志里 `自启真后台已恢复` |

第 1 项过不了（闪退）→ 多半是 iOS 版本与 `UIRootWindowScenePresentationBinder` 的类名差异，把 `设置 → 隐私 → 分析与改进 → 分析数据` 里的 `RealBG` 崩溃日志给我，能直接定位。
第 3 项过不了 → 那台系统的 FBScene 路径变了，会看到日志「scene 方案异常」，会自动退回 RBS assertion 兜底（保活但 UI 状态可能重载）。

## 六、目录结构

```
Makefile                  Theos application 工程
entitlements.plist        10 条权限（逐条注释了为什么需要）
src/RB.h                  公共接口
src/rbproc.h              libproc 声明兜底（SDK 缺头文件时自己声明）
src/main.m                入口：装 UI → 恢复自启真后台 → 可选启动加速
src/RBStore.m             配置持久化（修掉原包写死路径的 bug）+ RBLog/RBHumanMB
src/RBProcesses.m         应用枚举 / 进程枚举 / 杀进程 / 内存统计
src/RBBackstage.m         真后台：FBScene 挂载 + RBS assertion 兜底
src/RBBooster.m           一键加速（新增）
src/RBRootVC.m            主界面：分段筛选 + 搜索 + 左右滑操作 + 底部加速条
RealBG/Info.plist         包信息（cn.bswbw.RealBG，真后台 Pro，1.0.0）
RealBG/AppIcon*.png       图标 60/120/180
tests/test_logic.py       源码逻辑测试（61 项：白名单/守卫/后门回归）
tests/verify_tipa.py      产物硬校验（结构/Mach-O/签名 entitlements/后门标记）
.github/workflows/build.yml  Theos 编译 → 组 .app → ldid 签 → 打 tipa → 硬校验 → 推 dist 分支
```

## 七、构建

CI 在 macOS runner 上跑 Theos，产物推到 `dist` 分支：

```
RealBG.tipa    （TrollStore 用这个）
RealBG.ipa     （同样的内容，给别的安装器）
```

本地构建（macOS + Theos）：

```bash
export THEOS=~/theos
make clean && make FINALPACKAGE=1
APP=.theos/obj/RealBG.app
cp RealBG/Info.plist "$APP/"
cp RealBG/*.png "$APP/"
ldid -Sentitlements.plist "$APP/RealBG"
mkdir -p Payload && cp -R "$APP" Payload/ && zip -qry RealBG.tipa Payload
```

## 八、用法

1. TrollStore 装 `RealBG.tipa`
2. 打开要保活的 App，回本 App 里左滑 → **开启真后台**（或点右上「全部真后台」一键给所有运行中的 App 挂上）
3. 想省内存：右滑 **杀后台**；或直接点底部 **一键加速** 批量清
4. 「自启」列表里的 App，下次本 App 启动时会自动重新挂真后台
