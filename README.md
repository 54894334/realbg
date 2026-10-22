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

## 五、目录结构

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
.github/workflows/build.yml  Theos 编译 → 组 .app → ldid 签 → 打 tipa → 推 dist 分支
```

## 六、构建

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

## 七、用法

1. TrollStore 装 `RealBG.tipa`
2. 打开要保活的 App，回本 App 里左滑 → **开启真后台**（或点右上「全部真后台」一键给所有运行中的 App 挂上）
3. 想省内存：右滑 **杀后台**；或直接点底部 **一键加速** 批量清
4. 「自启」列表里的 App，下次本 App 启动时会自动重新挂真后台
