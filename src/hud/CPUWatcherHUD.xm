//
//  CPUWatcherHUD — SpringBoard 驻留代理（无悬浮窗）
//
//  安全设计（严格遵守「不白苹果」）：
//    - 本 dylib 不 hook 任何系统方法，只注册 Darwin 通知观察者。
//    - %ctor 里不做任何 IO、不起定时器、不建视图。加载体现在这一步就结束了。
//    - 所有工作都是用户主动点按钮后才触发；SpringBoard 重启后没有任何持久状态。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <unistd.h>

#import "CWCommon.h"
#import "CWConflictScan.h"

#pragma mark - 注入清单导出

// 在 SpringBoard 内部遍历 _dyld_image_name，得到「真实加载了哪些插件 dylib」。
//
// 为什么必须在这里做：跨进程拿别人的 image list 需要 task_for_pid + 远程读内存，
// 而本进程就是 SpringBoard —— 直接问 dyld，零风险、零权限、结果还是真值
// （不是靠解析 Filter plist 猜出来的）。
//
// 顺带取每个 dylib 的 LC_UUID：崩溃日志的 usedImages 里用的就是 UUID，
// 有了它才能把 .ips 里崩掉的地址对上具体是哪个插件。
static void CWDumpInjectedImages(void) {
    NSMutableArray *plugins = [NSMutableArray array];
    uint32_t n = _dyld_image_count();

    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm) continue;
        NSString *path = [NSString stringWithUTF8String:nm];
        if (!path.length) continue;

        // 只保留越狱注入通道里的库。系统框架不列，否则几百行根本没法看。
        BOOL isTweak = [path containsString:@"TweakInject"] ||
                       [path containsString:@"MobileSubstrate"] ||
                       [path containsString:@"/var/jb/"] ||
                       [path containsString:@".jbroot"];
        if (!isTweak) continue;

        NSString *uuid = @"";
        const struct mach_header_64 *h =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (h) {
            const uint8_t *p = (const uint8_t *)h + sizeof(struct mach_header_64);
            for (uint32_t c = 0; c < h->ncmds; c++) {
                const struct load_command *lc = (const struct load_command *)p;
                if (lc->cmdsize == 0) break;
                if (lc->cmd == LC_UUID) {
                    const struct uuid_command *uc = (const struct uuid_command *)lc;
                    uuid = [NSString stringWithFormat:
                            @"%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
                            uc->uuid[0],  uc->uuid[1],  uc->uuid[2],  uc->uuid[3],
                            uc->uuid[4],  uc->uuid[5],  uc->uuid[6],  uc->uuid[7],
                            uc->uuid[8],  uc->uuid[9],  uc->uuid[10], uc->uuid[11],
                            uc->uuid[12], uc->uuid[13], uc->uuid[14], uc->uuid[15]];
                    break;
                }
                p += lc->cmdsize;
            }
        }

        [plugins addObject:@{ @"name"    : path.lastPathComponent,
                              @"path"    : path,
                              @"uuid"    : uuid,
                              @"loadAddr": [NSString stringWithFormat:@"0x%llx",
                                            (unsigned long long)(uintptr_t)h] }];
    }

    CWEnsureDataDir();
    CWWriteJSONAtomically(@{ @"ts"      : @([NSDate timeIntervalSinceReferenceDate]),
                             @"pid"     : @(getpid()),
                             @"process" : [NSProcessInfo processInfo].processName ?: @"?",
                             @"plugins" : plugins },
                          CWInjectedListPath());
}

#pragma mark - 通知桥

static void CWHUDNotifyCallback(CFNotificationCenterRef center,
                                void *observer,
                                CFNotificationName name,
                                const void *object,
                                CFDictionaryRef userInfo) {
    if (!name) return;
    // 通知回调在任意线程，UI 操作一律切主队列；扫描类枚举必须放后台队列，避免卡死 SB。
    if (CFStringCompare(name, CW_NOTIFY_DUMP_INJECTED, 0) == kCFCompareEqualTo) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            CWDumpInjectedImages();
        });
    } else if (CFStringCompare(name, CW_NOTIFY_SCAN_CONFLICTS, 0) == kCFCompareEqualTo) {
        // P4 冲突扫描：必须在后台线程跑，否则遍历上万类会卡死 SpringBoard 主线程
        //（看门狗风险 / 白苹果）。扫描完自行广播 SCAN_DONE。
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            CWRunConflictScan();
        });
    }
}

// %ctor 的职责严格限制为「注册观察者」。
// 这里不做 IO、不解码资源、不起定时器、不建视图 —— 加载体现在这一步就结束了，
// 因此不可能拖慢或卡死 SpringBoard 启动。
%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    CWHUDNotifyCallback,
                                    CW_NOTIFY_DUMP_INJECTED,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    CWHUDNotifyCallback,
                                    CW_NOTIFY_SCAN_CONFLICTS,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}
