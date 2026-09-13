//
//  CWCommon.h — 公共路径、能力档位、JSON 落盘
//  CPUWatcher
//

#import <Foundation/Foundation.h>

// 版本号：改版本时同步改这里 + control + bundle Info.plist（CI 会校验三者一致）。
// 规则：小改动 +0.1（0.1.0 → 0.1.1），大改动 +1.0。
#define CW_VERSION_STRING "0.1.3"

// 数据落在用户区（不是越狱目录），方便 Filza / 爱思 / 文件 App 直接取走，
// 也避免往 /var/jb 写导致越狱目录权限被搅乱。
#define CW_DATA_DIR      @"/var/mobile/Media/CPUWatcher"
#define CW_SNAPSHOT_PATH @"/var/mobile/Media/CPUWatcher/snapshot.json"
#define CW_STATE_PATH    @"/var/mobile/Media/CPUWatcher/state.json"
#define CW_INJECTED_PATH @"/var/mobile/Media/CPUWatcher/injected.json"
// 悬浮窗自己在 SpringBoard 里写的事件日志（收到什么通知、有没有找到 scene、窗有没有建出来）。
// 它存在的唯一目的：把"悬浮窗没出来"从"猜"变成"读"。
#define CW_HUD_STATUS_PATH @"/var/mobile/Media/CPUWatcher/hud_status.json"
#define CW_PREFS_DOMAIN  @"com.axs.cpuwatcher"

// Darwin 通知名（面板 <-> SpringBoard 内 HUD 通信，不依赖任何常驻进程）
#define CW_NOTIFY_HUD_ON        CFSTR("com.axs.cpuwatcher.hud.on")
#define CW_NOTIFY_HUD_OFF       CFSTR("com.axs.cpuwatcher.hud.off")
// 让 SpringBoard 里的 HUD 把「自己实际加载了哪些插件 dylib」写成 JSON。
// 这是拿到真实注入清单的唯一零风险途径：不用 task_for_pid、不读别人内存。
#define CW_NOTIFY_DUMP_INJECTED CFSTR("com.axs.cpuwatcher.dumpinjected")

// ---- HUD 状态回报（SpringBoard -> 面板）------------------------------------
// Darwin 通知只能传名字、不能带数据，所以用「一个状态一个名字」的方式把
// 布尔级结论传回来。面板注册这几个名字的观察者，把最后收到的那个显示出来。
// 好处：即使 HUD 写文件失败（沙盒拒绝），这条通道也能走通，
// 于是"通知没送达"和"窗建不出来"这两种失败能被区分开，不用再靠猜。
#define CW_NOTIFY_HUDST_SHOWN     CFSTR("com.axs.cpuwatcher.hudst.shown")      // 窗已建出并可见
#define CW_NOTIFY_HUDST_NOSCENE   CFSTR("com.axs.cpuwatcher.hudst.noscene")    // 收在通知，但找不到 UIWindowScene
#define CW_NOTIFY_HUDST_NOCTOR    CFSTR("com.axs.cpuwatcher.hudst.nomain")     // 收到通知但不在主线程/回调异常
#define CW_NOTIFY_HUDST_HIDDEN    CFSTR("com.axs.cpuwatcher.hudst.hidden")     // 已按请求销毁
#define CW_NOTIFY_HUDST_WRITEFAIL CFSTR("com.axs.cpuwatcher.hudst.writefail")  // 事件日志写不进 Media 目录
#define CW_NOTIFY_HUDST_DUMPOK    CFSTR("com.axs.cpuwatcher.hudst.dumpok")     // 注入清单已写出
#define CW_NOTIFY_HUDST_DUMPFAIL  CFSTR("com.axs.cpuwatcher.hudst.dumpfail")   // 注入清单写失败

// 面板判超时：发了 hud.on 后这么久没收到任何 hudst.* 回报，就认定"通知没送到或 dylib 没注入"。
#define CW_HUD_REPORT_TIMEOUT_SEC 2.0


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
NSString *CWHUDStatusPath(void);
NSString *CWHelperLaunchPath(void);
BOOL      CWEnsureDataDir(void);
CWTier    CWDetectTier(void);
NSString *CWTierName(CWTier t);
NSString *CWTierDetail(CWTier t);

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
