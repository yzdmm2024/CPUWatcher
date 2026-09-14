//
//  CWCommon.h — 公共路径、能力档位、JSON 落盘
//  CPUWatcher
//

#import <Foundation/Foundation.h>

// 版本号：改版本时同步改这里 + control + bundle Info.plist（CI 会校验三者一致）。
// 规则：小改动 +0.1（0.1.0 → 0.1.1），大改动 +1.0。
#define CW_VERSION_STRING "0.1.8"

// 数据落在用户区（不是越狱目录），方便 Filza / 爱思 / 文件 App 直接取走，
// 也避免往 /var/jb 写导致越狱目录权限被搅乱。
#define CW_DATA_DIR      @"/var/mobile/Media/CPUWatcher"
#define CW_SNAPSHOT_PATH @"/var/mobile/Media/CPUWatcher/snapshot.json"
#define CW_STATE_PATH    @"/var/mobile/Media/CPUWatcher/state.json"
#define CW_INJECTED_PATH @"/var/mobile/Media/CPUWatcher/injected.json"
// 插件冲突扫描（IMP 归属）结果：SpringBoard 内的 HUD 写出，设置面板读取。
#define CW_CONFLICT_PATH @"/var/mobile/Media/CPUWatcher/conflicts.json"
// 越狱插件 CPU / 内存归因结果（v0.1.8）：SpringBoard 内 HUD 写出，面板读取。
#define CW_TWEAK_PROFILE_PATH @"/var/mobile/Media/CPUWatcher/tweakprofile.json"
#define CW_PREFS_DOMAIN  @"com.axs.cpuwatcher"
// 面板「显示悬浮窗」开关的偏好键（监控页浮层与开关共用）。
#define CW_HUD_ENABLED_KEY @"hudEnabled"
// 悬浮窗位置记忆（用户可拖动到屏幕任意位置，落点存进这两个键）。
#define CW_HUD_ORIGIN_X_KEY @"hudOriginX"
#define CW_HUD_ORIGIN_Y_KEY @"hudOriginY"

// Darwin 通知名（面板 <-> SpringBoard 内 HUD 通信，不依赖任何常驻进程）
// 让 SpringBoard 里的 HUD 把「自己实际加载了哪些插件 dylib」写成 JSON。
// 这是拿到真实注入清单的唯一零风险途径：不用 task_for_pid、不读别人内存。
#define CW_NOTIFY_DUMP_INJECTED CFSTR("com.axs.cpuwatcher.dumpinjected")

// 插件冲突扫描：面板 -> HUD 请求扫描；HUD 扫描完成 -> 面板。
// 扫描在 SpringBoard 后台线程进行，完成后广播 SCAN_DONE，面板据此读取结果文件。
#define CW_NOTIFY_SCAN_CONFLICTS CFSTR("com.axs.cpuwatcher.scan.conflicts")
#define CW_NOTIFY_SCAN_DONE      CFSTR("com.axs.cpuwatcher.scan.done")

// 越狱插件 CPU / 内存归因（v0.1.8）：面板 -> HUD 请求；HUD 完成 -> 面板。
#define CW_NOTIFY_TWEAK_PROFILE      CFSTR("com.axs.cpuwatcher.tweakprofile")
#define CW_NOTIFY_TWEAK_PROFILE_DONE CFSTR("com.axs.cpuwatcher.tweakprofile.done")


// 面板按需 spawn 的 helper 路径（按顺序尝试）
#define CW_HELPER_PATHS @[ @"/var/jb/usr/bin/cpuwatchctl", @"/var/jb/usr/local/bin/cpuwatchctl" ]

// 硬性存活上限：任何情况下 helper 最长只允许跑这么久，到点自杀。
// 目的：即使面板被系统杀掉、或逻辑出 bug，也绝不留下长期后台采样进程。
#define CW_HELPER_HARD_LIMIT_SEC  60

// 心跳看门狗：父进程（面板）消失 / 变成 launchd 后就退出。
#define CW_HELPER_PPID_POLL_SEC   0.5

// 能力档位。注意：**判定不看 uid** —— 本机实测非 root 也能调通
// proc_pidinfo / proc_pid_rusage，所以"完整模式"与是不是 root 无关。
typedef NS_ENUM(NSInteger, CWTier) {
    CWTierGlobalOnly = 0,  // 最低：只有全局 CPU 与内存
    CWTierProcBasic  = 1,  // 半：只有进程列表，读不到每进程 CPU / 能耗
    CWTierFull       = 2,  // 完整：每进程 CPU / 内存 / 线程 / 能耗 / 唤醒全可读
};

// 进程类别：实时监控页据此把每个进程标注成「系统 / 你装的App / 越狱相关」。
// 分类**只看可执行文件路径**，纯 Foundation，无 UIKit 依赖（本头会被 tool target 编译）。
// 注意：越狱「插件(tweak)」本身是注入到宿主进程的 dylib，不是独立进程，所以不会
// 单独出现在进程列表里——列表里标 [越狱] 的只是越狱App/daemon/工具（Sileo、Filza、/var/jb 下的二进制）。
typedef NS_ENUM(NSInteger, CWProcKind) {
    CWProcKindSystem    = 0, // iOS 自带：系统守护进程 / 系统App（设置、短信、SpringBoard…）
    CWProcKindApp       = 1, // 用户安装的第三方 App（微信、抖音…）
    CWProcKindJailbreak = 2, // 越狱相关：越狱App / daemon / 工具（Sileo、Filza、/var/jb 下二进制）
    CWProcKindUnknown   = 3, // 路径读不到，无法归类（不再冒认成系统）
};

// ⚠️ extern "C" 不能省：本头文件会被 .xm 文件包含，而 theos 把 .xm 当 **Objective-C++**
// 编译。C++ 编译单元里引用这些函数会发生 name mangling（变成 _Z14CWEnsureDataDirv 之类），
// 而 CWCommon.m 里定义的是 C 符号 _CWEnsureDataDir，链接期直接 Undefined symbols。
// 症状：只在 .xm 引用了这些函数时才炸，纯 .m 引用完全正常，很容易误判成"函数没实现"。
#ifdef __cplusplus
extern "C" {
#endif

NSString *CWDataDirPath(void);
NSString *CWSnapshotPath(void);
NSString *CWStatePath(void);
NSString *CWInjectedListPath(void);
NSString *CWConflictPath(void);
NSString *CWTweakProfilePath(void);
NSString *CWHelperLaunchPath(void);
BOOL      CWEnsureDataDir(void);
CWTier    CWDetectTier(void);
NSString *CWTierName(CWTier t);
NSString *CWTierDetail(CWTier t);

// 进程分类：CWProcKindForPath 按路径判类别，CWProcKindName 取中文标签（给 UI 用）。
CWProcKind CWProcKindForPath(NSString *path);
NSString  *CWProcKindName(CWProcKind k);

// 原子写 JSON：先写 .tmp 再 rename，避免面板读到半个文件
BOOL CWWriteJSONAtomically(NSDictionary *obj, NSString *path);
NSDictionary *CWReadJSON(NSString *path);

NSString *CWFormattedBytes(unsigned long long bytes);

// 把「纳焦/秒」换算成人类能读的功率。1 nJ/s == 1e-9 W == 1e-6 mW。
// 能耗原始数字动辄上亿，直接显示没有意义。
NSString *CWFormatPower(double nanoJoulesPerSec);

#ifdef __cplusplus
}
#endif
