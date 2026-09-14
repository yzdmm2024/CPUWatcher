//
//  CWCommon.m
//  CPUWatcher
//

#import "CWCommon.h"

#include <sys/sysctl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

// ⚠️ 不要再引入 libproc.h：CI 的 iPhoneOS SDK 里没有这个头，
// 用 __has_include 判它会静默把整块功能编译掉（v0.1.2 的真根因）。
// 一切 libproc 入口统一走自包含的 shim。
#import "CWProcShim.h"

NSString *CWDataDirPath(void) { return CW_DATA_DIR; }
NSString *CWSnapshotPath(void) { return CW_SNAPSHOT_PATH; }
NSString *CWStatePath(void)    { return CW_STATE_PATH; }
NSString *CWInjectedListPath(void) { return CW_INJECTED_PATH; }
NSString *CWConflictPath(void)     { return CW_CONFLICT_PATH; }

NSString *CWFormattedBytes(unsigned long long bytes) {
    double v = (double)bytes;
    if (v >= 1024.0 * 1024.0 * 1024.0) return [NSString stringWithFormat:@"%.2f GB", v / (1024.0 * 1024.0 * 1024.0)];
    if (v >= 1024.0 * 1024.0)          return [NSString stringWithFormat:@"%.1f MB", v / (1024.0 * 1024.0)];
    if (v >= 1024.0)                   return [NSString stringWithFormat:@"%.0f KB", v / 1024.0];
    return [NSString stringWithFormat:@"%llu B", bytes];
}

NSString *CWFormatPower(double nanoJoulesPerSec) {
    // 纳焦/秒 -> 瓦特：1 nJ/s = 1e-9 W
    double w = nanoJoulesPerSec / 1e9;
    if (w >= 1.0)     return [NSString stringWithFormat:@"%.2f W", w];
    if (w >= 0.001)   return [NSString stringWithFormat:@"%.1f mW", w * 1000.0];
    if (w >= 0.000001) return [NSString stringWithFormat:@"%.1f uW", w * 1e6];
    return @"0";
}

BOOL CWEnsureDataDir(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:CW_DATA_DIR]) return YES;

    NSError *err = nil;
    // 0777 是故意的：这个目录会被三个不同身份的进程写 ——
    // helper(root) 写 snapshot.json、SpringBoard(mobile) 写 injected.json、
    // 设置面板(mobile) 写导出快照。权限收窄会让 SpringBoard 静默写失败。
    // 位置在 /var/mobile/Media 下，本来就是对用户可见的公开区，不涉及系统文件。
    BOOL ok = [fm createDirectoryAtPath:CW_DATA_DIR
            withIntermediateDirectories:YES
                             attributes:@{ NSFilePosixPermissions : @(0777) }
                                  error:&err];
    if (!ok) {
        // helper 以 root 跑时这里一般不会失败；面板以 mobile 跑时 Media 目录本身可写。
        NSLog(@"[CPUWatcher] 创建数据目录失败: %@", err);
    }
    return ok;
}

// ---------------------------------------------------------------------------
// 能力档位探测：不假装全能，探到什么报什么。
//
// ⚠️ 关键修正：档位**不能用 geteuid()==0 判断**。
// 实机取证（iPhone 12 Pro / iOS 16.6.1 / Relaxin）：uid=501 的非 root 进程
// 也能调通 proc_pidinfo(PROC_PIDTASKINFO) 与 proc_pid_rusage(RUSAGE_INFO_V4)，
// 只有 launchd(pid 1) 被拒。旧写法因此把"其实能用"的环境误报成降级，
// 还顺带把采样路径也带偏了。
// 这里改为**真去读一个别的进程**，能读到就是完整模式。
// ---------------------------------------------------------------------------
static BOOL CWCanListProcesses(void) {
    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
    size_t len = 0;
    int rc = sysctl(mib, 3, NULL, &len, NULL, 0);
    if (rc != 0 || len == 0) return NO;
    // 真的取一次，确认不是只给了长度却拒绝读
    void *buf = malloc(len);
    if (!buf) return NO;
    rc = sysctl(mib, 3, buf, &len, NULL, 0);
    free(buf);
    return (rc == 0);
}

// 找一个「不是自己、也不是 launchd」的进程，试着读它的 taskinfo。
// 读得到 => 每进程 CPU / 内存 / 能耗 / 唤醒全部可用。
static BOOL CWCanReadTaskInfo(void) {
    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
    size_t len = 0;
    if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0 || len == 0) return NO;

    void *buf = malloc(len);
    if (!buf) return NO;
    if (sysctl(mib, 3, buf, &len, NULL, 0) != 0) { free(buf); return NO; }

    struct kinfo_proc *procs = (struct kinfo_proc *)buf;
    int n = (int)(len / sizeof(struct kinfo_proc));
    pid_t me = getpid();
    pid_t probe = 0;
    for (int i = 0; i < n; i++) {
        pid_t p = procs[i].kp_proc.p_pid;
        if (p > 0 && p != me && p != 1) { probe = p; break; }
    }
    free(buf);
    if (probe <= 0) return NO;

    cw_proc_taskinfo_t pti;
    return CWProcInfoForPid(probe, &pti) > 0;
}

CWTier CWDetectTier(void) {
    if (CWCanReadTaskInfo()) return CWTierFull;
    if (CWCanListProcesses()) return CWTierProcBasic;
    return CWTierGlobalOnly;
}

