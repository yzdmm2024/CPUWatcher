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
#import <sys/resource.h>
#include <pwd.h>
#include <unistd.h>
#include <string.h>

// FSCALE 在部分 SDK 里不随 sys/param.h 暴露，这里兜底，避免编译期找不到符号。
#ifndef FSCALE
#define FSCALE 65536.0
#endif

// ⚠️ 不要改回 #include <libproc.h>。
// CI 的 iPhoneOS SDK 里没有这个头文件，用 __has_include 开关会导致整个
// proc_pidinfo 分支在编译期被静默裁掉（v0.1.2 就是这么翻车的）。
// 这里统一走自包含的 shim：dlsym 运行时解析 + 自声明结构体。
// 细节与证据见 CWProcShim.h 顶部。
#import "CWProcShim.h"

#pragma mark - CWProcInfo

@implementation CWProcInfo
- (NSDictionary *)dictionaryRepresentation {
    return @{ @"pid"     : @(self.pid),
              @"name"    : self.name ?: @"?",
              @"cpu"     : @(self.cpuPercent),
              @"mem"     : @(self.memBytes),
              @"threads" : @(self.threadCount),
              @"energyNJ": @(self.energyNJ),
              @"wkups"   : @(self.wakeups),
              @"nJps"    : @(self.energyNJPerSec),
              @"wkupsPs" : @(self.wakeupsPerSec),
              @"hasEnergy": @(self.hasEnergy) };
}
+ (instancetype)fromDictionary:(NSDictionary *)d {
    CWProcInfo *p = [CWProcInfo new];
    p.pid = [d[@"pid"] integerValue];
    p.name = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : @"?";
    p.cpuPercent = [d[@"cpu"] doubleValue];
    p.memBytes = (unsigned long long)[d[@"mem"] unsignedLongLongValue];
    p.threadCount = [d[@"threads"] integerValue];
    p.energyNJ = (unsigned long long)[d[@"energyNJ"] unsignedLongLongValue];
    p.wakeups = (unsigned long long)[d[@"wkups"] unsignedLongLongValue];
    p.energyNJPerSec = [d[@"nJps"] doubleValue];
    p.wakeupsPerSec = [d[@"wkupsPs"] doubleValue];
    p.hasEnergy = [d[@"hasEnergy"] boolValue];
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
              @"detailOK"  : @(self.detailOK),
              @"totalPids" : @(self.totalPids),
              @"src"       : self.src ?: @"?",
              @"caps"      : self.caps ?: @"?",
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
    s.detailOK = [d[@"detailOK"] integerValue];
    s.totalPids = [d[@"totalPids"] integerValue];
    s.src = [d[@"src"] isKindOfClass:[NSString class]] ? d[@"src"] : @"?";
    s.caps = [d[@"caps"] isKindOfClass:[NSString class]] ? d[@"caps"] : @"?";
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

    // 每进程上一次的能耗累计（纳焦）与中断唤醒次数。
    // 内核给的是从进程启动起的累计量，必须两次求差才是"当前耗电速率"。
    NSMutableDictionary<NSNumber *, NSNumber *> *_prevEnergy;
    NSMutableDictionary<NSNumber *, NSNumber *> *_prevWakeups;
    NSMutableDictionary<NSNumber *, NSNumber *> *_newEnergy;
    NSMutableDictionary<NSNumber *, NSNumber *> *_newWakeups;

    // 本轮是否有任何进程成功取到能耗数据（用于面板如实标注"该数据不可用"）
    BOOL _energySupported;

    // 最近一轮「能读到明细的进程数 / 总进程数」。
    // 会随快照一起写出去：下次再出"全 0"，看一眼就知道是权限被拒（0/218）
    // 还是代码压根没跑到这条路上。
    NSInteger _lastDetailOK;
    NSInteger _lastTotalPids;

    NSInteger _cpuCount;
    unsigned long long _memTotal;
}

