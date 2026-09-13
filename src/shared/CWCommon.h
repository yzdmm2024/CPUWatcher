//
//  CWCommon.h — 公共路径、能力档位、JSON 落盘
//  CPUWatcher
//

#import <Foundation/Foundation.h>

// 版本号：改版本时同步改这里 + control + bundle Info.plist（CI 会校验三者一致）。
// 规则：小改动 +0.1（0.1.0 → 0.1.1），大改动 +1.0。
#define CW_VERSION_STRING "0.1.1"

// 数据落在用户区（不是越狱目录），方便 Filza / 爱思 / 文件 App 直接取走，
// 也避免往 /var/jb 写导致越狱目录权限被搅乱。
#define CW_DATA_DIR      @"/var/mobile/Media/CPUWatcher"
#define CW_SNAPSHOT_PATH @"/var/mobile/Media/CPUWatcher/snapshot.json"
#define CW_STATE_PATH    @"/var/mobile/Media/CPUWatcher/state.json"
#define CW_INJECTED_PATH @"/var/mobile/Media/CPUWatcher/injected.json"
#define CW_PREFS_DOMAIN  @"com.axs.cpuwatcher"

// Darwin 通知名（面板 <-> SpringBoard 内 HUD 单向通信，不依赖任何常驻进程）
#define CW_NOTIFY_HUD_ON        CFSTR("com.axs.cpuwatcher.hud.on")
#define CW_NOTIFY_HUD_OFF       CFSTR("com.axs.cpuwatcher.hud.off")
// 让 SpringBoard 里的 HUD 把「自己实际加载了哪些插件 dylib」写成 JSON。
// 这是拿到真实注入清单的唯一零风险途径：不用 task_for_pid、不读别人内存。
#define CW_NOTIFY_DUMP_INJECTED CFSTR("com.axs.cpuwatcher.dumpinjected")

// 面板按需 spawn 的 helper 路径（按顺序尝试）
#define CW_HELPER_PATHS @[ @"/var/jb/usr/bin/cpuwatchctl", @"/var/jb/usr/local/bin/cpuwatchctl" ]

// 硬性存活上限：任何情况下 helper 最长只允许跑这么久，到点自杀。
// 目的：即使面板被系统杀掉、或逻辑出 bug，也绝不留下长期后台采样进程。
#define CW_HELPER_HARD_LIMIT_SEC  60

// 心跳看门狗：父进程（面板）消失 / 变成 launchd 后就退出。
#define CW_HELPER_PPID_POLL_SEC   0.5

typedef NS_ENUM(NSInteger, CWTier) {
    CWTierGlobalOnly = 0,  // 最低：只有全局 CPU（免权限）
    CWTierProcBasic  = 1,  // 半：全进程列表 + p_pctcpu
    CWTierFull       = 2,  // 完整：root，每进程 CPU/内存/能耗 + task port 剖析
};

NSString *CWDataDirPath(void);
NSString *CWSnapshotPath(void);
NSString *CWStatePath(void);
NSString *CWInjectedListPath(void);
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
