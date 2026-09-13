//
//  CWSampler.m
//  CPUWatcher
//
//  采样全部只读：只查内核计数器，不写任何目标进程的内存。
//

#import "CWSampler.h"

#import <mach/mach.h>
#import <mach/mach_host.h>
#import <mach/processor_info.h>
#import <sys/sysctl.h>
#import <sys/param.h>
#import <sys/time.h>
#include <pwd.h>
#include <unistd.h>
#include <string.h>

// FSCALE 在部分 SDK 里不随 sys/param.h 暴露，这里兜底，避免编译期找不到符号。
#ifndef FSCALE
#define FSCALE 65536.0
#endif

#if __has_include(<libproc.h>)
#include <libproc.h>
#define CW_HAVE_LIBPROC 1
#else
#define CW_HAVE_LIBPROC 0
#endif

#pragma mark - CWProcInfo

@implementation CWProcInfo
- (NSDictionary *)dictionaryRepresentation {
    return @{ @"pid"    : @(self.pid),
              @"name"   : self.name ?: @"?",
              @"cpu"    : @(self.cpuPercent),
              @"mem"    : @(self.memBytes),
              @"threads": @(self.threadCount) };
}
+ (instancetype)fromDictionary:(NSDictionary *)d {
    CWProcInfo *p = [CWProcInfo new];
    p.pid = [d[@"pid"] integerValue];
    p.name = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : @"?";
    p.cpuPercent = [d[@"cpu"] doubleValue];
    p.memBytes = (unsigned long long)[d[@"mem"] unsignedLongLongValue];
    p.threadCount = [d[@"threads"] integerValue];
    return p;
}
@end

#pragma mark - CWSnapshot

@implementation CWSnapshot
- (NSDictionary *)dictionaryRepresentation {
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:self.processes.count];
    for (CWProcInfo *p in self.processes) [arr addObject:[p dictionaryRepresentation]];
    return @{ @"ts"        : @(self.timestamp),
              @"totalCPU"  : @(self.totalCPUPercent),
              @"cpuCount"  : @(self.cpuCount),
              @"memRatio"  : @(self.memUsedRatio),
              @"memUsed"   : @(self.memUsedBytes),
              @"memTotal"  : @(self.memTotalBytes),
              @"tier"      : @(self.tier),
              @"processes" : arr };
}
+ (instancetype)snapshotFromDictionary:(NSDictionary *)d {
    CWSnapshot *s = [CWSnapshot new];
    s.timestamp = [d[@"ts"] doubleValue];
    s.totalCPUPercent = [d[@"totalCPU"] doubleValue];
    s.cpuCount = [d[@"cpuCount"] integerValue];
    s.memUsedRatio = [d[@"memRatio"] doubleValue];
    s.memUsedBytes = (unsigned long long)[d[@"memUsed"] unsignedLongLongValue];
    s.memTotalBytes = (unsigned long long)[d[@"memTotal"] unsignedLongLongValue];
    s.tier = [d[@"tier"] integerValue];
    NSMutableArray *arr = [NSMutableArray array];
    for (NSDictionary *pd in d[@"processes"]) {
        if ([pd isKindOfClass:[NSDictionary class]]) [arr addObject:[CWProcInfo fromDictionary:pd]];
    }
    s.processes = arr;
    return s;
}
@end

#pragma mark - CWSampler

@implementation CWSampler {
    // 全局 CPU 上一次的累积 tick
    uint64_t _prevCPUTicks[4];       // user, system, idle, nice（所有核求和）
    BOOL     _havePrevCPU;

    // 每进程上一次的 CPU 累计时间（ns）
    NSMutableDictionary<NSNumber *, NSNumber *> *_prevProcTime;
    double _prevSampleTime;

    NSInteger _cpuCount;
    unsigned long long _memTotal;
}

- (instancetype)init {
    if ((self = [super init])) {
        _prevProcTime = [NSMutableDictionary dictionary];
        _cpuCount = [NSProcessInfo processInfo].processorCount;
        if (_cpuCount <= 0) _cpuCount = 1;
        _memTotal = [self physicalMemory];
    }
    return self;
}

- (unsigned long long)physicalMemory {
    int mib[2] = { CTL_HW, HW_MEMSIZE };
    unsigned long long size = 0;
    size_t len = sizeof(size);
    if (sysctl(mib, 2, &size, &len, NULL, 0) != 0) return 0;
    return size;
}

- (void)prime {
    [self readGlobalCPUTicks];
    [self readProcessTimesInto:nil];
    _prevSampleTime = [NSDate timeIntervalSinceReferenceDate];
}

#pragma mark 全局 CPU

