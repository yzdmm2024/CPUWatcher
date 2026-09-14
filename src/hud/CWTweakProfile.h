//
//  CWTweakProfile.h — 在 SpringBoard 内做「tweak CPU / 内存归因」（v0.1.8）
//  CPUWatcher
//
//  头文件用 extern "C" 包裹：本头会被 .xm（Objective-C++）包含，C 函数若不做
//  名称修饰会在链接期找不到符号（与 CWCommon.h / CWConflictScan.h 同样的坑）。
//

#import <Foundation/Foundation.h>
#import "CWCommon.h"

#ifdef __cplusplus
extern "C" {
#endif

// 在 SpringBoard 进程内做 tweak 资源归因（无 root、只读、不 hook）：
//   - 取自身 task 的全部线程，用 thread_info(THREAD_BASIC_INFO) 记录每线程累计 CPU 时间；
//   - 2.5s 后再取一次，求差 = 该线程在采样窗口内消耗的 CPU；
//   - 对消耗显著的「热线程」采一次 PC（thread_suspend + thread_get_state + thread_resume），
//     用 dladdr 查 PC 落点的 dylib；若落在某个 tweak dylib => 这份 CPU 算那个 tweak 的；
//   - 另统计每个 tweak dylib 的映射大小（mach-o LC_SEGMENT_64 vmsize 之和，≈内存占用代理）。
// 结果写 CWTweakProfilePath()，并广播 CW_NOTIFY_TWEAK_PROFILE_DONE。
//
// ⚠️ 必须在后台线程调用：会 suspend/resume 若干线程 + sleep 2.5s，主线程做会卡 SB。
//   范围局限：只能归因「注入到 SpringBoard 的 tweak」（绝大多数系统级耗电/卡顿 tweak 都在这里）。
//   注入到具体 App（微信/抖音…）的 tweak 不在此列。
void CWRunTweakProfile(void);

#ifdef __cplusplus
}
#endif
