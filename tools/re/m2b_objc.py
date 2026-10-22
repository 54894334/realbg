#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""m2b_objc.py — 在 chained-fixups 二进制上还原 ObjC 元数据

输出 analysis/objc2.txt（可读）与 analysis/objc2.json（结构化）。
支持：class_t / class_ro_t / method_list（含 relative 小方法列表）/
      ivar_list / property_list / protocol_list / category
"""
import struct, sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m0_fixups import MachO

PATH = sys.argv[1] if len(sys.argv) > 1 else 'x/Payload/RealBackstage.app/RealBackstage'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'analysis')
m = MachO(PATH)
d = m.d


def u32(vm):
    o = m.vm_to_off(vm)
    return None if o is None else struct.unpack_from('<I', d, o)[0]


def u64(vm):
    o = m.vm_to_off(vm)
    return None if o is None else struct.unpack_from('<Q', d, o)[0]


def i32(vm):
    o = m.vm_to_off(vm)
    return None if o is None else struct.unpack_from('<i', d, o)[0]


def resolve(vm):
    """槽位 -> 最终 vm 地址（rebase）或符号名（bind）"""
    if vm == 0:
        return None
    r = m.ptr(vm)
    if r is None:
        return None
    if r[0] == 'bind':
        return r[1]
    return r[1]


def pstr(vm):
    r = resolve(vm)
    if not isinstance(r, int):
        return None
    return m.cstr(r)


TYPE_MAP = {
    'c': 'char', 'i': 'int', 's': 'short', 'l': 'long', 'q': 'long long',
    'C': 'unsigned char', 'I': 'unsigned int', 'S': 'unsigned short',
    'L': 'unsigned long', 'Q': 'unsigned long long',
    'f': 'float', 'd': 'double', 'B': 'BOOL', 'v': 'void', '*': 'char *',
    '#': 'Class', ':': 'SEL', '@': 'id', '?': 'void *',
}


def parse_type(enc):
    """粗解析 ObjC type encoding；只要顶层类型够用"""
    if not enc:
        return 'id'
    c = enc[0]
    if c == '@':
        if enc.startswith('@"'):
            e = enc.find('"', 2)
            return (enc[2:e] or 'id') + ' *'
        if enc.startswith('@?'):
            return 'id /*block*/'
        return 'id'
    if c == '^':
        inner = parse_type(enc[1:])
        return inner + ' *'
    if c == '{':
        depth = 0
        for i, ch in enumerate(enc):
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    name = enc[1:i].split('=')[0]
                    return 'struct ' + name
        return 'struct ?'
    if c in '([':
        return TYPE_MAP.get(c, 'id')
    return TYPE_MAP.get(c, 'id')


def parse_method_type(enc):
    """返回 (ret, [args...])，去掉 self/_cmd"""
    if not enc:
        return ('id', [])
    # 逐段扫描
    i = 0
    types = []
    while i < len(enc):
        c = enc[i]
        if c in 'rnNoORVA':
            i += 1
            continue
        if c == '@' and enc.startswith('@"', i):
            j = enc.find('"', i + 2)
            types.append(enc[i:j + 1])
            i = j + 1
            continue
        if c == '@' and enc.startswith('@?', i):
            types.append('@?')
            i += 2
            continue
        if c in '^({[':
            depth = 0
            j = i
            while j < len(enc):
                if enc[j] in '^({[':
                    depth += 1
                elif enc[j] in ')}]':
                    depth -= 1
                    if depth == 0:
                        j += 1
                        break
                j += 1
            types.append(enc[i:j])
            i = j
            continue
        types.append(c)
        i += 1
    ret = parse_type(types[0]) if types else 'id'
    args = [parse_type(t) for t in types[3:]] if len(types) > 2 else []
    return (ret, args)


def resolve_cstr(vm):
    """iOS 16+ 的 relative method list 里，name 偏移指向的是 __objc_selrefs 槽，
    槽本身是 chained 指针，解一层才是 __objc_methname 里的 cstring。
    先试解一层，解不出再当普通 cstring 读。"""
    r = m.decode_slot(vm)
    if r and r[0] == 'rebase':
        s = m.cstr(r[1])
        # 中文选择器是合法的，只排控制字符
        if s and not any(ord(ch) < 9 or (13 < ord(ch) < 32) for ch in s):
            return s
    return m.cstr(vm)


def looks_bad(s):
    return not s or any(ord(ch) < 9 or (13 < ord(ch) < 32) for ch in s)


def read_method_list(vm):
    out = []
    if not vm or not isinstance(vm, int):
        return out
    hdr = u32(vm)
    cnt = u32(vm + 4)
    if hdr is None or cnt is None or cnt > 2000:
        return out
    entsize = hdr & 0x0000FFFC
    relative = bool(hdr & 0x80000000)
    if relative:
        for i in range(cnt):
            base = vm + 8 + i * 12
            noff = i32(base)
            toff = i32(base + 4)
            ioff = i32(base + 8)
            if noff is None:
                continue
            name = resolve_cstr(base + noff)
            types = ''
            if toff is not None:
                types = m.cstr(base + 4 + toff)
                if looks_bad(types):
                    types = resolve_cstr(base + 4 + toff)
            imp = base + 8 + ioff if ioff is not None else 0
            out.append({'sel': name, 'type': types, 'imp': imp})
    else:
        for i in range(cnt):
            base = vm + 8 + i * entsize
            name = pstr(base)
            if name is None:
                continue
            types = pstr(base + 8) or ''
            imp = resolve(base + 16)
            out.append({'sel': name, 'type': types,
                        'imp': imp if isinstance(imp, int) else 0})
    return out


def read_ivar_list(vm):
    out = []
    if not vm or not isinstance(vm, int):
        return out
    entsize = u32(vm)
    cnt = u32(vm + 4)
    if entsize is None or cnt is None or cnt > 500:
        return out
    step = entsize & 0x0000FFFC or 32
    for i in range(cnt):
        base = vm + 8 + i * step
        offp = u64(base)
        name = pstr(base + 8)
        typ = pstr(base + 16)
        align = u32(base + 24)
        size = u32(base + 28)
        off = i32(offp) if offp else None
        out.append({'offset': off, 'name': name, 'type': typ,
                    'align': align, 'size': size})
    return out


def read_property_list(vm):
    out = []
    if not vm or not isinstance(vm, int):
        return out
    entsize = u32(vm)
    cnt = u32(vm + 4)
    if entsize is None or cnt is None or cnt > 500:
        return out
    step = entsize & 0x0000FFFC or 16
    for i in range(cnt):
        base = vm + 8 + i * step
        name = pstr(base)
        attrs = pstr(base + 8)
        out.append({'name': name, 'attrs': attrs})
    return out


def read_protocol_list(vm):
    out = []
    if not vm or not isinstance(vm, int):
        return out
    cnt = u64(vm)
    if cnt is None or cnt > 100:
        return out
    for i in range(cnt):
        p = resolve(vm + 8 + i * 8)
        if isinstance(p, int):
            nm = pstr(p + 8)
            out.append(nm)
    return out


def read_class(vm, is_meta=False):
    """class_t: isa superclass cache vtable data"""
    ro = resolve(vm + 32)
    if not isinstance(ro, int):
        return None
    flags = u32(ro)
    name = pstr(ro + 24)
    methods = read_method_list(resolve(ro + 32))
    protos = read_protocol_list(resolve(ro + 40))
    ivars = read_ivar_list(resolve(ro + 48))
    props = read_property_list(resolve(ro + 64))
    sup = resolve(vm + 8)
    supname = None
    if isinstance(sup, int):
        sro = resolve(sup + 32)
        if isinstance(sro, int):
            supname = pstr(sro + 24)
    elif isinstance(sup, str):
        supname = sup[4:] if sup.startswith('_OBJC') else sup
    return {'name': name, 'superclass': supname or 'NSObject',
            'flags': flags, 'methods': methods, 'protocols': protos,
            'ivars': ivars, 'props': props, 'addr': vm,
            'instanceStart': u32(ro + 4), 'instanceSize': u32(ro + 8)}


def read_category(vm):
    name = pstr(vm)
    cls = resolve(vm + 8)
    clsname = None
    if isinstance(cls, str):
        clsname = cls
    elif isinstance(cls, int):
        ro = resolve(cls + 32)
        if isinstance(ro, int):
            clsname = pstr(ro + 24)
    inst_m = read_method_list(resolve(vm + 16))
    class_m = read_method_list(resolve(vm + 24))
    protos = read_protocol_list(resolve(vm + 32))
    props = read_property_list(resolve(vm + 40))
    return {'name': name, 'class': clsname, 'instance_methods': inst_m,
            'class_methods': class_m, 'protocols': protos, 'props': props}


def main():
    classes = []
    catlist = m.sects.get('__objc_catlist')
    classlist = m.sects.get('__objc_classlist')
    clst_addrs = []
    if classlist:
        addr, size, off = classlist
        for i in range(size // 8):
            r = resolve(addr + i * 8)
            if isinstance(r, int):
                clst_addrs.append(r)
    for a in clst_addrs:
        c = read_class(a)
        if c:
            classes.append(c)

    cats = []
    if catlist:
        addr, size, off = catlist
        for i in range(size // 8):
            r = resolve(addr + i * 8)
            if isinstance(r, int):
                cats.append(read_category(r))

    L = []
    L.append('=== CLASSES (%d) ===' % len(classes))
    for c in classes:
        L.append('')
        L.append('@interface %s : %s   // addr %#x  size %d' %
                 (c['name'], c['superclass'], c['addr'], c['instanceSize'] or 0))
        for iv in c['ivars']:
            L.append('    %-28s %s;   // off %s' %
                     (parse_type(iv['type']) if iv['type'] else 'id',
                      iv['name'], iv['offset']))
        for p in c['props']:
            L.append('    @property %s' % p['attrs'])
        for mm in c['methods']:
            ret, args = parse_method_type(mm['type'])
            parts = mm['sel'].split(':')
            if len(parts) <= 1:
                L.append('    - (%s)%s;' % (ret, mm['sel']))
            else:
                segs = []
                for k, nm in enumerate(parts[:-1]):
                    a = args[k] if k < len(args) else 'id'
                    segs.append('%s:(%s)arg%d' % (nm, a, k))
                L.append('    - (%s)%s;' % (ret, ' '.join(segs)))
        L.append('@end')

    L.append('')
    L.append('=== CATEGORIES (%d) ===' % len(cats))
    for c in cats:
        L.append('')
        L.append('@interface %s (%s)' % (c['class'], c['name']))
        for p in c['props']:
            L.append('    @property %s' % p['attrs'])
        for mm in c['instance_methods']:
            ret, args = parse_method_type(mm['type'])
            parts = mm['sel'].split(':')
            if len(parts) <= 1:
                L.append('    - (%s)%s;' % (ret, mm['sel']))
            else:
                segs = []
                for k, nm in enumerate(parts[:-1]):
                    a = args[k] if k < len(args) else 'id'
                    segs.append('%s:(%s)arg%d' % (nm, a, k))
                L.append('    - (%s)%s;' % (ret, ' '.join(segs)))
        for mm in c['class_methods']:
            ret, args = parse_method_type(mm['type'])
            parts = mm['sel'].split(':')
            if len(parts) <= 1:
                L.append('    + (%s)%s;' % (ret, mm['sel']))
            else:
                segs = []
                for k, nm in enumerate(parts[:-1]):
                    a = args[k] if k < len(args) else 'id'
                    segs.append('%s:(%s)arg%d' % (nm, a, k))
                L.append('    + (%s)%s;' % (ret, ' '.join(segs)))
        L.append('@end')

    os.makedirs(OUT, exist_ok=True)
    open(os.path.join(OUT, 'objc2.txt'), 'w', encoding='utf-8').write('\n'.join(L))
    json.dump({'classes': classes, 'categories': cats},
              open(os.path.join(OUT, 'objc2.json'), 'w', encoding='utf-8'),
              ensure_ascii=False, indent=1)
    print('\n'.join(L[:60]))
    print('...')
    print('classes=%d categories=%d methods=%d' %
          (len(classes), len(cats),
           sum(len(c['methods']) for c in classes) +
           sum(len(c['instance_methods']) for c in cats)))


if __name__ == '__main__':
    main()