- (BOOL)readGlobalCPUTicks {
    natural_t cpuCount = 0;
    processor_info_array_t info = NULL;
    mach_msg_type_number_t infoCount = 0;

    kern_return_t kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                           &cpuCount, &info, &infoCount);
    if (kr != KERN_SUCCESS || info == NULL) return NO;

    uint64_t sum[4] = {0, 0, 0, 0};
    processor_cpu_load_info_t loads = (processor_cpu_load_info_t)info;
    for (natural_t i = 0; i < cpuCount; i++) {
        sum[0] += loads[i].cpu_ticks[CPU_STATE_USER];
        sum[1] += loads[i].cpu_ticks[CPU_STATE_SYSTEM];
        sum[2] += loads[i].cpu_ticks[CPU_STATE_IDLE];
        sum[3] += loads[i].cpu_ticks[CPU_STATE_NICE];
    }
    // 必须释放，否则每秒泄漏一次
    vm_deallocate(mach_task_self(), (vm_address_t)info, infoCount * sizeof(integer_t));

    if (cpuCount > 0) _cpuCount = (NSInteger)cpuCount;
    for (int i = 0; i < 4; i++) _prevCPUTicks[i] = sum[i];
    return YES;
}

- (double)globalCPUPercent {
    if (!_havePrevCPU) return -1;
    uint64_t user = _prevCPUTicks[0], sys = _prevCPUTicks[1], idle = _prevCPUTicks[2], nice = _prevCPUTicks[3];
    uint64_t total = user + sys + idle + nice;
    if (total == 0) return -1;
    uint64_t busy = user + sys + nice;
    double pct = (double)busy / (double)total * 100.0;
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    return pct;
}

#pragma mark 内存

- (void)readMemoryUsed:(unsigned long long *)used total:(unsigned long long *)total {
    vm_statistics64_data_t vmstat;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    kern_return_t kr = host_statistics64(mach_host_self(), HOST_VM_INFO64,
                                         (host_info64_t)&vmstat, &count);
    if (used) {
        if (kr == KERN_SUCCESS) {
            unsigned long long pageSize = (unsigned long long)sysconf(_SC_PAGESIZE);
            unsigned long long u = ((unsigned long long)vmstat.active_count +
                                    (unsigned long long)vmstat.wire_count +
                                    (unsigned long long)vmstat.compressor_page_count) * pageSize;
            *used = u;
        } else {
            *used = 0;
        }
    }
    if (total) *total = _memTotal;
}

#pragma mark 进程

// 读取全部 pid。sysctl(KERN_PROC_ALL) 在部分沙盒下会失败，失败就返回空。
- (NSArray<NSNumber *> *)allPids {
    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
    size_t len = 0;
    if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0 || len == 0) return @[];

    void *buf = malloc(len + sizeof(struct kinfo_proc) * 8);
    if (!buf) return @[];
    if (sysctl(mib, 3, buf, &len, NULL, 0) != 0) { free(buf); return @[]; }

    struct kinfo_proc *procs = (struct kinfo_proc *)buf;
    int n = (int)(len / sizeof(struct kinfo_proc));
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:(NSUInteger)MAX(n, 0)];
    for (int i = 0; i < n; i++) {
        pid_t pid = procs[i].kp_proc.p_pid;
        if (pid > 0) [out addObject:@(pid)];
    }
    free(buf);
    return out;
}

// 进程显示名：kinfo_proc 的 p_comm 只有 16 字节，容易被截断。
// 能取到完整路径时优先用可执行文件名。
- (NSString *)nameForPid:(pid_t)pid fallback:(NSString *)fallback {
#if CW_HAVE_LIBPROC
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) > 0) {
        NSString *p = [NSString stringWithUTF8String:path];
        if (p.length) return p.lastPathComponent;
    }
#endif
    return fallback.length ? fallback : [NSString stringWithFormat:@"pid %d", pid];
}