- (instancetype)init {
    if ((self = [super init])) {
        _prevProcTime  = [NSMutableDictionary dictionary];
        _prevEnergy    = [NSMutableDictionary dictionary];
        _prevWakeups   = [NSMutableDictionary dictionary];
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

// 进程显示名：kinfo_proc 的 p_comm 只有 16 字节，会被硬截断
// （症状：SiriTTSSynthesiz / MTLCompilerServi 这种缺尾巴的名字）。
// 能取到完整路径时优先用可执行文件名。
- (NSString *)nameForPid:(pid_t)pid fallback:(NSString *)fallback {
    NSString *full = CWProcPathForPid(pid);
    if (full.length) return full.lastPathComponent;
    return fallback.length ? fallback : [NSString stringWithFormat:@"pid %d", pid];
}

#pragma mark 能耗 / 唤醒

// 读单个进程的能耗累计值与中断唤醒累计值，并算出相对上一轮的速率。
//
// 为什么必须做差：内核给的是「进程启动至今」的累计量，直接显示等于显示进程年龄。
// 取不到时保持 hasEnergy = NO —— 界面据此如实标注"该数据不可用"，不拿 0 冒充。
- (void)fillEnergyForProcess:(CWProcInfo *)p
                   pidNumber:(NSNumber *)pidNum
                   deltaTime:(double)dt {
    cw_rusage_info_v4_t ri;
    if (CWProcRusageForPid((int)p.pid, &ri) != 0) return;

    p.hasEnergy = YES;
    p.energyNJ  = (unsigned long long)ri.ri_billed_energy;
    p.wakeups   = (unsigned long long)(ri.ri_interrupt_wkups + ri.ri_pkg_idle_wkups);

    NSNumber *pe = _prevEnergy[pidNum];
    NSNumber *pw = _prevWakeups[pidNum];
    if (pe && pw && dt > 0.001) {
        double de = (double)p.energyNJ - (double)pe.unsignedLongLongValue;
        double dw = (double)p.wakeups  - (double)pw.unsignedLongLongValue;
        // 进程重启 / pid 复用会让累计量倒退，负值一律归零而不是显示成负耗电
        p.energyNJPerSec = de > 0 ? de / dt : 0;
        p.wakeupsPerSec  = dw > 0 ? dw / dt : 0;
    }
    _newEnergy[pidNum]  = @(p.energyNJ);
    _newWakeups[pidNum] = @(p.wakeups);
    _energySupported = YES;
}

// 全进程扫描。返回 pid -> 累计 CPU 时间(ns) 与附加信息。
- (NSMutableDictionary<NSNumber *, NSNumber *> *)readProcessTimesInto:(NSMutableArray<CWProcInfo *> *)out {
    NSMutableDictionary<NSNumber *, NSNumber *> *now = [NSMutableDictionary dictionary];
    _newEnergy  = [NSMutableDictionary dictionary];
    _newWakeups = [NSMutableDictionary dictionary];
    _energySupported = NO;

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

    // ── 每进程明细 ────────────────────────────────────────────────
    //
    // 这里踩过两个坑，都记下来免得再犯：
    //
    // 坑一（v0.1.2 的真根因）：旧代码把这段包在 `#if __has_include(<libproc.h>)` 里。
    //   CI 的 iPhoneOS SDK 没有 libproc.h → 判定为假 → **整段在编译期被裁掉**，
    //   CI 日志里毫无异常。装到手机上就是每进程 CPU 全 0.0%、内存 —、线程 0、
    //   进程名截断成 16 字符（走 p_comm 兜底）。现在统一走 CWProcShim，
    //   不再依赖任何 SDK 头文件。
    //
    // 坑二：更早的版本用 `geteuid() == 0` 当门槛，把非 root 环境整个挡回
    //   p_pctcpu 兜底 —— 而新版 XNU 把该字段恒置为 0，也会得到"全 0"。
    //   真机实测（uid=501 非 root）proc_pidinfo / proc_pid_rusage 对
    //   SpringBoard / backboardd / WeChat 全部成功，只有 launchd(pid 1) 被拒。
    //   所以门槛只能由**系统调用的返回值**决定，不能由 uid 决定。
    //
    // 结论：无条件尝试，用返回值说话；一条都读不到才退回兜底，并如实上报。
    NSUInteger detailOK = 0;
    for (NSNumber *pidNum in pids) {
        pid_t pid = (pid_t)pidNum.intValue;
        if (pid <= 0) continue;

        cw_proc_taskinfo_t pti;
        int got = CWProcInfoForPid(pid, &pti);
        if (got <= 0) continue;      // launchd 这类被内核保护的进程，跳过即可
        detailOK++;

        uint64_t cpuTime = pti.pti_total_user + pti.pti_total_system;
        now[pidNum] = @(cpuTime);

        if (!out) continue;

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

        // ---- 能耗 / 唤醒：只看 proc_pid_rusage 有没有被拒，与 uid 无关 ----
        [self fillEnergyForProcess:p pidNumber:pidNum deltaTime:dt];

        [out addObject:p];
    }
    // 把「能不能读到明细」如实记录下来，随快照一起交给面板显示。
    // 这样"全 0"这种症状下次一眼就能分辨是权限被拒还是代码没编进去。
    _lastDetailOK  = (NSInteger)detailOK;
    _lastTotalPids = (NSInteger)pids.count;
    if (detailOK > 0) return now;

    // ── 兜底路径：连 proc_pidinfo 都读不到时 ──────────────────────
    //
    // 用内核维护的衰减 CPU 估值 p_pctcpu（FSCALE 定点数）。
    // ⚠️ 注意：新版 XNU 已把该字段恒置为 0，所以这条路上 CPU 会全是 0。
    // 它的存在意义只是「还能列出进程」，不是「还能测 CPU」——
    // 面板会据此明确显示"明细不可读"，而不是让用户以为机器很闲。
    {
        _lastDetailOK = 0;
        _lastTotalPids = (NSInteger)pids.count;
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
                        // 名字还是尽量取全：p_comm 只有 16 字节，会被截断成
                        // SiriTTSSynthesiz / MTLCompilerServi 这种缺尾巴的形式。
                        p.name = [self nameForPid:pid fallback:c];
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
    // 数据来源 + 明细可读性 + libproc 入口状态，全部随快照发出。
    // 这样即使跨进程，也能从文件里直接看出"是谁采的、采到了什么、缺什么"。
    s.src = self.samplerTag.length ? self.samplerTag : @"?";
    s.caps = CWProcShimCaps();

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

    _prevProcTime   = times ?: [NSMutableDictionary dictionary];
    _prevEnergy     = _newEnergy  ?: [NSMutableDictionary dictionary];
    _prevWakeups    = _newWakeups ?: [NSMutableDictionary dictionary];
    _prevSampleTime = [NSDate timeIntervalSinceReferenceDate];

    [procs sortUsingComparator:^NSComparisonResult(CWProcInfo *a, CWProcInfo *b) {
        if (a.cpuPercent > b.cpuPercent) return NSOrderedAscending;
        if (a.cpuPercent < b.cpuPercent) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    s.processes = procs;
    s.detailOK = _lastDetailOK;
    s.totalPids = _lastTotalPids;
    return s;
}

@end
