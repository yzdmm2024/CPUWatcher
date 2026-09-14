//
//  CWTweakProfile — 在 SpringBoard 内做 tweak CPU / 内存归因（v0.1.8）
//
//  思路（无 root、只读、不 hook）：
//    本进程就是 SpringBoard，所以直接用 mach_task_self() 拿到自己的 task，
//    不需要 task_for_pid（那才需要 root）。步骤：
//      ① task_threads 取全部线程；
//      ② 对每个线程 thread_info(THREAD_BASIC_INFO) 记录累计 CPU 时间（user+system，微秒）；
//      ③ sleep 2.5s；
//      ④ 再取一次，求差 = 该线程窗口内消耗 CPU；
//      ⑤ 对消耗显著的「热线程」采一次 PC（suspend + get_state + resume），
//         dladdr(PC) 查落点 dylib；落在某个 tweak dylib => 这份 CPU 归它；
//      ⑥ 另统计每个 tweak dylib 的映射大小（mach-o 各 LC_SEGMENT_64 vmsize 之和）。
//
//  安全：只读，不改任何内存、不起定时器、不 hook。后台线程跑，不会卡 SB 主线程。
//  局限：只能归因注入到 SpringBoard 的 tweak（绝大多数系统级耗电/卡顿 tweak 都在这里）。
//

#import "CWTweakProfile.h"
#import "CWCommon.h"

#import <mach/mach.h>
#import <mach/arm/thread_status.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <unistd.h>

// 判定一个镜像路径是不是「越狱注入的 tweak dylib」（与冲突扫描同源启发式）。
static BOOL CWIsTweakImage(NSString *path) {
    if (!path.length) return NO;
    if ([path containsString:@"TweakInject"])      return YES;
    if ([path containsString:@"MobileSubstrate"])  return YES;
    if ([path containsString:@"DynamicLibraries"]) return YES;
    if ([path containsString:@".jbroot"])          return YES;
    if ([path hasPrefix:@"/var/jb/"])              return YES;
    return NO;
}

// 把 time_value_t 折成微秒。
static uint64_t CWTimeValUs(const time_value_t *tv) {
    return (uint64_t)tv->seconds * 1000000ULL + (uint64_t)tv->microseconds;
}