// 全进程扫描。返回 pid -> 累计 CPU 时间(ns) 与附加信息。
- (NSMutableDictionary<NSNumber *, NSNumber *> *)readProcessTimesInto:(NSMutableArray<CWProcInfo *> *)out {
    NSMutableDictionary<NSNumber *, NSNumber *> *now = [NSMutableDictionary dictionary];
    double nowTime = [NSDate timeIntervalSinceReferenceDate];
    double dt = nowTime - _prevSampleTime;

    NSArray<NSNumber *> *pids = [self allPids];
    if (pids.count == 0) return now;

    // sysctl 拿到的 pid 顺序不带进程名，补一次 kinfo 扫描取 p_comm
    NSMutableDictionary<NSNumber *, NSString *> *comm = [NSMutableDictionary dictionary];
    {
        int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
        size_t len = 0;
        if (sysctl(mib, 3, NULL, &len, NULL, 0) == 0 && len > 0) {
            void *buf = malloc(len);
            if (buf) {
                if (sysctl(mib, 3, buf, &len, NULL, 0) == 0) {
                    struct kinfo_proc *procs = (struct kinfo_proc *)buf;
                    int n = (int)(len / sizeof(struct kinfo_proc));
                    for (int i = 0; i < n; i++) {
                        pid_t pid = procs[i].kp_proc.p_pid;
                        if (pid <= 0) continue;
                        NSString *c = [NSString stringWithUTF8String:procs[i].kp_proc.p_comm];
                        if (c.length) comm[@(pid)] = c;
                    }
                }
                free(buf);
            }
        }
    }

#if CW_HAVE_LIBPROC
    BOOL canReadDetail = (geteuid() == 0);
    if (canReadDetail) {
        for (NSNumber *pidNum in pids) {
            pid_t pid = (pid_t)pidNum.intValue;
            if (pid <= 0) continue;

            struct proc_taskinfo pti;
            memset(&pti, 0, sizeof(pti));
            int got = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &pti, (int)sizeof(pti));
            if (got <= 0) continue;

            uint64_t cpuTime = pti.pti_total_user + pti.pti_total_system;
            now[pidNum] = @(cpuTime);

            if (out) {
                CWProcInfo *p = [CWProcInfo new];
                p.pid = pid;
                p.name = [self nameForPid:pid fallback:comm[pidNum]];
                p.memBytes = pti.pti_resident_size;
                p.threadCount = (NSInteger)pti.pti_threadnum;

                NSNumber *prev = _prevProcTime[pidNum];
                if (prev && dt > 0.001) {
                    double deltaNs = (double)(cpuTime - prev.unsignedLongLongValue);
                    if (deltaNs < 0) deltaNs = 0;
                    p.cpuPercent = (deltaNs / 1e9) / dt * 100.0;
                } else {
                    p.cpuPercent = 0;
                }
                [out addObject:p];
            }
        }
        return now;
    }
#endif

    // 无 root 的降级路径：内核维护的衰减 CPU 估值 p_pctcpu。
    // 单位是 FSCALE(65536) 定点数，不精确但能排序，够用来找可疑对象。
    {
        int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
        size_t len = 0;
        if (sysctl(mib, 3, NULL, &len, NULL, 0) == 0 && len > 0) {
            void *buf = malloc(len);
            if (buf) {
                if (sysctl(mib, 3, buf, &len, NULL, 0) == 0) {
                    struct kinfo_proc *procs = (struct kinfo_proc *)buf;
                    int n = (int)(len / sizeof(struct kinfo_proc));
                    for (int i = 0; i < n; i++) {
                        pid_t pid = procs[i].kp_proc.p_pid;
                        if (pid <= 0) continue;
                        if (!out) continue;

                        CWProcInfo *p = [CWProcInfo new];
                        p.pid = pid;
                        NSString *c = comm[@(pid)] ?: [NSString stringWithFormat:@"pid %d", pid];
                        p.name = c;
                        p.cpuPercent = (double)procs[i].kp_proc.p_pctcpu / (double)FSCALE * 100.0;
                        p.memBytes = 0;
                        p.threadCount = 0;
                        [out addObject:p];
                    }
                }
                free(buf);
            }
        }
    }
    return now;
}

#pragma mark 采样入口

- (CWSnapshot *)sample {
    CWSnapshot *s = [CWSnapshot new];
    s.timestamp = [NSDate timeIntervalSinceReferenceDate];
    s.cpuCount = _cpuCount;
    s.tier = (NSInteger)CWDetectTier();

    // 全局 CPU：先算差值，再更新基线
    double g = [self globalCPUPercent];
    [self readGlobalCPUTicks];
    _havePrevCPU = YES;
    s.totalCPUPercent = (g < 0) ? 0 : g;

    unsigned long long used = 0, total = 0;
    [self readMemoryUsed:&used total:&total];
    s.memUsedBytes = used;
    s.memTotalBytes = total;
    s.memUsedRatio = (total > 0) ? ((double)used / (double)total) : 0;

    NSMutableArray<CWProcInfo *> *procs = [NSMutableArray array];
    NSMutableDictionary *times = [self readProcessTimesInto:procs];

    _prevProcTime = times ?: [NSMutableDictionary dictionary];
    _prevSampleTime = [NSDate timeIntervalSinceReferenceDate];

    [procs sortUsingComparator:^NSComparisonResult(CWProcInfo *a, CWProcInfo *b) {
        if (a.cpuPercent > b.cpuPercent) return NSOrderedAscending;
        if (a.cpuPercent < b.cpuPercent) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    s.processes = procs;
    return s;
}

@end
