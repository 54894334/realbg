# 逆向工具链（针对原包 1.5）

原二进制 `RealBackstage`（438,608 字节，thin arm64，`MH_EXECUTE`）用的是 **`LC_DYLD_CHAINED_FIXUPS`**，
`__objc_classlist` 里的"指针"是编码过的链指针 —— 直接当地址读会得到垃圾，所以老工具（otool/class-dump 思路）
读出来是 0 个方法。这几个脚本是为了绕开这一点现写的。

## 环境

```bash
pip install capstone unicorn
```

## 用法

先把原包解开，得到 `x/Payload/RealBackstage.app/RealBackstage`，然后：

```bash
export TARGET_BIN=x/Payload/RealBackstage.app/RealBackstage

python m1_header.py                 # 段/节/load command 概览
python m2b_objc.py                  # 还原 ObjC：类、方法、category（输出到 analysis/）
python m4b_disasm.py func -[Foo bar]  # 符号化反汇编某个方法
python m4b_disasm.py sel Is自杀:      # 按选择器查
python m4b_disasm.py calls 0x100012345  # 看某个函数调了谁
python m6_strdec.py > strings.txt   # 静态还原运行时 XOR 加密字符串（85 条）
python m5_sim.py <函数地址>          # Unicorn 模拟执行（会停在 __stubs，不如 m6 全）
```

## 两个必须记住的坑

1. **`dyld_chained_starts_in_segment` 的头是 `<IHHQ>`**（size / page_size / pointer_format / segment_offset），
   **+16 是 max_valid_pointer，+20 才是 page_count**，`page_start[]` 从 **+22** 开始。
   按"+20 读 page_count"写会把整个段解错，且不报错，只是全解不出来。

2. **iOS 16+ 的 relative method list**：`method_list_t.entsize` 的 bit31 置位时，每条记录是 3 个 `int32`
   相对偏移（name / types / imp），不是三个指针。而且 **name 偏移落在 `__objc_selrefs` 槽上，槽本身还是链指针**，
   要再解一层才指向 `__objc_methname` 里的 cstring。少解这一层，方法名全是乱码。

## 关于中文选择器

原包里确实有 `Is自杀:`、`Is自启:`、`TG频道`、`捐赠` 这种中文选择器。
过滤非法字符串时**只能排控制字符**，不能"只允许 ASCII 32–126"，否则这些合法选择器会被当成垃圾丢掉。

## 证据

`original_strings.txt` 是 `m6_strdec.py` 在原始二进制上的真实输出（85 条，去重后打印 55 条），
`com.example.myPort`（`0x100054d40`）、`trollstorehelper`（`0x100053ef0`）、
`/var/mobile/Library/Preferences/com.thefool.app.plist`（`0x100058760`）都在里面。