void CWRunTweakProfile(void) {
    @autoreleasepool {
        NSDate *start = [NSDate date];

        mach_port_t selfTask = mach_task_self();
        mach_port_t selfThread = mach_thread_self();
        thread_act_port_array_t threads = NULL;
        mach_msg_type_number_t tcount = 0;
        kern_return_t kr = task_threads(selfTask, &threads, &tcount);
        if (kr != KERN_SUCCESS || tcount == 0) {
            CWEnsureDataDir();
            CWWriteJSONAtomically(@{ @"ts":@([NSDate timeIntervalSinceReferenceDate]),
                                    @"pid":@(getpid()),
                                    @"error":@"task_threads 失败",
                                    @"tweaks":@[] }, CWTweakProfilePath());
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CW_NOTIFY_TWEAK_PROFILE_DONE, NULL, NULL, true);
            if (threads) vm_deallocate(selfTask, (vm_address_t)threads, tcount * sizeof(mach_port_t));
            return;
        }

        // 第一遍：记录每线程累计 CPU 时间（跳过采样线程自己）。
        NSMutableArray<NSNumber *> *idxList = [NSMutableArray array]; // 在 threads[] 里的下标
        NSMutableArray<NSNumber *> *cpu0 = [NSMutableArray array];
        for (mach_msg_type_number_t i = 0; i < tcount; i++) {
            thread_act_t t = threads[i];
            if (t == selfThread) continue;
            thread_basic_info_data_t info;
            mach_msg_type_number_t ic = THREAD_BASIC_INFO_COUNT;
            if (thread_info(t, THREAD_BASIC_INFO, (thread_info_t)&info, &ic) == KERN_SUCCESS) {
                [idxList addObject:@(i)];
                [cpu0 addObject:@(CWTimeValUs(&info.user_time) + CWTimeValUs(&info.system_time))];
            }
        }

        // 采样窗口。
        [NSThread sleepForTimeInterval:2.5];

        // 第二遍：求差，热线程采 PC 归因。
        uint64_t totalDelta = 0;
        NSMutableDictionary<NSString *, NSNumber *> *cpuByImage = [NSMutableDictionary dictionary];
        for (NSUInteger k = 0; k < idxList.count; k++) {
            mach_msg_type_number_t idx = [idxList[k] unsignedIntValue];
            thread_act_t t = threads[idx];
            thread_basic_info_data_t info;
            mach_msg_type_number_t ic = THREAD_BASIC_INFO_COUNT;
            uint64_t us1 = 0, us0 = [cpu0[k] unsignedLongLongValue];
            if (thread_info(t, THREAD_BASIC_INFO, (thread_info_t)&info, &ic) == KERN_SUCCESS) {
                us1 = CWTimeValUs(&info.user_time) + CWTimeValUs(&info.system_time);
            }
            int64_t delta = (int64_t)us1 - (int64_t)us0;
            if (delta < 0) delta = 0;
            totalDelta += (uint64_t)delta;
            if (delta < 2000) continue; // 窗口内 <2ms 的线程当作噪声跳过

            // 采一次 PC：suspend -> get_state -> resume（瞬时，不长期阻塞 SB）。
            if (thread_suspend(t) == KERN_SUCCESS) {
                arm_thread_state64_t state;
                mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
                if (thread_get_state(t, ARM_THREAD_STATE64, (thread_state_t)&state, &sc) == KERN_SUCCESS) {
                    // 不依赖 SDK 的 __pc 字段名（不同 SDK 命名不同），按 Apple arm64
                    // 线程状态布局直接取 PC：x[29] + fp + lr + sp + pc，单位为 uint32，
                    // pc 落在 uint32 偏移 64..65（小端）。
                    uint32_t *sp32 = (uint32_t *)&state;
                    uintptr_t pc = ((uintptr_t)sp32[65] << 32) | sp32[64];
                    Dl_info dli;
                    if (dladdr((void *)pc, &dli) && dli.dli_fname) {
                        NSString *img = @(dli.dli_fname);
                        if (CWIsTweakImage(img)) {
                            uint64_t cur = [cpuByImage[img] unsignedLongLongValue];
                            cpuByImage[img] = @(cur + (uint64_t)delta);
                        }
                    }
                }
                thread_resume(t);
            }
        }

        // 内存：每个 tweak dylib 的映射大小（mach-o 各段 vmsize 之和）。
        NSMutableDictionary<NSString *, NSNumber *> *memByImage = [NSMutableDictionary dictionary];
        uint32_t imgCount = _dyld_image_count();
        for (uint32_t i = 0; i < imgCount; i++) {
            const char *nm = _dyld_get_image_name(i);
            if (!nm) continue;
            NSString *p = @(nm);
            if (!CWIsTweakImage(p)) continue;
            uint64_t mapped = 0;
            const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(i);
            if (h) {
                const uint8_t *q = (const uint8_t *)h + sizeof(struct mach_header_64);
                for (uint32_t c = 0; c < h->ncmds; c++) {
                    const struct load_command *lc = (const struct load_command *)q;
                    if (lc->cmdsize == 0) break;
                    if (lc->cmd == LC_SEGMENT_64) {
                        const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
                        mapped += sg->vmsize;
                    }
                    q += lc->cmdsize;
                }
            }
            memByImage[p] = @(mapped);
        }

        // 汇总：先放有 CPU 消耗的，再补「零 CPU 但已加载」的（只展示内存）。
        NSMutableArray<NSMutableDictionary *> *tweaks = [NSMutableArray array];
        for (NSString *img in cpuByImage) {
            uint64_t cpuUs = [cpuByImage[img] unsignedLongLongValue];
            double pct = totalDelta > 0 ? (double)cpuUs / (double)totalDelta * 100.0 : 0.0;
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            d[@"name"] = img.lastPathComponent;
            d[@"path"] = img;
            d[@"cpuPercent"] = @(pct);
            d[@"cpuDeltaUs"] = @(cpuUs);
            d[@"memMappedBytes"] = memByImage[img] ?: @0;
            [tweaks addObject:d];
        }
        for (NSString *img in memByImage) {
            BOOL found = NO;
            for (NSDictionary *d in tweaks) {
                if ([d[@"path"] isEqualToString:img]) { found = YES; break; }
            }
            if (!found) {
                NSMutableDictionary *d = [NSMutableDictionary dictionary];
                d[@"name"] = img.lastPathComponent;
                d[@"path"] = img;
                d[@"cpuPercent"] = @0.0;
                d[@"cpuDeltaUs"] = @0;
                d[@"memMappedBytes"] = memByImage[img];
                [tweaks addObject:d];
            }
        }
        [tweaks sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"cpuPercent" ascending:NO]]];

        NSDictionary *result = @{
            @"ts":             @([NSDate timeIntervalSinceReferenceDate]),
            @"pid":            @(getpid()),
            @"durationSec":    @(-[start timeIntervalSinceNow]),
            @"totalThreads":   @(tcount),
            @"totalCpuDeltaUs":@(totalDelta),
            @"note":           @"仅覆盖注入到 SpringBoard 的 tweak；注入具体 App 的 tweak 不在此列。"
                                @"内存为 dylib 映射大小（近似，非精确常驻）。",
            @"tweaks":         tweaks,
        };

        CWEnsureDataDir();
        CWWriteJSONAtomically(result, CWTweakProfilePath());

        // 清掉线程端口，避免泄漏。
        for (mach_msg_type_number_t i = 0; i < tcount; i++) {
            mach_port_deallocate(selfTask, threads[i]);
        }
        vm_deallocate(selfTask, (vm_address_t)threads, tcount * sizeof(mach_port_t));

        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CW_NOTIFY_TWEAK_PROFILE_DONE, NULL, NULL, true);
    }
}
