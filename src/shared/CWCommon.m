//
//  CWCommon.m
//  CPUWatcher
//

#import "CWCommon.h"

#include <sys/sysctl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

NSString *CWDataDirPath(void) { return CW_DATA_DIR; }
NSString *CWSnapshotPath(void) { return CW_SNAPSHOT_PATH; }
NSString *CWStatePath(void)    { return CW_STATE_PATH; }

NSString *CWFormattedBytes(unsigned long long bytes) {
    double v = (double)bytes;
    if (v >= 1024.0 * 1024.0 * 1024.0) return [NSString stringWithFormat:@"%.2f GB", v / (1024.0 * 1024.0 * 1024.0)];
    if (v >= 1024.0 * 1024.0)          return [NSString stringWithFormat:@"%.1f MB", v / (1024.0 * 1024.0)];
    if (v >= 1024.0)                   return [NSString stringWithFormat:@"%.0f KB", v / 1024.0];
    return [NSString stringWithFormat:@"%llu B", bytes];
}

BOOL CWEnsureDataDir(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:CW_DATA_DIR]) return YES;

    NSError *err = nil;
    BOOL ok = [fm createDirectoryAtPath:CW_DATA_DIR
            withIntermediateDirectories:YES
                             attributes:@{ NSFilePosixPermissions : @(0755) }
                                  error:&err];
    if (!ok) {
        // helper 以 root 跑时这里一般不会失败；面板以 mobile 跑时 Media 目录本身可写。
        NSLog(@"[CPUWatcher] 创建数据目录失败: %@", err);
    }
    return ok;
}

// ---------------------------------------------------------------------------
// 能力档位探测：不假装全能，探到什么报什么。
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

CWTier CWDetectTier(void) {
    if (geteuid() == 0) return CWTierFull;
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
            return @"特权助手已就位：可读每进程 CPU / 内存 / 能耗 / 唤醒次数，并支持采样剖析。";
        case CWTierProcBasic:
            return @"无 root 权限：只能读到进程列表与内核估算的 CPU 占比，能耗、唤醒次数与采样剖析不可用。";
        case CWTierGlobalOnly:
            return @"当前环境连进程列表都读不到：仅显示全局 CPU 与内存。冲突扫描（纯静态解析）仍可用。";
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
