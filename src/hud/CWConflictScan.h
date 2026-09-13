//
//  CWConflictScan.h — 在 SpringBoard 内做 IMP 归属扫描（P4 冲突检测）
//  CPUWatcher
//
//  头文件用 extern "C" 包裹：本头会被 .xm（Objective-C++）包含，C 函数若不做
//  名称修饰会在链接期找不到符号（与 CWCommon.h 同样的坑）。
//

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// 在 SpringBoard 进程内做 IMP 归属扫描（无 root、只读、不 hook）。
//   - 枚举进程内所有 Objective-C 类 + 元类的方法 IMP；
//   - 用 dladdr 查 IMP 实际落点的 dylib；
//   - 与 class_getImageName 拿到的「类定义所在 dylib」比对；
//     若 IMP 落在某个 tweak dylib、且该类并非定义在该 tweak 里
//     => 这个 tweak 把该方法替换成了自己的实现（即一次 hook）；
//   - 同一个 (类, 方法) 被 ≥2 个 tweak 命中 => 冲突（多个插件抢同一方法）。
// 结果写 CW_CONFLICT_PATH，并广播 CW_NOTIFY_SCAN_DONE。
//
// ⚠️ 必须在后台线程调用：会遍历上万类、几十万方法，耗时数秒。
//    SpringBoard 主线程被长时间阻塞会触发看门狗（白苹果风险）。
void CWRunConflictScan(void);

#ifdef __cplusplus
}
#endif
