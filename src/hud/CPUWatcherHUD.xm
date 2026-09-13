//
//  CPUWatcherHUD — SpringBoard 悬浮窗
//
//  安全设计（严格遵守「不白苹果」）：
//    - 本 dylib 不 hook 任何系统方法，只注册一个 Darwin 通知观察者。
//    - %ctor 里不做任何 IO、不起定时器、不建视图。加载体现在这一步就结束了。
//    - 悬浮窗只有收到面板发来的 "hud.on" 通知才会创建；收到 "hud.off" 立刻销毁
//      并 invalidate 定时器。SpringBoard 重启后没有任何持久状态，必然回到关闭态。
//    - 数据只读面板 helper 写出的 snapshot.json；本进程内不做任何 mach 采样，
//      避免在 SpringBoard 里跑有内存风险的底层代码。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <unistd.h>

#import "CWCommon.h"

#define CWHUD_SNAPSHOT    CW_SNAPSHOT_PATH
// 快照超过这个秒数没更新，就认为数据源已停（面板已返回），显示待机。
#define CWHUD_STALE_SEC   3.0

#pragma mark - 悬浮窗

@interface CWHUDPillWindow : UIWindow
@end

@interface CWHUDPillView : UIView
@property (nonatomic, strong) UILabel *line1;
@property (nonatomic, strong) UILabel *line2;
@end

@implementation CWHUDPillWindow

// 只让药丸本体接手势，其它区域一律穿透，绝不挡住 SpringBoard / App 的触摸。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || [v isKindOfClass:[CWHUDPillWindow class]]) return nil;
    return v;
}

@end

@implementation CWHUDPillView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.62];
        self.layer.cornerRadius = 12.0;
        self.layer.masksToBounds = YES;
        self.userInteractionEnabled = YES;

        _line1 = [[UILabel alloc] initWithFrame:CGRectMake(10, 6, frame.size.width - 20, 16)];
        _line1.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
        _line1.textColor = [UIColor whiteColor];
        _line1.text = @"CPU --";

        _line2 = [[UILabel alloc] initWithFrame:CGRectMake(10, 23, frame.size.width - 20, 14)];
        _line2.font = [UIFont systemFontOfSize:11];
        _line2.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
        _line2.text = @"待机";

        [self addSubview:_line1];
        [self addSubview:_line2];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                             action:@selector(onPan:)];
        [self addGestureRecognizer:pan];

        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                                    action:@selector(onDoubleTap)];
        doubleTap.numberOfTapsRequired = 2;
        [self addGestureRecognizer:doubleTap];
    }
    return self;
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *win = self.superview ?: self;
    CGPoint t = [g translationInView:win];
    CGPoint c = self.center;
    c.x += t.x;
    c.y += t.y;
    // 简单夹取，别拖出屏幕外找不回来
    CGRect bounds = win.bounds;
    c.x = MAX(60.0, MIN(bounds.size.width - 60.0, c.x));
    c.y = MAX(40.0, MIN(bounds.size.height - 40.0, c.y));
    self.center = c;
    [g setTranslation:CGPointZero inView:win];
}

- (void)onDoubleTap {
    // 双击 = 自己关掉自己，同时告诉面板状态已关
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CW_NOTIFY_HUD_OFF, NULL, NULL, true);
}

@end

#pragma mark - 状态回报