NSString *CWTierName(CWTier t) {
    switch (t) {
        case CWTierFull:       return @"完整模式";
        case CWTierProcBasic:  return @"基础模式";
        case CWTierGlobalOnly: return @"受限模式";
    }
    return @"未知";
}

NSString *CWTierDetail(CWTier t) {
    switch (t) {
        case CWTierFull:
            return @"每进程 CPU、内存、线程数、能耗（纳焦）、中断唤醒次数全部可读。\n\n"
                   @"实测本机非 root 也能读到，不需要特权助手、不需要 setuid。";
        case CWTierProcBasic:
            return @"只能读到进程列表，读不到每进程 CPU 与能耗（proc_pidinfo 被拒）。";
        case CWTierGlobalOnly:
            return @"连进程列表都受限，仅能显示全局 CPU 与内存。\n\n"
                   @"插件冲突扫描（纯静态解析 dylib）不受影响，仍然可用。";
    }
    return @"";
}

NSString *CWHelperLaunchPath(void) {
    for (NSString *p in CW_HELPER_PATHS) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:p]) return p;
    }
    return nil;
}

// ---------------------------------------------------------------------------
// JSON 读写
// ---------------------------------------------------------------------------
BOOL CWWriteJSONAtomically(NSDictionary *obj, NSString *path) {
    if (!obj || !path) return NO;
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj
                                                   options:0
                                                     error:&err];
    if (!data) {
        NSLog(@"[CPUWatcher] JSON 序列化失败: %@", err);
        return NO;
    }
    NSString *tmp = [path stringByAppendingString:@".tmp"];
    if (![data writeToFile:tmp atomically:NO]) return NO;
    // rename 是原子的；目标已存在时 rename 会直接覆盖，不会留下半个文件
    if (rename([tmp fileSystemRepresentation], [path fileSystemRepresentation]) != 0) {
        NSLog(@"[CPUWatcher] rename 失败: %d", errno);
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
        return NO;
    }
    return YES;
}

NSDictionary *CWReadJSON(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length == 0) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

#pragma mark - 进程分类（系统 / App / 越狱）

// 越狱 App / 工具的可执行名（装在 /Applications 下，不在 Apple 系统名单里）。
// 名单有限，但覆盖最常见的几个；漏掉的越狱进程靠 /var/jb/ 路径兜底也能命中。
static NSArray<NSString *> *CWJailbreakAppNames(void) {
    static NSArray *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[ @"Sileo", @"Zebra", @"Filza", @"Filza_File_Manager", @"iCleanerPro",
                   @"NewTerm", @"NewTerm2", @"sshd", @"Substrate",
                   @"ElleKit", @"TrollStore", @"Cydia", @"CydiaExtender", @"Cr4shed",
                   @"PreferenceLoader", @"rocketbootstrap", @"AppList" ];
    });
    return names;
}

// 按可执行文件路径判类别，纯 Foundation，无 UIKit 依赖（tool target 也编本文件）。
// 顺序很关键：先判越狱路径 / 越狱 App 名，再判用户 App 容器，最后系统，兜底系统。
CWProcKind CWProcKindForPath(NSString *path) {
    NSString *p = path ?: @"";
    if (p.length == 0) return CWProcKindUnknown;

    // 1) 越狱目录 / 注入框架 → 越狱
    if ([p containsString:@"/var/jb/"] ||
        [p containsString:@"/var/LIB/"] ||
        [p containsString:@"TweakInject"] ||
        [p containsString:@"MobileSubstrate"] ||
        [p containsString:@"/usr/lib/TweakInject"] ||
        [p containsString:@"/Library/MobileSubstrate"] ||
        [p containsString:@"/Library/TweakInject"]) {
        return CWProcKindJailbreak;
    }

    // 2) 越狱 App / 工具（可执行名匹配，装在 /Applications 下）
    NSString *base = p.lastPathComponent;
    for (NSString *name in CWJailbreakAppNames()) {
        if ([base isEqualToString:name]) return CWProcKindJailbreak;
    }

    // 3) 用户安装的第三方 App（App Store / 侧载到沙盒容器）
    if ([p containsString:@"/private/var/containers/Bundle/Application/"] ||
        [p containsString:@"/var/containers/Bundle/Application/"]) {
        return CWProcKindApp;
    }

    // 4) 系统守护进程 / 系统 App / 框架
    if ([p hasPrefix:@"/Applications/"] ||
        [p containsString:@"/System/Library/"] ||
        [p containsString:@"/usr/libexec/"] ||
        [p containsString:@"/usr/sbin/"] ||
        [p containsString:@"/sbin/"] ||
        [p containsString:@"/Library/Apple/"] ||
        [p containsString:@"/usr/lib/"] ||
        [p containsString:@"/System/Library/CoreServices/"] ||
        [p containsString:@"/Library/Preferences/"]) {
        return CWProcKindSystem;
    }

    // 兜底：认不出的都算系统，避免把未知进程误标成「越狱」吓人
    return CWProcKindSystem;
}

NSString *CWProcKindName(CWProcKind k) {
    switch (k) {
        case CWProcKindSystem:    return @"系统";
        case CWProcKindApp:       return @"App";
        case CWProcKindJailbreak: return @"越狱";
        case CWProcKindUnknown:   return @"未知";
    }
    return @"系统";
}
