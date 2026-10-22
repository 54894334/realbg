#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""m6_strdec.py — 静态还原运行时 XOR 字符串

App 里所有敏感字符串都是形如：
    adrp x8, #page ; add x8, x8, #src
    adrp x9, #page ; add x9, x9, #dst
    ldrb w10, [x8, #i] ; mov w11, #k ; eor w10, w10, w11 ; strb w10, [x9, #i]
的"解密桩"。这里按指令模式把 (src, dst, key[]) 抠出来直接解，比模拟器全。
"""
import struct, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m0_fixups import MachO
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from capstone.arm64 import ARM64_OP_REG, ARM64_OP_IMM, ARM64_OP_MEM

PATH = os.environ.get('TARGET_BIN', 'x/Payload/RealBackstage.app/RealBackstage')
m = MachO(PATH)
d = m.d
md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
md.detail = True

a, size, off = m.sects['__text']
code = d[off:off + size]


def run():
    reg_page = {}     # reg -> page
    reg_addr = {}     # reg -> absolute addr
    reg_imm = {}      # reg -> immediate
    last_ldrb = {}    # reg(w) -> (addr, index)
    tables = {}       # (src_addr, dst_addr) -> {index: key}

    for ins in md.disasm(code, a):
        ops = ins.operands
        mn = ins.mnemonic
        if mn == 'adrp' and len(ops) == 2 and ops[1].type == ARM64_OP_IMM:
            r = ins.reg_name(ops[0].reg)
            reg_page[r] = ops[1].imm
            reg_addr.pop(r, None)
        elif mn == 'add' and len(ops) == 3 and ops[2].type == ARM64_OP_IMM \
                and ops[1].type == ARM64_OP_REG:
            b = ins.reg_name(ops[1].reg)
            t = ins.reg_name(ops[0].reg)
            if b in reg_page:
                reg_addr[t] = reg_page[b] + ops[2].imm
        elif mn == 'mov' and len(ops) == 2 and ops[1].type == ARM64_OP_IMM:
            reg_imm[ins.reg_name(ops[0].reg)] = ops[1].imm & 0xFFFFFFFF
        elif mn in ('movk',) and len(ops) == 3:
            r = ins.reg_name(ops[0].reg)
            imm = ops[1].imm & 0xFFFF
            sh = 0
            if len(ops) > 2 and ops[2].type == ARM64_OP_IMM:
                sh = ops[2].imm
            cur = reg_imm.get(r, 0)
            reg_imm[r] = (cur & ~(0xFFFF << sh)) | (imm << sh)
        elif mn == 'eor' and len(ops) == 3 and ops[2].type == ARM64_OP_IMM:
            # 立即数形态：eor w10, w10, #0x7f —— 一半的字符用这种写法，必须一起处理
            src = ins.reg_name(ops[1].reg)
            if src in last_ldrb:
                addr, idx = last_ldrb[src]
                last_ldrb['__xor__'] = (addr, idx, ops[2].imm & 0xFFFFFFFF)
                reg_imm.pop(ins.reg_name(ops[0].reg), None)
        elif mn == 'eor' and len(ops) == 3 and ops[2].type == ARM64_OP_REG:
            src = ins.reg_name(ops[1].reg)
            key = ins.reg_name(ops[2].reg)
            dst = ins.reg_name(ops[0].reg)
            if src in last_ldrb and reg_imm.get(key) is not None:
                addr, idx = last_ldrb[src]
                kval = reg_imm[key]
                reg_imm.pop(dst, None)   # 结果不再是指令里的立即数
                last_ldrb['__xor__'] = (addr, idx, kval)
        elif mn == 'ldrb' and len(ops) == 2 and ops[1].type == ARM64_OP_MEM:
            mem = ops[1].mem
            base = ins.reg_name(mem.base) if mem.base else ''
            if base in reg_addr:
                reg_addr[ins.reg_name(ops[0].reg)] = None
                last_ldrb[ins.reg_name(ops[0].reg)] = (reg_addr[base] + mem.disp, mem.disp)
        elif mn == 'strb' and len(ops) == 2 and ops[1].type == ARM64_OP_MEM:
            mem = ops[1].mem
            base = ins.reg_name(mem.base) if mem.base else ''
            srcr = ins.reg_name(ops[0].reg)
            if base in reg_addr and '__xor__' in last_ldrb:
                saddr, sidx, key = last_ldrb['__xor__']
                if sidx == mem.disp:
                    dst_addr = reg_addr[base] + mem.disp
                    tables.setdefault((saddr - sidx, dst_addr - sidx), {})[sidx] = key
                    last_ldrb.pop('__xor__', None)

    results = []
    for (src, dst), keys in sorted(tables.items()):
        n = max(keys) + 1
        raw = b''
        ok = True
        for i in range(n):
            if i not in keys:
                ok = False
                break
            o = m.vm_to_off(src + i)
            if o is None:
                ok = False
                break
            raw += bytes([d[o] ^ (keys[i] & 0xFF)])
        if not ok or not raw:
            continue
        try:
            s = raw.split(b'\0')[0].decode('utf-8')
        except Exception:
            continue
        if len(s) >= 3 and all(ch.isprintable() for ch in s):
            results.append((src, dst, s))
    return results


if __name__ == '__main__':
    res = run()
    print('解出 %d 条字符串' % len(res))
    seen = set()
    for src, dst, s in res:
        if s in seen:
            continue
        seen.add(s)
        print('%#010x -> %r' % (src, s))
