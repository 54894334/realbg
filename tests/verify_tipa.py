#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
verify_tipa.py — 交付前对 tipa 做硬校验（全部读真实字节，不做字符串猜测）

用法：
  python3 tests/verify_tipa.py RealBG.tipa --app RealBG --bundle cn.bswbw.RealBG --version 1.2.0
  python3 tests/verify_tipa.py RealBGLite.tipa --app RealBGLite --bundle cn.bswbw.RealBGLite --version 1.0

  V1  zip 完整性 / Payload/<App>.app 结构
  V2  Info.plist 关键字段
  V3  Mach-O 头（thin/fat、cputype、filetype=MH_EXECUTE、cryptid、LC_MAIN）
  V4  从 LC_CODE_SIGNATURE -> SuperBlob 解出真正签进去的 entitlements，逐条列出
  V5  entitlements 必含项 / 危险项（照原包 1.5 的越权清单）
  V6  后门标记必须为 0
  V7  LC_LOAD_DYLIB 只允许系统公开库 —— 只要出现 PrivateFrameworks 或
      FrontBoard / RunningBoard / SpringBoard 这类私有框架，dyld 在没装对应
      系统的设备上就会立刻杀掉进程，是「点开闪退」的头号原因
"""
import sys, os, struct, zipfile, plistlib, argparse

MUST_HAVE = [
    "platform-application",
    "com.apple.private.security.no-sandbox",
    "com.apple.private.security.storage.AppBundles",
    "com.apple.private.security.storage.AppDataContainers",
    "com.apple.backboard.client",
    "com.apple.QuartzCore.displayable-context",
    "com.apple.QuartzCore.secure-mode",
    "com.apple.springboard.accessibility-window-hosting",
    "com.apple.springboard-ui.client",
    "com.apple.runningboard.terminateprocess",
    "com.apple.runningboard.process-state",
    "com.apple.runningboard.targetidentities",
    "com.apple.runningboard.assertions.frontboard",
    "com.apple.runningboard.launchprocess",
    "com.apple.frontboard.launchapplications",
    "com.apple.security.exception.mach-lookup.global-name",
]

# 原包 1.5 有、本包必须为 0 的越权项
MUST_NOT_HAVE = [
    "task_for_pid-allow",
    "com.apple.system-task-ports",
    "com.apple.system-task-ports.control",
    "proc_info-allow",
    "get-task-allow",
    "com.apple.security.get-task-allow",
    "com.apple.private.persona-mgmt",
    "com.apple.private.kernel.jetsam",
    "com.apple.private.memorystatus",
    "com.apple.private.hid.client.event-monitor",
    "com.apple.private.hid.client.event-dispatch",
    "com.apple.private.hid.client.event-filter",
    "com.apple.private.hid.client.service-protected",
    "com.apple.private.hid.manager.client",
    "com.apple.private.allow-background-haptics",
    "com.apple.runningboard.hereditarygrantoriginator",
    "com.apple.runningboard.primitiveattribute",
    # 加了 no-container 就没有沙盒容器了。原包 1.5 根本没有这一条，
    # TrollStore 官方也说明 no-sandbox 单独就够（第三个是推荐项）。
    "com.apple.private.security.no-container",
]

BACKDOOR_MARKERS = [
    "com.example.myPort",
    "com.shadow.getEspDataQueue",
    "CFMessagePortCreateLocal",
    "CFMessagePortCreateRemote",
    "CFMessagePortCreateRemoteWithOptions",
]
LEGACY_READ_ONLY = ["com.thefool.app.plist"]

# 允许出现在 LC_LOAD_DYLIB 里的库（只放系统公开框架）
ALLOWED_DYLIB_PREFIXES = (
    "/usr/lib/",
    "/System/Library/Frameworks/Foundation.framework/",
    "/System/Library/Frameworks/UIKit.framework/",
    "/System/Library/Frameworks/CoreFoundation.framework/",
    "/System/Library/Frameworks/CoreGraphics.framework/",
    "/System/Library/Frameworks/QuartzCore.framework/",
    "/System/Library/Frameworks/CFNetwork.framework/",
    "/System/Library/Frameworks/Security.framework/",
    "/System/Library/Frameworks/ImageIO.framework/",
    "/System/Library/Frameworks/MobileCoreServices.framework/",
    "/System/Library/Frameworks/CoreServices.framework/",
    "/System/Library/Frameworks/AVFoundation.framework/",
    "/System/Library/Frameworks/AVFAudio.framework/",
    "/System/Library/Frameworks/AudioToolbox.framework/",
    "/System/Library/Frameworks/MediaPlayer.framework/",
    "/System/Library/Frameworks/UIKit.framework/",
    "/System/Library/Frameworks/WebKit.framework/",
    "/System/Library/Frameworks/SafariServices.framework/",
    "/System/Library/Frameworks/CoreImage.framework/",
    "/System/Library/Frameworks/Accelerate.framework/",
    "/System/Library/Frameworks/UniformTypeIdentifiers.framework/",
)

fails, warns = [], []


def ok(m):
    print("  \033[32mOK\033[0m   " + m)


def bad(m):
    print("  \033[31mFAIL\033[0m " + m)
    fails.append(m)


def warn(m):
    print("  \033[33mWARN\033[0m " + m)
    warns.append(m)


def cut_fat(data):
    magic = struct.unpack_from(">I", data, 0)[0]
    out = []
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        n = struct.unpack_from(">I", data, 4)[0]
        wide = magic == 0xCAFEBABF
        for i in range(n):
            if wide:
                cpu, sub, foff, size = struct.unpack_from(">iiQQ", data, 8 + i * 32)
                ft = struct.unpack_from("<I", data, foff + 12)[0]
            else:
                cpu, sub, foff, size, _ = struct.unpack_from(">iiIII", data, 8 + i * 20)
                ft = struct.unpack_from("<I", data, foff + 12)[0]
            low = sub & 0x00FFFFFF
            name = "arm64" if low == 0 else ("arm64e" if low == 2 else "sub%d" % low)
            out.append((name, data[foff:foff + size], ft))
    else:
        if struct.unpack_from("<I", data, 0)[0] in (0xFEEDFACF, 0xFEEDFACE):
            cpu, sub, ft = struct.unpack_from("<iiI", data, 4)
            low = sub & 0x00FFFFFF
            name = "arm64" if low == 0 else "arm64e"
            out.append((name, data, ft))
        else:
            return None
    return out


def parse_cmds(slice_bytes):
    """一次性把 load command 都取出来，后面几项校验共用"""
    ncmds = struct.unpack_from("<I", slice_bytes, 16)[0]
    off = 32
    dylibs, info = [], {}
    for _ in range(ncmds):
        if off + 8 > len(slice_bytes):
            break
        cmd, csz = struct.unpack_from("<II", slice_bytes, off)
        if csz < 8:
            break
        if cmd in (0xC, 0xD, 0x8000001F, 0x21):     # LC_LOAD_DYLIB / ID / REEXPORT / LAZY
            noff = struct.unpack_from("<I", slice_bytes, off + 8)[0]
            end = slice_bytes.find(b"\0", off + noff)
            try:
                dylibs.append(slice_bytes[off + noff:end].decode("utf8", "replace"))
            except Exception:
                pass
        elif cmd == 0x1D:                            # LC_CODE_SIGNATURE
            info["sig"] = struct.unpack_from("<II", slice_bytes, off + 8)
        elif cmd == 0x2C:                            # LC_ENCRYPTION_INFO_64
            _, _, cryptid, _ = struct.unpack_from("<IIII", slice_bytes, off + 8)
            info["cryptid"] = cryptid
        elif cmd == 0x2B:                            # LC_ENCRYPTION_INFO
            _, _, cryptid = struct.unpack_from("<III", slice_bytes, off + 8)
            info.setdefault("cryptid", cryptid)
        elif cmd == 0x80000028:                      # LC_MAIN
            info["main"] = struct.unpack_from("<QQ", slice_bytes, off + 8)
        elif cmd == 0x32:                            # LC_BUILD_VERSION
            p, mi, sk, nt = struct.unpack_from("<IIII", slice_bytes, off + 8)
            info["platform"] = p
            info["minos"] = "%d.%d.%d" % (mi >> 16, (mi >> 8) & 0xFF, mi & 0xFF)
            info["sdk"] = "%d.%d.%d" % (sk >> 16, (sk >> 8) & 0xFF, sk & 0xFF)
        elif cmd == 0x80000034:
            info["chained_fixups"] = True
        off += csz
    return dylibs, info


def entitlements_of(sig):
    """SuperBlob(0xfade0cc0) -> blob type 5 = XML entitlements"""
    if not sig or len(sig) < 12:
        return None, "没有 LC_CODE_SIGNATURE"
    if struct.unpack_from(">I", sig, 0)[0] != 0xFADE0CC0:
        return None, "SuperBlob magic 不对（可能没签名）"
    count = struct.unpack_from(">I", sig, 8)[0]
    for i in range(count):
        btype, boff = struct.unpack_from(">II", sig, 12 + i * 8)
        if btype != 5:
            continue
        bmagic, blen = struct.unpack_from(">II", sig, boff)
        if bmagic != 0xFADE7171:
            continue
        try:
            return plistlib.loads(sig[boff + 8: boff + blen]), None
        except Exception as e:
            return None, "entitlements 解析失败: %s" % e
    return None, "签名里没有 type5(entitlements) blob"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tipa")
    ap.add_argument("--app", default="RealBG")
    ap.add_argument("--bundle", default="cn.bswbw.RealBG")
    ap.add_argument("--version", default="1.2.0")
    ap.add_argument("--lite", action="store_true", help="探针包：不要求文件共享与日志")
    a = ap.parse_args()

    APP = a.app
    base = "Payload/%s.app/" % APP
    exe_path = base + APP
    path = a.tipa

    print("→ 校验 %s（app=%s）\n" % (path, APP))
    if not os.path.exists(path):
        print("文件不存在"); return 2
    if os.path.getsize(path) == 0:
        print("文件是 0 字节"); return 2

    # ---------- V1 ----------
    print("V1 包结构")
    try:
        z = zipfile.ZipFile(path)
    except Exception as e:
        bad("不是合法 zip: %s" % e); return 2
    names = z.namelist()
    for n in (base + "Info.plist", exe_path):
        (ok if n in names else bad)("%s (%d B)" % (n, z.getinfo(n).file_size if n in names else 0))
    icons = sorted(n for n in names if n.startswith(base + "AppIcon") and n.endswith(".png"))
    (ok if len(icons) >= 1 else warn)("图标 %d 个" % len(icons))
    junk = [n for n in names if n.startswith("__MACOSX") or "/._" in n]
    if junk:
        bad("包内有 macOS 垃圾条目 %d 个（会干扰 TrollStore 解包）" % len(junk))
    else:
        ok("无 __MACOSX / ._ 垃圾条目")
    if exe_path not in names:
        print("\n缺可执行文件，后续无法继续"); return 2

    # ---------- V2 ----------
    print("\nV2 Info.plist")
    ip_raw = z.read(base + "Info.plist")
    ip = plistlib.loads(ip_raw)
    (ok if ip.get("CFBundleIdentifier") == a.bundle else bad)(
        "CFBundleIdentifier = %r（期望 %s）" % (ip.get("CFBundleIdentifier"), a.bundle))
    (ok if ip.get("CFBundleExecutable") == APP else bad)(
        "CFBundleExecutable = %r（期望 %s，文件名必须一致，否则启动即退）" % (ip.get("CFBundleExecutable"), APP))
    (ok if ip.get("CFBundleShortVersionString") == a.version else bad)(
        "版本 = %r（期望 %s）" % (ip.get("CFBundleShortVersionString"), a.version))
    ok("build = %s" % ip.get("CFBundleVersion"))
    (ok if ip.get("CFBundlePackageType") == "APPL" else bad)(
        "CFBundlePackageType = %r" % ip.get("CFBundlePackageType"))
    (ok if "iPhoneOS" in (ip.get("CFBundleSupportedPlatforms") or []) else bad)(
        "CFBundleSupportedPlatforms = %r" % (ip.get("CFBundleSupportedPlatforms"),))
    ok("MinimumOSVersion = %s  UIDeviceFamily = %s" % (ip.get("MinimumOSVersion"), ip.get("UIDeviceFamily")))
    if "<key>UIRequiresFullScreen</key>" in ip_raw.decode("utf-8", "replace"):
        bad("仍然声明 UIRequiresFullScreen（iPad 上要求四方向，只写竖屏会断言崩溃）")
    else:
        ok("未声明 UIRequiresFullScreen")
    if not a.lite:
        (ok if ip.get("UIFileSharingEnabled") else warn)(
            "UIFileSharingEnabled = %r（System 注册下 iOS 本就不显示共享目录，仅备用）"
            % ip.get("UIFileSharingEnabled"))

    # ---------- V3 ----------
    print("\nV3 Mach-O")
    bin_data = z.read(exe_path)
    slices = cut_fat(bin_data)
    if not slices:
        bad("认不出 Mach-O 头"); return 2
    ok("%s，%d 个切片，共 %d B" % ("FAT" if len(slices) > 1 else "thin", len(slices), len(bin_data)))

    all_ents = None
    for name, sb, ft in slices:
        ftn = {2: "MH_EXECUTE", 6: "MH_DYLIB"}.get(ft, str(ft))
        dylibs, info = parse_cmds(sb)
        cryptid = info.get("cryptid", 0)
        (ok if ft == 2 else bad)("  %-7s %-11s %d B" % (name, ftn, len(sb)))
        (ok if cryptid == 0 else bad)("  %-7s cryptid = %d（必须 0；非 0 表示还带 FairPlay 加密壳）" % (name, cryptid))
        (ok if "main" in info else bad)("  %-7s LC_MAIN %s" % (name, "存在" if "main" in info else "缺失（没有入口点，启动即退）"))
        ok("  %-7s platform=%s minos=%s sdk=%s %s" % (
            name, info.get("platform"), info.get("minos"), info.get("sdk"),
            "chained_fixups" if info.get("chained_fixups") else "classic")))

        sig = info.get("sig")
        if sig:
            e, err = entitlements_of(bin_data if len(slices) == 1 else sb[sig[0]:sig[0] + sig[1]])
            if e:
                ok("  %-7s 签名解出 %d 条 entitlements" % (name, len(e)))
                if all_ents is None:
                    all_ents = e
            else:
                warn("  %-7s %s" % (name, err))
        else:
            bad("  %-7s 没有 LC_CODE_SIGNATURE（未签名，装上去必闪退）" % name)

        # ---------- V7 ----------
        print("V7 %s 切片依赖的库" % name)
        bads = []
        for d in dylibs:
            if d.startswith(ALLOWED_DYLIB_PREFIXES):
                print("       · %s" % d)
            else:
                bads.append(d)
        for d in bads:
            bad("  不允许的依赖: %s" % d)
        if not bads:
            ok("  全部是系统公开库（%d 个），无私有框架" % len(dylibs))

    slice_names = [n for n, _, _ in slices]
    if "arm64e" in slice_names:
        bad("产物里有 arm64e 切片（TrollStore 的 ldid 不覆盖 PAC，是秒退高发区）")
    else:
        ok("没有 arm64e 切片")
    (ok if "arm64" in slice_names else bad)("有 arm64 切片")

    # ---------- V4 ----------
    print("\nV4 签名里的 entitlements（解 SuperBlob，不是查字符串）")
    ents = all_ents
    if ents is None:
        bad("拿不到 entitlements")
        ents = {}
    else:
        for k in sorted(ents):
            print("       · %s = %s" % (k, ents[k] if not isinstance(ents[k], list) else "array[%d]" % len(ents[k])))
        print()
        if not a.lite:
            for k in MUST_HAVE:
                (ok if k in ents else bad)("必须有: %s" % k)
        else:
            (ok if "platform-application" in ents else bad)("探针包必须有 platform-application")
            (ok if "com.apple.private.security.no-sandbox" in ents else bad)("探针包必须有 no-sandbox")
            (ok if len(ents) <= 4 else warn)("探针包权限数 = %d（越少越能证明问题不在权限）" % len(ents))

    # ---------- V5 ----------
    print("\nV5 危险权限（原包 1.5 有，本包必须为 0）")
    for k in MUST_NOT_HAVE:
        if k in ents:
            bad("仍然存在: %s" % k)
        else:
            ok("已剔除: %s" % k)

    # ---------- V6 ----------
    print("\nV6 后门标记回归")
    for k in BACKDOOR_MARKERS:
        (bad if k.encode() in bin_data else ok)("无 %s" % k)
    if not a.lite:
        for k in LEGACY_READ_ONLY:
            if k.encode() in bin_data:
                warn("%s —— 仅用于只读迁移原版配置，不写入" % k)
            else:
                ok("无 %s" % k)

    print("\n" + "=" * 60)
    if fails:
        print("结果：\033[31m%d 项不通过\033[0m，%d 项提醒" % (len(fails), len(warns)))
        for f in fails:
            print("  · " + f)
        return 1
    print("结果：\033[32m全部通过\033[0m" + ("（%d 项提醒）" % len(warns) if warns else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
