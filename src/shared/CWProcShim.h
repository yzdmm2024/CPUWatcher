//
//  CWProcShim.h — libproc 的最小自包含绑定
//  CPUWatcher
//
//  ── 为什么要自己写这一层（这是 v0.1.2 那个"CPU 全 0"的真根因）──────────────
//
//  旧代码是这么写的：
//      #if __has_include(<libproc.h>)
//      #include <libproc.h>
//      #define CW_HAVE_LIBPROC 1
//      #else
//      #define CW_HAVE_LIBPROC 0
//      #endif
//
//  而 theos CI 用的 iPhoneOS SDK 里**根本没有 libproc.h**（也没有 sys/proc_info.h）。
//  于是 `__has_include` 判定为假，整个 proc_pidinfo / proc_pid_rusage / proc_pidpath
//  分支在预处理阶段就被整块裁掉，编译期一声不响。
//
//  证据（对 CI 产出的 deb 直接查符号，不靠猜）：
//      cpuwatchctl 里 sysctl 出现 4 次、host_processor_info 出现 4 次，
//      而 _proc_pidinfo / proc_pid_rusage / proc_pidpath 出现 0 次。
//  运行时的表现就是面板上：每进程 CPU 全 0.0%、内存「—」、线程 0、
//  进程名被截断成 16 字符（SiriTTSSynthesiz / MTLCompilerServi）——
//  因为走了 kinfo_proc.p_comm 兜底，而 CPU 用的 p_pctcpu 在新版 XNU 上恒为 0。
//
//  ── 这一层的做法 ─────────────────────────────────────────────
//    ① 结构体按 XNU bsd/sys/proc_info.h、bsd/sys/resource.h 逐字段对齐，
//       并在尾部留 32~64 字节余量（多给缓冲区永远安全，少给才会写越界）；
//    ② 函数用 dlsym(RTLD_DEFAULT) 运行时解析 —— 编译期不依赖任何 SDK 头，
//       链接期不产生未定义符号（不受 .tbd 里有没有这些符号影响）；
//    ③ 每次调用都对返回值做合理性校验，ABI 不匹配时宁可报失败，
//       也不把垃圾数据当成真实数值显示出去。
//

#ifndef CW_PROC_SHIM_H
#define CW_PROC_SHIM_H

#import <Foundation/Foundation.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// libproc.h 里的 flavor 常量（这里写死，免得依赖头文件）
#define CW_PROC_PIDTASKINFO   4
#define CW_RUSAGE_INFO_V4     4

/// 对应 XNU 的 struct proc_taskinfo。64 位下内核写入 96 字节。
typedef struct {
    uint64_t pti_virtual_size;
    uint64_t pti_resident_size;
    uint64_t pti_total_user;
    uint64_t pti_total_system;
    uint64_t pti_threads_user;
    uint64_t pti_threads_system;
    int32_t  pti_policy;
    int32_t  pti_faults;
    int32_t  pti_pageins;
    int32_t  pti_cow_faults;
    int32_t  pti_messages_sent;
    int32_t  pti_messages_received;
    int32_t  pti_syscalls_mach;
    int32_t  pti_syscalls_unix;
    int32_t  pti_csw;
    int32_t  pti_threadnum;
    int32_t  pti_numrunning;
    int32_t  pti_priority;
    uint8_t  cw_tail[32];      // 余量，不参与计算
} cw_proc_taskinfo_t;

/// 对应 XNU 的 struct rusage_info_v4（字段顺序与 sys/resource.h 完全一致）。
/// ri_billed_energy 位于偏移 264 —— 这一点早在真机上用 frida 按偏移读过并拿到
/// 真实增量（SpringBoard 2 秒 +71029 nJ），偏移是对的。
typedef struct {
    uint8_t  ri_uuid[16];
    uint64_t ri_user_time;
    uint64_t ri_system_time;
    uint64_t ri_pkg_idle_wkups;
    uint64_t ri_interrupt_wkups;
    uint64_t ri_pageins;
    uint64_t ri_wired_size;
    uint64_t ri_resident_size;
    uint64_t ri_phys_footprint;
    uint64_t ri_proc_start_abstime;
    uint64_t ri_proc_exit_abstime;
    uint64_t ri_child_user_time;
    uint64_t ri_child_system_time;
    uint64_t ri_child_pkg_idle_wkups;
    uint64_t ri_child_interrupt_wkups;
    uint64_t ri_child_pageins;
    uint64_t ri_child_elapsed_abstime;
    uint64_t ri_diskio_bytesread;
    uint64_t ri_diskio_byteswritten;
    uint64_t ri_cpu_time_qos_default;
    uint64_t ri_cpu_time_qos_maintenance;
    uint64_t ri_cpu_time_qos_background;
    uint64_t ri_cpu_time_qos_utility;
    uint64_t ri_cpu_time_qos_legacy;
    uint64_t ri_cpu_time_qos_user_initiated;
    uint64_t ri_cpu_time_qos_user_interactive;
    uint64_t ri_billed_system_time;
    uint64_t ri_serviced_system_time;
    uint64_t ri_logical_writes;
    uint64_t ri_lifetime_max_phys_footprint;
    uint64_t ri_instructions;
    uint64_t ri_cycles;
    uint64_t ri_billed_energy;      // 偏移 264
    uint64_t ri_serviced_energy;
    uint64_t ri_interval_max_phys_footprint;
    uint64_t ri_runnable_time;
    uint64_t cw_tail[8];            // 余量，不参与计算
} cw_rusage_info_v4_t;

/// 运行时符号是否解析成功。为 NO 说明这台设备/这个进程拿不到 libproc 入口，
/// 此时所有读取都会失败 —— 由调用方如实上报，不要装成"数据是 0"。
BOOL CWProcShimReady(void);

/// 一句话描述各入口是否拿到（写进自检弹窗与快照，方便远程定位）
NSString *CWProcShimCaps(void);

/// 读进程 taskinfo。返回内核写入的字节数；<=0 表示失败。
int CWProcInfoForPid(int pid, cw_proc_taskinfo_t *out);

/// 读进程 rusage（含能耗 / 唤醒）。返回 0 表示成功，非 0 表示失败。
int CWProcRusageForPid(int pid, cw_rusage_info_v4_t *out);

/// 取可执行文件完整路径（用于拿到不被 16 字节截断的进程名）。失败返回 nil。
NSString *CWProcPathForPid(int pid);

#ifdef __cplusplus
}
#endif

#endif /* CW_PROC_SHIM_H */
