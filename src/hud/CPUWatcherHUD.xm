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

- (UIWindowScene *)activeScene {
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)s;
        }
    }
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)s;
    }
    return nil;
}

- (void)show {
    if (self.window) { [self refresh]; return; }

    UIWindowScene *scene = [self activeScene];
    if (!scene) return;   // 没有场景就不要硬建窗口

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

    [self refresh];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                  target:self
                                                selector:@selector(refresh)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)hide {
    [self.timer invalidate];
    self.timer = nil;
    self.window.hidden = YES;
    self.window = nil;
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
}