// 「悬浮窗没出来」这种情况必须能定位到是哪一步断的，否则只能猜。
// 断点有三处：① 通知压根没送到（dylib 没注入 / 通知名不匹配）；
//             ② 送到了但找不到 UIWindowScene（窗建不出来，静默 return）；
//             ③ 窗建出来了但没显示（层级 / 可见性）。
// 这里把每一步都回报出去：写一份文件（人可读）+ 发一条 Darwin 通知（不依赖文件权限）。
// 通知只能带名字、不能带数据，所以用「一个状态一个名字」的笨办法 ——
// 面板把最后收到的那个名字显示出来，一眼就知道卡在哪。
static void CWHUDReport(CFStringRef state, NSString *extra) {
    // ① 发通知：这条通道不依赖任何文件权限，是主证据
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         state, NULL, NULL, true);
    // ② 尽力落盘：写不进也不影响①（SpringBoard 沙盒可能拒绝写 Media 目录）
    CWEnsureDataDir();
    BOOL ok = CWWriteJSONAtomically(@{ @"ts"    : @([NSDate timeIntervalSinceReferenceDate]),
                                       @"pid"   : @(getpid()),
                                       @"state" : (__bridge NSString *)state,
                                       @"extra" : extra ?: @"" },
                                    CWHUDStatusPath());
    if (!ok) {
        // 文件写不进去这件事本身也是重要信息，用通知再补报一次
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CW_NOTIFY_HUDST_WRITEFAIL, NULL, NULL, true);
    }
}

#pragma mark - 控制器

@interface CWHUDController : NSObject
@property (nonatomic, strong) CWHUDPillWindow *window;
@property (nonatomic, strong) NSTimer *timer;
+ (instancetype)shared;
- (void)show;
- (void)hide;
@end

@implementation CWHUDController

+ (instancetype)shared {
    static CWHUDController *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [CWHUDController new]; });
    return inst;
}

/// 拿 UIWindowScene。iOS 13 之后窗口**必须**挂在 scene 上，否则
/// [[UIWindow alloc] initWithFrame:] 出来的窗永远不会显示 —— 而且不报错，
/// 表现就是"通知也收到了、窗也建了，但屏幕上什么都没有"。
/// 以前这里只查 connectedScenes，查不到就直接 return；现在补三级兜底。
- (UIWindowScene *)activeScene {
    UIApplication *app = UIApplication.sharedApplication;

    // ① 前台活跃的 scene
    for (UIScene *s in app.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)s;
        }
    }
    // ② 任意一个 window scene（SpringBoard 的主 scene 有时不报 ForegroundActive）
    for (UIScene *s in app.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)s;
    }
    // ③ 从已有窗口反推（SpringBoard 一定已经有自己的窗口）
    for (UIWindow *w in app.windows) {
        if (w.windowScene) return w.windowScene;
    }
    return nil;
}

