#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
verify_realbg.py — 交付前对 RealBG.tipa 做硬校验（不读猜测，全部读真实字节）

用法： python verify_realbg.py <RealBG.tipa>

  V1  zip 完整性 / Payload/RealBG.app 结构（Info.plist、可执行文件、图标）
  V2  Info.plist 关键字段
  V3  Mach-O 头（fat/thin、cputype+cpusubtype 精确到 arm64/arm64e、filetype=MH_EXECUTE）
  V4  从 LC_CODE_SIGNATURE -> SuperBlob 解出**真正签进去的** entitlements，逐条列出
  V5  entitlements 危险项必须为 0（对照原包 1.5 的越权清单）
  V6  后门标记必须为 0；旧配置读取路径单独列出（只读，不算后门）
"""
import sys, os, struct, zipfile, plistlib

EXPECT_INFO = {"CFBundleIdentifier": "cn.bswbw.RealBG", "CFBundleExecutable": "RealBG"}

MUST_HAVE = [
    "platform-application",
    "com.apple.private.security.no-sandbox",
    "com.apple.runningboard.terminateprocess",
    "com.apple.runningboard.process-state",
    "com.apple.runningboard.targetidentities",
    "com.apple.runningboard.assertions.frontboard",
    "com.apple.runningboard.launchprocess",
    "com.apple.frontboard.launchapplications",
    "com.apple.springboard-ui.client",
    "com.apple.private.security.storage.AppBundles",
    "com.apple.private.security.storage.AppDataContainers",
    "com.apple.security.exception.mach-lookup.global-name",
]

MUST_NOT_HAVE = [
    "task_for_pid-allow",
    "com.apple.system-task-ports",
    "com.apple.system-task-ports.control",
    "proc_info-allow",
    "get-task-allow",
    "com.apple.private.persona-mgmt",
    "com.apple.private.kernel.jetsam",
    "com.apple.private.memorystatus",
    "com.apple.private.hid.client.event-monitor",
    "com.apple.private.hid.client.event-dispatch",
    "com.apple.private.hid.manager",
    "com.apple.private.hid.client.service",
]

BACKDOOR_MARKERS = [
    "com.example.myPort",
    "com.shadow.getEspDataQueue",
    "CFMessagePortCreateLocal",
    "CFMessagePortCreateRemote",
    "CFMessagePortCreateRemoteWithOptions",
]
# 只读兼容：只为把原版 1.5 的白名单读过来，不写这个文件、不依赖它的存在
LEGACY_READ_ONLY = ["com.thefool.app.plist"]

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
    """返回 [(标签, 切片字节)]，fat/thin 都处理"""
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
            name = "arm64" if (sub & 0x00FFFFFF) == 0 else ("arm64e" if (sub & 0x00FFFFFF) == 2 else "sub%d" % (sub & 0xFFFFFF))
            out.append((name, data[foff:foff + size], ft))
    else:
        if struct.unpack_from("<I", data, 0)[0] in (0xFEEDFACF, 0xFEEDFACE):
            cpu, sub, ft = struct.unpack_from("<iiI", data, 4)
            name = "arm64" if (sub & 0x00FFFFFF) == 0 else "arm64e"
            out.append((name, data, ft))
        else:
            return None
    return out


def entitlements_of(slice_bytes):
    """解 LC_CODE_SIGNATURE -> SuperBlob(0xfade0cc0) -> blob type 5 = XML entitlements"""
    magic, cputype, cpusub, ft, ncmds, szcmds, flags = struct.unpack_from("<IiiIIII", slice_bytes, 0)
    off = 32
    lc = None
    for _ in range(ncmds):
        cmd, csz = struct.unpack_from("<II", slice_bytes, off)
        if cmd == 0x1D:  # LC_CODE_SIGNATURE
            dataoff, datasize = struct.unpack_from("<II", slice_bytes, off + 8)
            lc = (dataoff, datasize)
            break
        off += csz
    if not lc:
        return None, "没有 LC_CODE_SIGNATURE"
    dataoff, datasize = lc
    sig = slice_bytes[dataoff:dataoff + datasize]
    if len(sig) < 12 or struct.unpack_from(">I", sig, 0)[0] != 0xFADE0CC0:
        return None, "SuperBlob magic 不对（可能没签名）"
    count = struct.unpack_from(">I", sig, 8)[0]
    for i in range(count):
        btype, boff = struct.unpack_from(">II", sig, 12 + i * 8)
        if btype != 5:
            continue
        bmagic, blen = struct.unpack_from(">II", sig, boff)
        if bmagic != 0xFADE7171:
            continue
        xml = sig[boff + 8: boff + blen]
        try:
            return plistlib.loads(xml), None
        except Exception as e:
            return None, "entitlements 解析失败: %s" % e
    return None, "签名里没有 type5(entitlements) blob"


def main(path):
    print("→ 校验 %s\n" % path)
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
    for n in ("Payload/RealBG.app/Info.plist", "Payload/RealBG.app/RealBG"):
        if n in names:
            ok("%s (%d B)" % (n, z.getinfo(n).file_size))
        else:
            bad("缺 %s" % n)
    icons = sorted(n for n in names if n.startswith("Payload/RealBG.app/AppIcon") and n.endswith(".png"))
    (ok if len(icons) >= 3 else bad)("图标 %d 个：%s" % (len(icons), ", ".join(os.path.basename(i) for i in icons)))
    junk = [n for n in names if n.startswith("__MACOSX") or "/._" in n]
    if junk:
        warn("包内有 macOS 垃圾条目 %d 个" % len(junk))
    if "Payload/RealBG.app/RealBG" not in names:
        return 2

    # ---------- V2 ----------
    print("\nV2 Info.plist")
    ip = plistlib.loads(z.read("Payload/RealBG.app/Info.plist"))
    for k, v in EXPECT_INFO.items():
        (ok if ip.get(k) == v else bad)("%s = %r" % (k, ip.get(k)))
    ok("显示名 = %r" % ip.get("CFBundleDisplayName"))
    ok("版本 = %s (build %s)" % (ip.get("CFBundleShortVersionString"), ip.get("CFBundleVersion")))
    ok("MinimumOSVersion = %s  UIDeviceFamily = %s" % (ip.get("MinimumOSVersion"), ip.get("UIDeviceFamily")))

    # ---------- V3 ----------
    print("\nV3 Mach-O")
    bin_data = z.read("Payload/RealBG.app/RealBG")
    slices = cut_fat(bin_data)
    if not slices:
        bad("认不出 Mach-O 头"); return 2
    ok("%s，%d 个切片，共 %d B" % ("FAT" if len(slices) > 1 else "thin", len(slices), len(bin_data)))
    for name, sb, ft in slices:
        ftn = {2: "MH_EXECUTE", 6: "MH_DYLIB"}.get(ft, str(ft))
        (ok if ft == 2 else bad)("  %-7s %-11s %d B" % (name, ftn, len(sb)))

    # ---------- V4 ----------
    print("\nV4 签名里的 entitlements（解 SuperBlob，不是查字符串）")
    ents = None
    for name, sb, ft in slices:
        e, err = entitlements_of(sb)
        if e:
            ok("%s 切片解出 %d 条权限" % (name, len(e)))
            ents = e if ents is None else ents
        else:
            warn("%s 切片：%s" % (name, err))
    if ents is None:
        bad("拿不到 entitlements")
    else:
        for k in sorted(ents):
            v = ents[k]
            print("       · %s = %s" % (k, "true" if v is True else (v if not isinstance(v, list) else v)))
        print()
        for k in MUST_HAVE:
            (ok if k in ents else bad)("必须有: %s" % k)

    # ---------- V5 ----------
    print("\nV5 危险权限（原包 1.5 有，本包必须为 0）")
    have = ents or {}
    blob = bin_data
    for k in MUST_NOT_HAVE:
        if k in have or k.encode() in blob:
            bad("仍然存在: %s" % k)
        else:
            ok("已剔除: %s" % k)

    # ---------- V6 ----------
    print("\nV6 后门标记回归")
    for k in BACKDOOR_MARKERS:
        (bad if k.encode() in blob else ok)("无 %s" % k)
    print()
    for k in LEGACY_READ_ONLY:
        if k.encode() in blob:
            warn("%s —— 仅用于读取原版 1.5 的旧配置（只读迁移），不写入、不依赖" % k)
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
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "RealBG.tipa"))
