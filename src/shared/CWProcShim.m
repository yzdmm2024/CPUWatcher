//
//  CWProcShim.m
//  CPUWatcher
//
//  实现说明见 CWProcShim.h 顶部。核心两点：
//    ① dlsym 运行时解析，编译/链接期不依赖 SDK 里的 libproc 头与符号；
//    ② 每次调用都校验返回值，ABI 对不上就报失败，不把垃圾当数据。
//

#import "CWProcShim.h"

#include <dlfcn.h>
#include <string.h>
#include <dispatch/dispatch.h>

typedef int (*cw_pidinfo_fn)(int, int, uint64_t, void *, int);
typedef int (*cw_rusage_fn)(int, int, void *);
typedef int (*cw_pidpath_fn)(int, void *, uint32_t);

static cw_pidinfo_fn cw_f_pidinfo = NULL;
static cw_rusage_fn  cw_f_rusage  = NULL;
static cw_pidpath_fn cw_f_pidpath = NULL;

// PROC_PIDPATHINFO_MAXSIZE
#define CW_PIDPATH_MAX 4096

static void cw_shim_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 这些入口在 libsystem_kernel / libsystem 里，进程一启动就已加载。
        // 用 RTLD_DEFAULT 在「已加载镜像」里查即可，不需要 dlopen 具体路径，
        // 因此不会因为路径在 rootless / jbroot 下变形而失败。
        cw_f_pidinfo = (cw_pidinfo_fn)dlsym(RTLD_DEFAULT, "proc_pidinfo");
        if (!cw_f_pidinfo) cw_f_pidinfo = (cw_pidinfo_fn)dlsym(RTLD_DEFAULT, "_proc_pidinfo");

        cw_f_rusage = (cw_rusage_fn)dlsym(RTLD_DEFAULT, "proc_pid_rusage");
        if (!cw_f_rusage) cw_f_rusage = (cw_rusage_fn)dlsym(RTLD_DEFAULT, "_proc_pid_rusage");

        cw_f_pidpath = (cw_pidpath_fn)dlsym(RTLD_DEFAULT, "proc_pidpath");
        if (!cw_f_pidpath) cw_f_pidpath = (cw_pidpath_fn)dlsym(RTLD_DEFAULT, "_proc_pidpath");

        // ⚠️ 这里不能调 CWProcShimCaps() —— 它会再调 cw_shim_init()，
        // dispatch_once 重入直接死锁。日志自己拼。
        NSLog(@"[CPUWatcher] proc shim 就绪: pidinfo=%@ rusage=%@ pidpath=%@",
              cw_f_pidinfo ? @"有" : @"无",
              cw_f_rusage ? @"有" : @"无",
              cw_f_pidpath ? @"有" : @"无");
    });
}

BOOL CWProcShimReady(void) {
    cw_shim_init();
    return (cw_f_pidinfo != NULL);
}

NSString *CWProcShimCaps(void) {
    cw_shim_init();
    return [NSString stringWithFormat:@"pidinfo=%@ rusage=%@ pidpath=%@",
            cw_f_pidinfo ? @"有" : @"无",
            cw_f_rusage  ? @"有" : @"无",
            cw_f_pidpath ? @"有" : @"无"];
}

int CWProcInfoForPid(int pid, cw_proc_taskinfo_t *out) {
    cw_shim_init();
    if (!out || pid <= 0) return 0;
    memset(out, 0, sizeof(*out));
    if (!cw_f_pidinfo) return 0;

    int n = cw_f_pidinfo(pid, CW_PROC_PIDTASKINFO, 0, out, (int)sizeof(*out));
    // 内核正常会写满前 96 字节。返回值过小说明结构体布局与内核不一致，
    // 这种情况必须报失败 —— 否则会拿错位的数字当真数据（比如把 uuid 当 rss）。
    if (n < 48) return 0;
    return n;
}

int CWProcRusageForPid(int pid, cw_rusage_info_v4_t *out) {
    cw_shim_init();
    if (!out || pid <= 0) return -1;
    memset(out, 0, sizeof(*out));
    if (!cw_f_rusage) return -1;
    return cw_f_rusage(pid, CW_RUSAGE_INFO_V4, out);
}

NSString *CWProcPathForPid(int pid) {
    cw_shim_init();
    if (!cw_f_pidpath || pid <= 0) return nil;

    char buf[CW_PIDPATH_MAX];
    memset(buf, 0, sizeof(buf));
    int n = cw_f_pidpath(pid, buf, (uint32_t)sizeof(buf));
    if (n <= 0) return nil;
    buf[sizeof(buf) - 1] = '\0';
    NSString *s = [NSString stringWithUTF8String:buf];
    return s.length ? s : nil;
}
