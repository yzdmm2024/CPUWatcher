//
//  cpuwatchctl — CPUWatcher 的按需特权助手
//
//  设计上刻意**不做守护进程**：
//    - 不注册 launchd，开机零执行（白苹果防护第 1 条）
//    - 由设置面板 posix_spawn 拉起，面板返回上级页时被 SIGKILL
//    - 自身 alarm() 硬性存活上限，到点无条件自杀（防孤儿进程长期采样）
//    - 父进程变成 launchd(1) 后立即退出（第二重孤儿防护）
//
//  用法：
//    cpuwatchctl --interval 1000 --duration 60
//    cpuwatchctl --oneshot              # 打印一次采样结果到 stdout，SSH 手测用
//

#import <Foundation/Foundation.h>

#import "CWCommon.h"
#import "CWSampler.h"

#include <signal.h>
#include <pthread.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>

#define CW_PIDFILE "/var/mobile/Media/CPUWatcher/helper.pid"

static volatile sig_atomic_t gShouldExit = 0;

static void CWOnAlarm(int sig) {
    (void)sig;
    // alarm 到点：无条件退出，不给任何"再跑一会儿"的机会
    _exit(0);
}

static void CWOnTerm(int sig) {
    (void)sig;
    gShouldExit = 1;
}

#pragma mark - 单实例保护

// 返回 YES 表示已有存活实例，本次应当直接退出。
static BOOL CWAnotherInstanceRunning(void) {
    int fd = open(CW_PIDFILE, O_RDONLY);
    if (fd < 0) return NO;

    char buf[32] = {0};
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return NO;

    pid_t other = (pid_t)atoi(buf);
    if (other <= 0 || other == getpid()) return NO;

    // 用 kill(pid, 0) 探活；不存在就认为可以接管
    if (kill(other, 0) == 0 || errno == EPERM) return YES;
    return NO;
}

static void CWWritePidFile(void) {
    CWEnsureDataDir();
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "%d\n", getpid());
    int fd = open(CW_PIDFILE, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        ssize_t ignored = write(fd, buf, (size_t)len);
        (void)ignored;
        close(fd);
    }
}

static void CWRemovePidFile(void) {
    unlink(CW_PIDFILE);
}

#pragma mark - 孤儿看门狗

// 面板进程消失后我们会被 launchd 收养（ppid == 1）。
// 这里轮询 ppid，一旦发现被收养就立刻退出，避免变成常驻后台进程。
static void *CWOrphanWatchdog(void *ctx) {
    (void)ctx;
    while (!gShouldExit) {
        if (getppid() == 1) {
            CWRemovePidFile();
            _exit(0);
        }
        usleep((useconds_t)(CW_HELPER_PPID_POLL_SEC * 1000000.0));
    }
    return NULL;
}

#pragma mark - main

int main(int argc, char *argv[]) {
    @autoreleasepool {
        int intervalMs = 1000;
        int durationSec = CW_HELPER_HARD_LIMIT_SEC;
        BOOL oneshot = NO;

        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--interval") == 0 && i + 1 < argc) {
                intervalMs = atoi(argv[++i]);
                if (intervalMs < 200) intervalMs = 200;     // 下限保护：别把自己变成耗电源
                if (intervalMs > 10000) intervalMs = 10000;
            } else if (strcmp(argv[i], "--duration") == 0 && i + 1 < argc) {
                durationSec = atoi(argv[++i]);
            } else if (strcmp(argv[i], "--oneshot") == 0) {
                oneshot = YES;
            } else if (strcmp(argv[i], "--version") == 0) {
                printf("cpuwatchctl %s\n", CW_VERSION_STRING);
                return 0;
            }
        }

        // 硬性存活上限：无论发生什么，到这个点都必须死。
        if (durationSec <= 0 || durationSec > CW_HELPER_HARD_LIMIT_SEC) {
            durationSec = CW_HELPER_HARD_LIMIT_SEC;
        }
        alarm((unsigned)durationSec + 2);

        signal(SIGALRM, CWOnAlarm);
        signal(SIGTERM, CWOnTerm);
        signal(SIGINT,  CWOnTerm);
        signal(SIGHUP,  CWOnTerm);

        CWSampler *sampler = [CWSampler new];
        [sampler prime];

        if (oneshot) {
            // 等一个采样周期，让差值有意义
            usleep((useconds_t)(intervalMs * 1000));
            CWSnapshot *s = [sampler sample];
            NSData *d = [NSJSONSerialization dataWithJSONObject:[s dictionaryRepresentation]
                                                        options:NSJSONWritingPrettyPrinted
                                                          error:NULL];
            fwrite(d.bytes, 1, d.length, stdout);
            printf("\n");
            return 0;
        }

        if (CWAnotherInstanceRunning()) {
            fprintf(stderr, "cpuwatchctl: 已有实例在运行，本次退出\n");
            return 0;
        }

        CWEnsureDataDir();
        CWWritePidFile();

        // 孤儿看门狗线程（detach，进程退出即随之结束）
        pthread_t tid;
        if (pthread_create(&tid, NULL, CWOrphanWatchdog, NULL) == 0) {
            pthread_detach(tid);
        }

        CWWriteJSONAtomically(@{ @"pid"     : @(getpid()),
                                 @"tier"    : @((NSInteger)CWDetectTier()),
                                 @"started" : @([NSDate timeIntervalSinceReferenceDate]),
                                 @"interval": @(intervalMs),
                                 @"limit"   : @(durationSec) },
                              CWStatePath());

        double startTime = [NSDate timeIntervalSinceReferenceDate];

        while (!gShouldExit) {
            @autoreleasepool {
                CWSnapshot *s = [sampler sample];
                CWWriteJSONAtomically([s dictionaryRepresentation], CWSnapshotPath());

                if ([NSDate timeIntervalSinceReferenceDate] - startTime >= durationSec) break;
            }
            // 分片睡眠，保证收到信号后能尽快退出
            int waited = 0;
            while (waited < intervalMs && !gShouldExit) {
                usleep(100 * 1000);
                waited += 100;
            }
        }

        CWRemovePidFile();
        return 0;
    }
}
