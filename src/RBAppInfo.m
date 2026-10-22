//
//  RBAppInfo.m — 应用条目模型
//
//  这个文件本来应该早就在。1.0.0 / 1.1.0 里 RBAppInfo 只有 @interface 声明，
//  整个工程没有一处 @implementation —— 而 RBProcesses.m 里直接写了
//  [RBAppInfo new]。
//
//  因为 Makefile 当时带 -Wl,-undefined,dynamic_lookup，链接器不检查符号，
//  产物照样生成。但 _OBJC_CLASS_$_RBAppInfo 这类引用在 dyld 里是启动时立即
//  绑定的（不是 lazy），于是：点图标 → dyld 找不到类 → 直接杀掉进程。
//  崩在 main 之前 —— 崩溃捕获装不上、日志一字节写不出、「文件」App 里什么都没有。
//
//  这就是「点开就闪退」的真正原因。去掉 dynamic_lookup 后，链接器第一件事
//  就把这个错误指了出来，再也不用靠猜。
//
#import "RB.h"

@implementation RBAppInfo

/// 空实现就够：所有属性都由编译器自动合成（ARC 下 strong/copy/assign 都按声明处理）。
/// 保留一个 description 便于日志排查。
- (NSString *)description {
    return [NSString stringWithFormat:
            @"<RBAppInfo %@ 「%@」 pid=%d running=%d backstage=%d auto=%d suicide=%d locked=%d sys=%d>",
            self.bundleID, self.name, self.pid,
            self.isRunning, self.hasBackstage, self.hasAutoStart,
            self.hasSuicide, self.locked, self.isSystem];
}

@end