- (void)show {
    if (self.window) { [self refresh]; return; }

    UIWindowScene *scene = [self activeScene];
    if (!scene) {
        // 不静默失败：把"找不到 scene"这件事报出去
        CWHUDReport(CW_NOTIFY_HUDST_NOSCENE,
                    [NSString stringWithFormat:@"connectedScenes=%lu windows=%lu",
                     (unsigned long)UIApplication.sharedApplication.connectedScenes.count,
                     (unsigned long)UIApplication.sharedApplication.windows.count]);
        return;
    }

    CGFloat w = 132.0, h = 44.0;
    CGFloat x = 16.0, y = 90.0;

    CWHUDPillWindow *win = nil;
    if ([CWHUDPillWindow instancesRespondToSelector:@selector(initWithWindowScene:)]) {
        win = [[CWHUDPillWindow alloc] initWithWindowScene:scene];
        win.frame = CGRectMake(x, y, w, h);
    } else {
        win = [[CWHUDPillWindow alloc] initWithFrame:CGRectMake(x, y, w, h)];
    }
    win.windowLevel = UIWindowLevelAlert + 100;
    win.backgroundColor = [UIColor clearColor];
    win.rootViewController = [UIViewController new];
    win.hidden = NO;

    CWHUDPillView *pill = [[CWHUDPillView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    [win.rootViewController.view addSubview:pill];
    self.window = win;

    if (!win.rootViewController) {
        CWHUDReport(CW_NOTIFY_HUDST_NOCTOR, @"rootViewController 建不出来");
        return;
    }

    [self refresh];
    // 刷新定时器挂在主 run loop 的 common modes 上：
    // 否则用户一滑动手势（tracking mode），刷新就停了。
    self.timer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(refresh)
                                       userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];

    CWHUDReport(CW_NOTIFY_HUDST_SHOWN,
                [NSString stringWithFormat:@"level=%.0f frame=%@ scene=%@",
                 win.windowLevel, NSStringFromCGRect(win.frame), NSStringFromClass([scene class])]);
}

- (void)hide {
    [self.timer invalidate];
    self.timer = nil;
    self.window.hidden = YES;
    self.window = nil;
    CWHUDReport(CW_NOTIFY_HUDST_HIDDEN, @"");
}

- (void)refresh {
    if (!self.window) return;
    CWHUDPillView *pill = (CWHUDPillView *)self.window.rootViewController.view.subviews.firstObject;
    if (![pill isKindOfClass:[CWHUDPillView class]]) return;

    NSData *data = [NSData dataWithContentsOfFile:CWHUD_SNAPSHOT];
    NSDictionary *snap = nil;
    if (data.length) {
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([obj isKindOfClass:[NSDictionary class]]) snap = obj;
    }

    if (!snap) {
        pill.line1.text = @"CPU --";
        pill.line2.text = @"待机（未采集）";
        return;
    }

    NSTimeInterval ts = [snap[@"ts"] doubleValue];
    NSTimeInterval age = [NSDate timeIntervalSinceReferenceDate] - ts;
    if (age > CWHUD_STALE_SEC) {
        pill.line1.text = @"CPU --";
        pill.line2.text = @"待机（面板已离开）";
        return;
    }

    double cpu = [snap[@"totalCPU"] doubleValue];
    double memRatio = [snap[@"memRatio"] doubleValue];
    pill.line1.text = [NSString stringWithFormat:@"CPU %.0f%%   内存 %.0f%%", cpu, memRatio * 100.0];

    NSArray *procs = snap[@"processes"];
    if ([procs isKindOfClass:[NSArray class]] && procs.count > 0) {
        NSDictionary *top = procs.firstObject;
        if ([top isKindOfClass:[NSDictionary class]]) {
            pill.line2.text = [NSString stringWithFormat:@"%@ %.0f%%",
                               top[@"name"] ?: @"?", [top[@"cpu"] doubleValue]];
            return;
        }
    }
    pill.line2.text = @"—";
}

@end

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
    BOOL ok = CWWriteJSONAtomically(@{ @"ts"      : @([NSDate timeIntervalSinceReferenceDate]),
                                       @"pid"     : @(getpid()),
                                       @"process" : [NSProcessInfo processInfo].processName ?: @"?",
                                       @"plugins" : plugins },
                                    CWInjectedListPath());
    // 写成功/失败都回报 —— 失败时面板能直接说清是"写不进 Media 目录"，
    // 而不是笼统地甩一句"没拿到清单"。
    CWHUDReport(ok ? CW_NOTIFY_HUDST_DUMPOK : CW_NOTIFY_HUDST_DUMPFAIL,
                [NSString stringWithFormat:@"%lu 个 dylib", (unsigned long)plugins.count]);
}

#pragma mark - 通知桥

static void CWHUDNotifyCallback(CFNotificationCenterRef center,
                                void *observer,
                                CFNotificationName name,
                                const void *object,
                                CFDictionaryRef userInfo) {
    if (!name) return;
    // 通知回调在任意线程，UI 操作一律切主队列
    if (CFStringCompare(name, CW_NOTIFY_HUD_ON, 0) == kCFCompareEqualTo) {
        dispatch_async(dispatch_get_main_queue(), ^{ [[CWHUDController shared] show]; });
    } else if (CFStringCompare(name, CW_NOTIFY_HUD_OFF, 0) == kCFCompareEqualTo) {
        dispatch_async(dispatch_get_main_queue(), ^{ [[CWHUDController shared] hide]; });
    } else if (CFStringCompare(name, CW_NOTIFY_DUMP_INJECTED, 0) == kCFCompareEqualTo) {
        // 用户主动点按钮才触发；放后台队列，绝不占主线程（更不能在启动路径上）。
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
                                    CW_NOTIFY_HUD_ON,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    CWHUDNotifyCallback,
                                    CW_NOTIFY_HUD_OFF,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
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
