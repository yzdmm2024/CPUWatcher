//
//  CPUWatcherPrefs — 设置面板
//
//  按需激活的核心在这里：
//    进入「实时监控」页 viewDidAppear  -> 拉起 cpuwatchctl
//    返回上级页 viewWillDisappear      -> 立即 SIGKILL 掉它
//  离开页面后不存在任何后台采样进程，符合「返回出去就不生效」的要求。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Preferences/Preferences.h>

#import "CWCommon.h"
#import "CWSampler.h"

#include <spawn.h>
#include <signal.h>
#include <sys/wait.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

static NSString *CWFormatTierShort(CWTier t);

// ---- P4 冲突扫描：面板 <-> HUD 通信 ----
// 主 @interface 与结果页控制器 @interface 前置，使下方 C 回调和引用都能看到完整类型
//（category/extension 不允许在类完整定义之前声明）。
@interface CPUWatcherPrefsController : PSListController
@property (nonatomic, strong) UIAlertController *scanAlert;
- (void)runConflictScan:(id)sender;
- (void)cwScanDidFinish;
- (void)cwPresentConflictResult;
- (void)runTweakProfile:(id)sender;
- (void)cwTweakProfileDidFinish;
- (void)cwPresentTweakProfileResult;
@end

@interface CWConflictViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSDictionary *result;
@property (nonatomic, strong) NSArray *tweaks;
@property (nonatomic, strong) NSArray *conflicts;
@property (nonatomic, strong) UITableView *table;
- (instancetype)initWithResult:(NSDictionary *)r;
@end

@interface CWConflictDetailViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSDictionary *tweak;
@property (nonatomic, strong) NSArray *hooks;
@property (nonatomic, strong) UITableView *table;
- (instancetype)initWithTweak:(NSDictionary *)t;
@end

@interface CWTweakProfileViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSDictionary *result;
@property (nonatomic, strong) NSArray *tweaks;
@property (nonatomic, strong) UITableView *table;
- (instancetype)initWithResult:(NSDictionary *)r;
@end

@class CPUWatcherPrefsController;
static __weak CPUWatcherPrefsController *gVisiblePrefs = nil;

// HUD 扫描完成后广播 SCAN_DONE，回调里把结果页推出来（实现见文件末尾）。
static void CWScanDoneCallback(CFNotificationCenterRef center, void *observer,
                               CFNotificationName name, const void *object, CFDictionaryRef userInfo);
static void CWTweakProfileDoneCallback(CFNotificationCenterRef center, void *observer,
                                       CFNotificationName name, const void *object, CFDictionaryRef userInfo);
static void cwRegisterScanDoneOnce(void);
static void cwRegisterTweakProfileDoneOnce(void);

static NSString * const kPrefsSuite   = @"com.axs.cpuwatcher";
static NSString * const kPrefSortMode = @"lastSortMode";

#pragma mark - 跨进程配置读写（rootless 下这里最容易翻车）

// 面板写出的开关值，在 rootless 环境下实际落在 jbroot 里的域 plist：
//   /var/jb/var/mobile/Library/Preferences/com.axs.cpuwatcher.plist
// 而 App / SpringBoard 侧用 suite 或 CFPreferences 都可能读不到同一个位置。
// 所以读取走三条通道依次试，并把「是哪条命中的」一起返回 ——
// 自检弹窗会显示它，避免下次又对着"填了不生效"干猜。
static id CWPrefGet(NSString *key, NSString **sink) {
    // ① jbroot 共享 plist（rootless 真身，也是 SpringBoard 侧能读到的那份）
    NSArray<NSString *> *files = @[
        @"/var/jb/var/mobile/Library/Preferences/com.axs.cpuwatcher.plist",
        @"/var/mobile/Library/Preferences/com.axs.cpuwatcher.plist"
    ];
    for (NSString *p in files) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if ([d isKindOfClass:[NSDictionary class]] && d[key] != nil) {
            if (sink) *sink = [NSString stringWithFormat:@"域 plist %@", p];
            return d[key];
        }
    }
    // ② 容器 suite
    id v = [[[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite] objectForKey:key];
    if (v != nil) { if (sink) *sink = @"容器 suite"; return v; }

    // ③ cfprefsd
    CFPropertyListRef cv = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                     CFSTR("com.axs.cpuwatcher"));
    if (cv) { if (sink) *sink = @"cfprefsd"; return CFBridgingRelease(cv); }

    if (sink) *sink = @"三通道都没读到";
    return nil;
}

static id CWPrefGet2(NSString *key) { return CWPrefGet(key, NULL); }

// 双写：NSUserDefaults(suite) + CFPreferences。
// 两条路在 rootless 下会落到不同的位置，都写一遍才能保证面板与 SpringBoard
// 两侧读到同一个值。
static void CWPrefSet(NSString *key, id value) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite];
    [d setObject:value forKey:key];
    [d synchronize];

    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             CFSTR("com.axs.cpuwatcher"));
    CFPreferencesAppSynchronize(CFSTR("com.axs.cpuwatcher"));
}

#pragma mark - helper 生命周期

/// 面板进程内持有的 helper 会话。只允许杀自己 spawn 出来的 pid。
@interface CWHelperSession : NSObject
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, assign) BOOL  spawnFailed;
@property (nonatomic, copy)   NSString *failReason;
- (BOOL)startWithIntervalMs:(int)ms duration:(int)sec;
- (void)stop;
@end

@implementation CWHelperSession

- (BOOL)startWithIntervalMs:(int)ms duration:(int)sec {
    [self stop];
    self.spawnFailed = NO;
    self.failReason = nil;

    NSString *path = CWHelperLaunchPath();
    if (!path) {
        self.spawnFailed = YES;
        self.failReason = @"未找到 cpuwatchctl（deb 可能没装上或路径不对）";
        return NO;
    }

    char ip[24], du[24];
    snprintf(ip, sizeof(ip), "%d", ms);
    snprintf(du, sizeof(du), "%d", sec);

    char *argv[] = {
        (char *)[path fileSystemRepresentation],
        (char *)"--interval", ip,
        (char *)"--duration", du,
        NULL
    };

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);

    pid_t child = 0;
    int rc = posix_spawn(&child, [path fileSystemRepresentation], &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);

    if (rc != 0) {
        // Preferences 是沙盒进程，spawn 越狱目录下的二进制可能被拒。
        // 这里不硬来，直接如实记录并让 UI 走降级路径。
        self.spawnFailed = YES;
        self.failReason = [NSString stringWithFormat:@"无法启动特权助手（%@，errno %d）",
                           @(strerror(rc)), rc];
        return NO;
    }

    self.pid = child;
    return YES;
}

- (void)stop {
    if (self.pid <= 0) return;
    pid_t p = self.pid;
    self.pid = 0;
    kill(p, SIGKILL);
    // 收尸，避免留下僵尸进程
    for (int i = 0; i < 20; i++) {
        int status = 0;
        pid_t r = waitpid(p, &status, WNOHANG);
        if (r == p || r == -1) break;
        usleep(20 * 1000);
    }
}

- (void)dealloc {
    [self stop];
}

@end

#pragma mark - 实时监控页（纯 UIViewController，不用任何私有列表 API）

typedef NS_ENUM(NSInteger, CWSortMode) {
    CWSortByCPU = 0,     // CPU 占用
    CWSortByMemory,      // 内存占用
    CWSortByWakeups,     // 中断唤醒次数/秒
    CWSortByThreads,     // 线程数
    CWSortByName,        // 进程名（字母序，稳定不跳动）
    CWSortByEnergy,      // 能耗（仅本机支持时）
};

@interface CWMonitorViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) CWHelperSession *session;
@property (nonatomic, strong) CWSampler *fallbackSampler;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *legendLabel;
@property (nonatomic, strong) UIBarButtonItem *sortButton;
@property (nonatomic, strong) UIBarButtonItem *pauseButton;
@property (nonatomic, strong) CWSnapshot *snapshot;
@property (nonatomic, strong) NSArray<CWProcInfo *> *sorted;
@property (nonatomic, assign) CWSortMode sortMode;
@property (nonatomic, assign) BOOL usingHelper;
@property (nonatomic, assign) BOOL energyAvailable;
@property (nonatomic, assign) NSInteger helperMisses;
@property (nonatomic, copy)   NSString *statusText;
@property (nonatomic, assign) BOOL paused;

// ---- 监控页内悬浮浮层（前 3 名，点按切 CPU/内存，长按关闭）----
@property (nonatomic, assign) CWSortMode hudMetric;      // 浮层自己的排序依据，与页面排序独立
@property (nonatomic, assign) BOOL hudBuilt;
@property (nonatomic, strong) UIView *hudPanel;
@property (nonatomic, strong) UILabel *hudTitle;
@property (nonatomic, strong) UILabel *hudTotal;
@property (nonatomic, strong) UILabel *hudFoot;
@property (nonatomic, strong) NSMutableArray<NSMutableArray<UILabel *> *> *hudRows; // 每行 4 个: rank/name/tag/val
@property (nonatomic, assign) BOOL hudDragging;       // 拖动浮层中：避免 tick 重排抢位置
@end

// 指向当前可见的监控页，用于「开关一拨就立刻生效」。
// weak：页面销毁后自动变 nil，不需要手动清理。
static __weak CWMonitorViewController *gVisibleMonitor = nil;

@implementation CWMonitorViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"实时监控";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.sortMode = (CWSortMode)[CWPrefGet2(kPrefSortMode) integerValue];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, self.view.bounds.size.width - 32, 52)];
    _statusLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    _statusLabel.numberOfLines = 3;
    _statusLabel.textColor = [UIColor secondaryLabelColor];
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _statusText = @"准备中…";

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = 58.0;

    _legendLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _legendLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    _legendLabel.numberOfLines = 0;
    _legendLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    // 底部常驻图例：把每行 [系统]/[App]/[越狱] 徽章的颜色含义讲清，并说明真正的
    // 插件(tweak) 是注入宿主进程的 dylib，不会单独出现在进程列表里（去根页冲突扫描看）。
    NSMutableAttributedString *leg = [[NSMutableAttributedString alloc] init];
    NSDictionary *legBase = @{ NSFontAttributeName: [UIFont systemFontOfSize:11],
                               NSForegroundColorAttributeName: [UIColor tertiaryLabelColor] };
    void (^legTag)(NSString *, UIColor *) = ^(NSString *t, UIColor *c) {
        [leg appendAttributedString:[[NSAttributedString alloc]
              initWithString:t attributes:@{ NSForegroundColorAttributeName: c,
                                            NSFontAttributeName: [UIFont boldSystemFontOfSize:11] }]];
    };
    legTag(@"[系统] ", [UIColor systemGrayColor]);
    [leg appendAttributedString:[[NSAttributedString alloc] initWithString:@"iOS 自带   " attributes:legBase]];
    legTag(@"[App] ", [UIColor systemGreenColor]);
    [leg appendAttributedString:[[NSAttributedString alloc] initWithString:@"你装的   " attributes:legBase]];
    legTag(@"[越狱] ", [UIColor systemOrangeColor]);
    [leg appendAttributedString:[[NSAttributedString alloc] initWithString:@"越狱工具\n" attributes:legBase]];
    [leg appendAttributedString:[[NSAttributedString alloc]
          initWithString:@"真正的插件(tweak) 是注入宿主进程的 dylib，不单独出现 → 根页「插件冲突扫描」看完整清单"
                   attributes:legBase]];
    _legendLabel.attributedText = leg;

    _sortButton = [[UIBarButtonItem alloc] initWithTitle:@"排序"
                                                   style:UIBarButtonItemStylePlain
                                                  target:self
                                                  action:@selector(showSortMenu:)];
    _pauseButton = [[UIBarButtonItem alloc] initWithTitle:@"暂停"
                                                    style:UIBarButtonItemStylePlain
                                                   target:self
                                                   action:@selector(togglePause:)];
    self.navigationItem.rightBarButtonItems = @[ _pauseButton, _sortButton ];
    [self updateSortButtonTitle];

    [self.view addSubview:_statusLabel];
    [self.view addSubview:_table];
    [self.view addSubview:_legendLabel];

    _hudMetric = CWSortByCPU;
    [self buildHUDPanel];

    _session = [CWHelperSession new];
    _fallbackSampler = [CWSampler new];
    // 标记数据来源：面板内采样与助手采样的结果会分别标注，
    // 出问题时一眼就能看出是哪条路给的数（两条路的权限环境不同）。
    _fallbackSampler.samplerTag = @"panel";
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat top = self.view.safeAreaInsets.top;
    CGFloat bottom = self.view.safeAreaInsets.bottom;
    _statusLabel.frame = CGRectMake(16, top + 6, w - 32, 52);
    CGFloat legendH = 52.0;
    _legendLabel.frame = CGRectMake(16, self.view.bounds.size.height - bottom - legendH, w - 32, legendH);
    _table.frame = CGRectMake(0, top + 58, w, self.view.bounds.size.height - top - bottom - legendH - 58);
}

- (void)updateSortButtonTitle {
    NSString *name = @"CPU";
    switch (self.sortMode) {
        case CWSortByMemory:  name = @"内存"; break;
        case CWSortByWakeups: name = @"唤醒"; break;
        case CWSortByThreads: name = @"线程"; break;
        case CWSortByName:    name = @"名称"; break;
        case CWSortByEnergy:  name = @"能耗"; break;
        default:              name = @"CPU";  break;
    }
    _sortButton.title = [NSString stringWithFormat:@"排序：%@", name];
}

- (void)showSortMenu:(id)sender {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"排序方式"
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSNumber *> *modes = @[ @(CWSortByCPU), @(CWSortByMemory), @(CWSortByWakeups),
                                    @(CWSortByThreads), @(CWSortByName), @(CWSortByEnergy) ];
    NSArray<NSString *> *titles = @[ @"CPU 占用", @"内存占用", @"唤醒次数/秒",
                                     @"线程数", @"进程名（稳定不跳动）", @"能耗（若支持）" ];
    for (NSUInteger i = 0; i < modes.count; i++) {
        CWSortMode m = (CWSortMode)[modes[i] integerValue];
        NSString *t = titles[i];
        UIAlertActionStyle style = (m == self.sortMode) ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault;
        [ac addAction:[UIAlertAction actionWithTitle:t style:style handler:^(UIAlertAction *action) {
            self.sortMode = m;
            CWPrefSet(kPrefSortMode, @(self.sortMode));
            [self updateSortButtonTitle];
            [self resort];
            [self.table reloadData];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)togglePause:(id)sender {
    self.paused = !self.paused;
    _pauseButton.title = self.paused ? @"继续" : @"暂停";
    if (!self.paused) {
        [self resort];
        [self.table reloadData];
    }
}

#pragma mark 生命周期的核心：进来才开，出去就关

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    gVisibleMonitor = self;
    [self startMonitoring];
    [self updateHUDVisibility];
}

- (void)viewWillDisappear:(BOOL)animated {
    // 必须在主线程同步把它杀掉，不能丢给后台队列 —— 用户返回了就必须马上停。
    [self stopMonitoring];
    if (gVisibleMonitor == self) gVisibleMonitor = nil;
    [super viewWillDisappear:animated];
}

- (void)dealloc {
    [self stopMonitoring];
}

- (void)startMonitoring {
    if (self.timer) return;

    CWEnsureDataDir();

    // 清掉上一轮的旧快照，避免把过期数据显示成实时值
    [[NSFileManager defaultManager] removeItemAtPath:CWSnapshotPath() error:NULL];

    int intervalMs = 1000;
    self.helperMisses = 0;
    self.usingHelper = [self.session startWithIntervalMs:intervalMs duration:CW_HELPER_HARD_LIMIT_SEC];

    if (!self.usingHelper) {
        [self.fallbackSampler prime];
    }

    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                  target:self
                                                selector:@selector(tick)
                                                userInfo:nil
                                                 repeats:YES];

    [self tick];
}

- (void)stopMonitoring {
    [self.timer invalidate];
    self.timer = nil;
    [self.session stop];

    // 面板离开后不留快照，避免读到陈旧数据
    [[NSFileManager defaultManager] removeItemAtPath:CWSnapshotPath() error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:CWStatePath() error:NULL];
}

static NSString *CWFormatTierShort(CWTier t) {
    switch (t) {
        case CWTierFull:       return @"每进程 CPU / 内存 / 能耗 / 唤醒全部可读";
        case CWTierProcBasic:  return @"仅进程列表（读不到每进程 CPU 与能耗）";
        case CWTierGlobalOnly: return @"仅全局 CPU 与内存";
    }
    return @"";
}

- (void)tick {
    if (self.usingHelper) {
        NSDictionary *d = CWReadJSON(CWSnapshotPath());
        if (d) {
            self.snapshot = [CWSnapshot snapshotFromDictionary:d];
            self.helperMisses = 0;
        } else {
            self.helperMisses++;
            // 助手起不来、或没权限写快照文件时不能装死 —— 连读三拍没数据就切回
            // 面板内采样。采样器已不再用 uid 做门槛，两条路径读到的都是真数据。
            if (self.helperMisses >= 3) {
                self.usingHelper = NO;
                [self.session stop];
                [self.fallbackSampler prime];
                self.statusText = [NSString stringWithFormat:@"助手无数据，已切为面板内采样（%@）",
                                   CWTierName(CWDetectTier())];
                self.snapshot = [self.fallbackSampler sample];
            } else {
                self.statusText = [NSString stringWithFormat:@"助手已启动（PID %d），等待首个采样…",
                                   self.session.pid];
            }
        }
    } else {
        self.snapshot = [self.fallbackSampler sample];
    }

    // 暂停时继续收数据，但不刷新表格，方便用户看清某一行、复制内容
    if (self.paused) {
        self.statusLabel.text = [NSString stringWithFormat:@"%@   [已暂停，列表不动]", self.statusText];
        return;
    }
    self.statusLabel.text = self.statusText;
    [self resort];
    [self.table reloadData];
    [self updateHUDVisibility];
}

#pragma mark 排序

- (void)resort {
    NSArray<CWProcInfo *> *procs = self.snapshot.processes ?: @[];
    self.energyAvailable = NO;
    for (CWProcInfo *p in procs) { if (p.hasEnergy) { self.energyAvailable = YES; break; } }

    // 以当前排序键为主，进程名为副键，避免数值相等时顺序乱跳。
    NSArray<CWProcInfo *> *arr = [procs sortedArrayUsingComparator:^NSComparisonResult(CWProcInfo *a, CWProcInfo *b) {
        NSComparisonResult r = NSOrderedSame;
        switch (self.sortMode) {
            case CWSortByMemory:
                if (a.memBytes > b.memBytes) r = NSOrderedAscending;
                else if (a.memBytes < b.memBytes) r = NSOrderedDescending;
                break;
            case CWSortByWakeups:
                if (a.wakeupsPerSec > b.wakeupsPerSec) r = NSOrderedAscending;
                else if (a.wakeupsPerSec < b.wakeupsPerSec) r = NSOrderedDescending;
                break;
            case CWSortByThreads:
                if (a.threadCount > b.threadCount) r = NSOrderedAscending;
                else if (a.threadCount < b.threadCount) r = NSOrderedDescending;
                break;
            case CWSortByName:
                r = [a.name localizedCaseInsensitiveCompare:b.name];
                break;
            case CWSortByEnergy:
                if (a.energyNJPerSec > b.energyNJPerSec) r = NSOrderedAscending;
                else if (a.energyNJPerSec < b.energyNJPerSec) r = NSOrderedDescending;
                break;
            default: // CWSortByCPU
                if (a.cpuPercent > b.cpuPercent) r = NSOrderedAscending;
                else if (a.cpuPercent < b.cpuPercent) r = NSOrderedDescending;
                break;
        }
        if (r == NSOrderedSame) {
            r = [a.name localizedCaseInsensitiveCompare:b.name];
        }
        return r;
    }];
    self.sorted = arr;
}

#pragma mark 悬浮浮层（监控页内，前 3 名 + 点按切 CPU/内存 + 长按关闭）

// 复用监控页已经采到的 self.snapshot，不额外采样；因此零额外耗电。
// 只显示 CPU / 内存 前 3 名，每行带：名次 + 进程名 + 类别标签 + 数值，
// 彻底解决旧版「只能看见数字、不知道是哪个」的问题。
- (void)buildHUDPanel {
    if (self.hudBuilt) return;
    self.hudBuilt = YES;

    UIView *panel = [[UIView alloc] init];
    panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.84];
    panel.layer.cornerRadius = 16;
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
    panel.layer.shadowColor = [UIColor blackColor].CGColor;
    panel.layer.shadowOpacity = 0.5;
    panel.layer.shadowRadius = 12;
    panel.layer.shadowOffset = CGSizeMake(0, 6);
    panel.hidden = YES;
    [self.view addSubview:panel];
    self.hudPanel = panel;

    _hudTitle = [[UILabel alloc] init];
    _hudTitle.text = @"CPU 监视器";
    _hudTitle.font = [UIFont boldSystemFontOfSize:12];
    _hudTitle.textColor = [UIColor whiteColor];
    _hudTotal = [[UILabel alloc] init];
    _hudTotal.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
    _hudTotal.textColor = [UIColor colorWithWhite:0.82 alpha:1];
    _hudTotal.textAlignment = NSTextAlignmentRight;
    [panel addSubview:_hudTitle];
    [panel addSubview:_hudTotal];

    _hudRows = [NSMutableArray array];
    for (int i = 0; i < 3; i++) {
        NSMutableArray *cells = [NSMutableArray array];
        UILabel *rank = [[UILabel alloc] init];
        rank.font = [UIFont boldSystemFontOfSize:11];
        rank.textAlignment = NSTextAlignmentCenter;
        rank.layer.cornerRadius = 5; rank.clipsToBounds = YES;
        UILabel *name = [[UILabel alloc] init];
        name.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        name.textColor = [UIColor whiteColor];
        name.lineBreakMode = NSLineBreakByTruncatingTail;
        UILabel *tag = [[UILabel alloc] init];
        tag.font = [UIFont boldSystemFontOfSize:9];
        tag.textAlignment = NSTextAlignmentCenter;
        tag.layer.cornerRadius = 4; tag.clipsToBounds = YES;
        UILabel *val = [[UILabel alloc] init];
        val.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
        val.textColor = [UIColor whiteColor];
        val.textAlignment = NSTextAlignmentRight;
        [panel addSubview:rank]; [panel addSubview:name]; [panel addSubview:tag]; [panel addSubview:val];
        [cells addObject:rank]; [cells addObject:name]; [cells addObject:tag]; [cells addObject:val];
        [_hudRows addObject:cells];
    }

    _hudFoot = [[UILabel alloc] init];
    _hudFoot.font = [UIFont systemFontOfSize:9];
    _hudFoot.textColor = [UIColor colorWithWhite:0.55 alpha:1];
    _hudFoot.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:_hudFoot];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onHUDTap:)];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onHUDLongPress:)];
    lp.minimumPressDuration = 0.6;
    // 拖动：可在屏幕内任意移动浮层（点按切 CPU/内存、长按关闭 仍生效）。
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onHUDPan:)];
    [panel addGestureRecognizer:tap];
    [panel addGestureRecognizer:lp];
    [panel addGestureRecognizer:pan];
    // 长按优先于拖动，避免长按被拖动吞掉。
    [pan requireGestureRecognizerToFail:lp];
}

- (void)layoutHUDPanel {
    if (self.hudDragging) return;  // 拖动中不抢位置
    CGFloat pad = 10, rowH = 26, titleH = 18, footH = 14;
    CGFloat w = 206;
    CGFloat h = 10 + titleH + 8 + 3 * rowH + 8 + footH + 10;
    // 记忆落点优先；否则默认右上角。
    CGFloat x = [CWPrefGet2(CW_HUD_ORIGIN_X_KEY) doubleValue];
    CGFloat y = [CWPrefGet2(CW_HUD_ORIGIN_Y_KEY) doubleValue];
    BOOL hasSaved = (x > 0 && y > 0 &&
                     x + w <= self.view.bounds.size.width &&
                     y + h <= self.view.bounds.size.height);
    if (!hasSaved) {
        x = self.view.bounds.size.width - w - 12;
        y = self.view.safeAreaInsets.top + 64;
    }
    self.hudPanel.frame = CGRectMake(x, y, w, h);

    _hudTitle.frame = CGRectMake(pad, 10, w - 2 * pad - 70, titleH);
    _hudTotal.frame = CGRectMake(w - pad - 70, 10, 70, titleH);
    CGFloat ry = 10 + titleH + 8;
    for (int i = 0; i < 3; i++) {
        NSArray *c = _hudRows[i];
        UILabel *rank = c[0], *name = c[1], *tag = c[2], *val = c[3];
        rank.frame = CGRectMake(pad, ry + (rowH - 18) / 2, 18, 18);
        name.frame = CGRectMake(pad + 24, ry, w - 2 * pad - 24 - 22 - 52, rowH);
        tag.frame  = CGRectMake(w - pad - 22 - 52, ry + (rowH - 14) / 2, 22, 14);
        val.frame  = CGRectMake(w - pad - 48, ry, 48, rowH);
        ry += rowH;
    }
    _hudFoot.frame = CGRectMake(pad, ry + 2, w - 2 * pad, footH);
}

- (void)updateHUDVisibility {
    BOOL show = [CWPrefGet2(CW_HUD_ENABLED_KEY) boolValue] && self.isViewLoaded && self.view.window;
    self.hudPanel.hidden = !show;
    if (show) {
        [self layoutHUDPanel];
        [self updateHUDPanel];
    }
}

- (void)updateHUDPanel {
    if (self.hudPanel.hidden) return;
    CWSnapshot *snap = self.snapshot;
    _hudTotal.text = snap ? [NSString stringWithFormat:@"全局 %.0f%%", snap.totalCPUPercent] : @"—";
    NSArray<CWProcInfo *> *procs = snap.processes ?: @[];
    NSArray *sorted = [procs sortedArrayUsingComparator:^NSComparisonResult(CWProcInfo *a, CWProcInfo *b) {
        double av = (self.hudMetric == CWSortByMemory) ? (double)a.memBytes : a.cpuPercent;
        double bv = (self.hudMetric == CWSortByMemory) ? (double)b.memBytes : b.cpuPercent;
        if (av > bv) return NSOrderedAscending;
        if (av < bv) return NSOrderedDescending;
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    for (int i = 0; i < 3; i++) {
        NSArray *c = _hudRows[i];
        UILabel *rank = c[0], *name = c[1], *tag = c[2], *val = c[3];
        if (i < (int)sorted.count) {
            CWProcInfo *p = sorted[i];
            rank.hidden = name.hidden = tag.hidden = val.hidden = NO;
            rank.text = @(i + 1).stringValue;
            UIColor *rc = (i == 0) ? [UIColor colorWithRed:1 green:0.84 blue:0.04 alpha:1]
                        : (i == 1) ? [UIColor colorWithWhite:0.78 alpha:1]
                                   : [UIColor colorWithRed:0.84 green:0.6 blue:0.41 alpha:1];
            rank.backgroundColor = rc;
            rank.textColor = [UIColor colorWithWhite:0.11 alpha:1];
            name.text = p.name ?: @"?";
            CWProcKind k = CWProcKindForPath(p.execPath);
            tag.text = CWProcKindName(k);
            UIColor *tc, *bg;
            if (k == CWProcKindApp)            { tc = [UIColor systemGreenColor];  bg = [[UIColor systemGreenColor] colorWithAlphaComponent:0.18]; }
            else if (k == CWProcKindJailbreak) { tc = [UIColor systemOrangeColor]; bg = [[UIColor systemOrangeColor] colorWithAlphaComponent:0.18]; }
            else                               { tc = [UIColor systemGrayColor];   bg = [[UIColor systemGrayColor] colorWithAlphaComponent:0.2]; }
            tag.textColor = tc; tag.backgroundColor = bg;
            val.text = (self.hudMetric == CWSortByMemory)
                       ? (p.memBytes ? CWFormattedBytes(p.memBytes) : @"—")
                       : [NSString stringWithFormat:@"%.1f%%", p.cpuPercent];
        } else {
            rank.hidden = name.hidden = tag.hidden = val.hidden = YES;
        }
    }
    _hudFoot.text = (self.hudMetric == CWSortByMemory)
                    ? @"内存 · 点按切 CPU · 长按关闭"
                    : @"CPU · 点按切内存 · 长按关闭";
}

- (void)onHUDTap:(id)sender {
    self.hudMetric = (self.hudMetric == CWSortByMemory) ? CWSortByCPU : CWSortByMemory;
    [self updateHUDPanel];
}

- (void)onHUDLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    // 长按关闭：写偏好把开关置 OFF，浮层立即隐藏；返回设置面板时开关已为关闭态。
    CWPrefSet(CW_HUD_ENABLED_KEY, @NO);
    self.hudPanel.hidden = YES;
    [self updateHUDVisibility];
    self.statusText = @"悬浮窗已关闭（可在设置里重新开启）";
    self.statusLabel.text = self.statusText;
}

// 拖动浮层：可在屏幕内任意移动；松手记忆落点（存面板域，跨重开生效）。
- (void)onHUDPan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        self.hudDragging = YES;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:self.view];
        CGPoint c = _hudPanel.center;
        c.x += t.x; c.y += t.y;
        CGFloat hw = _hudPanel.bounds.size.width, hh = _hudPanel.bounds.size.height;
        CGFloat minX = hw / 2, maxX = self.view.bounds.size.width - hw / 2;
        CGFloat minY = hh / 2, maxY = self.view.bounds.size.height - hh / 2;
        if (maxX < minX) maxX = minX;
        if (maxY < minY) maxY = minY;
        c.x = MAX(minX, MIN(maxX, c.x));
        c.y = MAX(minY, MIN(maxY, c.y));
        _hudPanel.center = c;
        [g setTranslation:CGPointZero inView:self.view];
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled) {
        self.hudDragging = NO;
        CGFloat x = _hudPanel.frame.origin.x, y = _hudPanel.frame.origin.y;
        CWPrefSet(CW_HUD_ORIGIN_X_KEY, @(x));
        CWPrefSet(CW_HUD_ORIGIN_Y_KEY, @(y));
    }
}

#pragma mark 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSUInteger n = self.sorted.count;
    return n > 30 ? 30 : n;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (!self.snapshot) return @"进程";
    NSString *head = [NSString stringWithFormat:@"全局 %.0f%%   内存 %@ / %@",
                      self.snapshot.totalCPUPercent,
                      CWFormattedBytes(self.snapshot.memUsedBytes),
                      CWFormattedBytes(self.snapshot.memTotalBytes)];
    if (self.sortMode == CWSortByEnergy && !self.energyAvailable) {
        head = [head stringByAppendingString:@"   （本机无能耗数据，该列不可用）"];
    }
    return head;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"cwproc";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
        cell.detailTextLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }

    NSArray<CWProcInfo *> *procs = self.sorted;
    if (indexPath.row >= (NSInteger)procs.count) return cell;

    CWProcInfo *p = procs[indexPath.row];

    // 第一行显示当前排序依据 + 进程名，方便截图和复制
    NSString *primary;
    switch (self.sortMode) {
        case CWSortByMemory:
            primary = [NSString stringWithFormat:@"%@   %@",
                       p.memBytes ? CWFormattedBytes(p.memBytes) : @"—", p.name];
            break;
        case CWSortByWakeups:
            primary = [NSString stringWithFormat:@"%.0f/s   %@", p.wakeupsPerSec, p.name];
            break;
        case CWSortByThreads:
            primary = [NSString stringWithFormat:@"%ld 线程   %@", (long)p.threadCount, p.name];
            break;
        case CWSortByName:
            primary = p.name;
            break;
        case CWSortByEnergy:
            primary = p.hasEnergy ? [NSString stringWithFormat:@"%@   %@", CWFormatPower(p.energyNJPerSec), p.name]
                                  : [NSString stringWithFormat:@"能耗不可读   %@", p.name];
            break;
        default:
            primary = [NSString stringWithFormat:@"%.1f%%   %@", p.cpuPercent, p.name];
            break;
    }
    // 类别徽章：系统=灰 / App=绿 / 越狱=橙。tweak 本身是注入宿主的 dylib，不单独成进程。
    CWProcKind kind = CWProcKindForPath(p.execPath);
    UIColor *kindColor;
    if      (kind == CWProcKindApp)       kindColor = [UIColor systemGreenColor];
    else if (kind == CWProcKindJailbreak) kindColor = [UIColor systemOrangeColor];
    else                                  kindColor = [UIColor systemGrayColor];
    NSString *badge = [NSString stringWithFormat:@"[%@] ", CWProcKindName(kind)];
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:badge
        attributes:@{ NSForegroundColorAttributeName: kindColor,
                      NSFontAttributeName: [UIFont boldSystemFontOfSize:13] }];
    [attr appendAttributedString:[[NSAttributedString alloc] initWithString:primary
        attributes:@{ NSForegroundColorAttributeName: [UIColor labelColor],
                      NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium] }]];
    cell.textLabel.attributedText = attr;

    cell.detailTextLabel.text = [NSString stringWithFormat:
        @"PID %ld   CPU %.1f%%   唤醒 %.0f/s   内存 %@   线程 %ld",
        (long)p.pid, p.cpuPercent, p.wakeupsPerSec,
        p.memBytes ? CWFormattedBytes(p.memBytes) : @"—", (long)p.threadCount];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)self.sorted.count) return;
    CWProcInfo *p = self.sorted[indexPath.row];
    NSString *kindTag = [NSString stringWithFormat:@"[%@] %@",
                         CWProcKindName(CWProcKindForPath(p.execPath)), p.name];
    NSString *text = [NSString stringWithFormat:
        @"%@\nPID %ld   CPU %.1f%%   唤醒 %.0f/s   内存 %@   线程 %ld",
        kindTag, (long)p.pid, p.cpuPercent, p.wakeupsPerSec,
        p.memBytes ? CWFormattedBytes(p.memBytes) : @"—", (long)p.threadCount];
    [UIPasteboard generalPasteboard].string = text;
    // 把状态栏临时改成复制提示，0.8 秒后恢复
    NSString *saved = self.statusLabel.text;
    self.statusLabel.text = [NSString stringWithFormat:@"已复制：%@", p.name];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if ([self.statusLabel.text isEqualToString:[NSString stringWithFormat:@"已复制：%@", p.name]]) {
            self.statusLabel.text = saved;
        }
    });
}

@end

#pragma mark - 根面板

// ⚠️ 这个控制器**必须**从 bundle 内的 Root.plist 加载 specifiers，不能纯代码构造后 set。
//
// 实机踩过的坑（frida 实测确认，症状是面板整片空白）：
//   旧写法 = 代码构造数组 -> self.specifiers = specs -> [self reloadSpecifiers]。
//   但 -reloadSpecifiers 会重新走 loadSpecifiersFromPlistName:，而当时 bundle 里没有
//   Root.plist，于是加载到空数组，把刚设好的 specifiers 整个盖掉。
//   实测：set 之后读出 2 条 → reload 之后读出 0 条。所以：
//     ① bundle 必须带 Root.plist（兜底）；
//     ② 要刷新表格用 reloadData，绝对不要用 reloadSpecifiers。
@implementation CPUWatcherPrefsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"CPU 监视器";
    @try {
        self.specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    } @catch (NSException *e) {
        NSLog(@"[CPUWatcher] 加载 Root.plist 失败: %@", e.reason);
    }
    [self cwRefreshDynamicRows];
    [self cwBindButtonActions];
    // 注册 HUD 扫描完成通知观察者（冲突扫描 + v0.1.8 tweak 归因）。
    cwRegisterScanDoneOnce();
    cwRegisterTweakProfileDoneOnce();
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    gVisiblePrefs = self;
    // 推到下一 runloop 再刷，避开 PSListController 在同一帧改表被刷空的时序问题。
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!self.specifiers || self.specifiers.count == 0) {
                self.specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
            }
            [self cwRefreshDynamicRows];
            [self cwBindButtonActions];
            if ([self.view respondsToSelector:@selector(reloadData)]) {
                [(UITableView *)self.view reloadData];
            }
        } @catch (NSException *e) {
            NSLog(@"[CPUWatcher] 刷新面板失败: %@", e.reason);
        }
    });
}

/// 回填两行的运行时值：版本、采集权限档位。Root.plist 里用自定义键 cwDynamic 标记。
- (void)cwRefreshDynamicRows {
    NSString *version = [[NSBundle bundleForClass:[self class]]
                         objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"—";
    CWTier tier = CWDetectTier();

    for (PSSpecifier *s in self.specifiers) {
        NSString *dyn = [s propertyForKey:@"cwDynamic"];
        if (![dyn isKindOfClass:[NSString class]]) continue;
        if ([dyn isEqualToString:@"version"]) {
            [s setProperty:version forKey:@"value"];
        } else if ([dyn isEqualToString:@"tierName"]) {
            [s setProperty:CWTierName(tier) forKey:@"value"];
        } else if ([dyn isEqualToString:@"tierDetail"]) {
            [s setProperty:CWTierDetail(tier) forKey:@"value"];
        }
    }
}

/// PSButtonCell 的坑（SuperScreenshot v6.02 踩过，症状是按钮点了完全没反应）：
/// plist 里 action 若写成不带冒号的字符串，NSSelectorFromString 得到的是 0 参选择器，
/// 而实际方法是带冒号吃一个参数的 —— 两者不是同一个 selector，按钮静默失效。
/// 这里统一兜底：本类没有无冒号版本时自动补冒号。
/// 另注：setAction: 在 SDK 头文件里不存在，只能用 setButtonAction:。
- (void)cwBindButtonActions {
    for (PSSpecifier *s in self.specifiers) {
        NSString *act = [s propertyForKey:@"action"];
        if (![act isKindOfClass:[NSString class]] || act.length == 0) continue;
        SEL sel = NSSelectorFromString(act);
        if (![self respondsToSelector:sel]) {
            NSString *alt = [act stringByAppendingString:@":"];
            if ([self respondsToSelector:NSSelectorFromString(alt)]) sel = NSSelectorFromString(alt);
        }
        if ([self respondsToSelector:sel]) [s setButtonAction:sel];
    }
}

#pragma mark 动作

- (void)openMonitor:(id)sender {
    CWMonitorViewController *vc = [CWMonitorViewController new];
    [self.navigationController pushViewController:vc animated:YES];
}

/// 采集权限/能力详情这两行原本是 PSTitleValueCell，设计上就是只读展示，点不动。
/// 但用户会去点它 —— 所以补一个真正可点的入口，把档位含义一次说清。
- (void)explainTier:(id)sender {
    CWTier t = CWDetectTier();
    NSMutableString *msg = [NSMutableString string];

    [msg appendFormat:@"当前档位：%@\n\n", CWTierName(t)];
    [msg appendFormat:@"%@\n\n", CWTierDetail(t)];

    [msg appendString:@"三个档位的区别：\n"];
    [msg appendString:@"· 完整模式 —— 每进程 CPU / 内存 / 线程 / 能耗 / 唤醒全部可读\n"];
    [msg appendString:@"· 基础模式 —— 只能列出进程，读不到每进程 CPU 与能耗\n"];
    [msg appendString:@"· 受限模式 —— 只有全局 CPU 与内存\n\n"];

    [msg appendString:@"注：本机（iOS 16.6.1 / Relaxin）实测非 root 即为完整模式 —— "
                      @"proc_pidinfo 与 proc_pid_rusage 都调得通，不需要特权助手。\n"
                      @"若这里显示降级，点「采集权限自检」可看到逐项实测结果。"];

    [self cwShowAlert:@"采集权限说明" message:msg];
}

- (void)runSelfCheck:(id)sender {
    CWEnsureDataDir();

    NSMutableString *msg = [NSMutableString string];
    CWTier tier = CWDetectTier();
    [msg appendFormat:@"采集权限档位：%@\n", CWTierName(tier)];
    [msg appendFormat:@"（euid=%d —— 注意：本机非 root 也能读全量数据，档位不看 uid）\n", geteuid()];

    NSString *helper = CWHelperLaunchPath();
    [msg appendFormat:@"特权助手：%@\n", helper ? helper : @"未找到"];
    [msg appendFormat:@"数据目录：%@\n", CW_DATA_DIR];

    CWSampler *s = [CWSampler new];
    [s prime];
    usleep(300 * 1000);
    CWSnapshot *snap = [s sample];
    [msg appendFormat:@"实测全局 CPU：%.0f%%（%ld 核）\n", snap.totalCPUPercent, (long)snap.cpuCount];
    [msg appendFormat:@"实测可见进程数：%lu\n", (unsigned long)snap.processes.count];

    // 能耗是这一版新增的能力，直接在这里报有没有 —— 免得用户以为是面板坏了。
    NSUInteger withEnergy = 0;
    for (CWProcInfo *p in snap.processes) { if (p.hasEnergy) withEnergy++; }
    [msg appendFormat:@"能耗数据可读进程：%lu / %lu%@",
     (unsigned long)withEnergy, (unsigned long)snap.processes.count,
     withEnergy ? @"" : @"\n（该字段在本机不可用，将自动退回只用 CPU + 唤醒次数排序）"];

    [self cwShowAlert:@"自检结果" message:msg];
}

- (void)listInjectedPlugins:(id)sender {
    CWEnsureDataDir();

    NSString *out = CWInjectedListPath();
    [[NSFileManager defaultManager] removeItemAtPath:out error:NULL];

    // HUD 常驻在 SpringBoard 里，让它把 _dyld_image_name 清单写出来。
    // 这是拿到真实注入清单的唯一零风险途径：不需要 task_for_pid、不读任何其它进程的内存。
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CW_NOTIFY_DUMP_INJECTED, NULL, NULL, true);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self cwPresentInjectedList];
    });
}

- (void)cwPresentInjectedList {
    NSDictionary *d = CWReadJSON(CWInjectedListPath());
    NSArray *plugins = [d[@"plugins"] isKindOfClass:[NSArray class]] ? d[@"plugins"] : nil;

    if (!plugins) {
        [self cwShowAlert:@"读取失败"
                  message:@"没拿到 SpringBoard 的插件清单。\n\n可能原因：\n"
                          @"① CPUWatcherHUD.dylib 还没被注入 SpringBoard；\n"
                          @"② 装完 deb 后还没注销过 SpringBoard。\n\n"
                          @"提示：装完 deb 后请注销（Respring）一次再试。"];
        return;
    }

    NSMutableString *msg = [NSMutableString string];
    [msg appendFormat:@"SpringBoard 实际加载了 %lu 个插件 dylib：\n\n", (unsigned long)plugins.count];
    for (NSDictionary *p in plugins) {
        if ([p isKindOfClass:[NSDictionary class]]) {
            [msg appendFormat:@"• %@\n", p[@"name"] ?: @"?"];
        }
    }
    if (plugins.count == 0) {
        [msg appendString:@"（一个都没有，说明注入通道没工作，或本机只装了本插件。）"];
    }

    [self cwShowAlert:[NSString stringWithFormat:@"已注入插件（%lu）", (unsigned long)plugins.count]
              message:msg];
}

- (void)cwShowAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                               message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    // 等一拍再 present：面板可能正处在 push/pop 过程中，直接 present 会失败。
    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentViewController:ac animated:YES completion:nil];
    });
}

@end

#pragma mark - 冲突扫描结果页

@implementation CWConflictViewController
- (instancetype)initWithResult:(NSDictionary *)r {
    if ((self = [super init])) {
        _result = r;
        _tweaks = [r[@"tweaks"] isKindOfClass:[NSArray class]] ? r[@"tweaks"] : @[];
        _conflicts = [r[@"conflicts"] isKindOfClass:[NSArray class]] ? r[@"conflicts"] : @[];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"插件冲突扫描";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.dataSource = self;
    _table.delegate = self;
    [self.view addSubview:_table];

    UIBarButtonItem *export = [[UIBarButtonItem alloc] initWithTitle:@"导出"
                                                              style:UIBarButtonItemStylePlain
                                                             target:self
                                                             action:@selector(onExport:)];
    self.navigationItem.rightBarButtonItem = export;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == 0) {
        return [NSString stringWithFormat:@"概览：扫描 %.1fs / 类 %@ / 插件 %@ / 冲突 %@",
                [self.result[@"scanSeconds"] doubleValue],
                self.result[@"totalClasses"] ?: @0,
                self.result[@"tweakCount"] ?: @0,
                self.result[@"conflictCount"] ?: @0];
    }
    if (s == 1) return @"冲突项（同一方法被多个插件替换）";
    return @"各插件替换的方法数（点击查看明细）";
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 1;
    if (s == 1) return self.conflicts.count ?: 1;
    return self.tweaks.count ?: 1;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"cwconf";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.textLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.numberOfLines = 0;
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (ip.section == 0) {
        cell.textLabel.text = @"说明";
        cell.detailTextLabel.text = @"冲突项（红字）才是真正「打架」的插件。点下方各插件可看它替换了哪些方法。";
        return cell;
    }
    if (ip.section == 1) {
        if (self.conflicts.count == 0) {
            cell.textLabel.text = @"未发现明显冲突";
            cell.textLabel.textColor = [UIColor labelColor];
            cell.detailTextLabel.text = @"";
            return cell;
        }
        NSDictionary *c = self.conflicts[ip.row];
        cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", c[@"class"] ?: @"?", c[@"sel"] ?: @"?"];
        cell.detailTextLabel.text = [(NSArray *)c[@"tweaks"] componentsJoinedByString:@"  ×  "];
        cell.textLabel.textColor = [UIColor systemRedColor];
        return cell;
    }
    if (self.tweaks.count == 0) {
        cell.textLabel.text = @"（未检测到插件替换方法）";
        cell.detailTextLabel.text = @"";
        return cell;
    }
    NSDictionary *t = self.tweaks[ip.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%@  替换 %@ 方法 / 冲突 %@",
                           t[@"name"] ?: @"?", t[@"hookCount"] ?: @0, t[@"conflictCount"] ?: @0];
    cell.detailTextLabel.text = @"";
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 2 && self.tweaks.count > 0) {
        NSDictionary *t = self.tweaks[ip.row];
        CWConflictDetailViewController *d = [[CWConflictDetailViewController alloc] initWithTweak:t];
        [self.navigationController pushViewController:d animated:YES];
    }
}
- (void)onExport:(id)sender {
    NSMutableString *txt = [NSMutableString string];
    [txt appendFormat:@"CPUWatcher 冲突扫描导出\n扫描耗时 %.1fs，类 %@，插件 %@，冲突 %@\n\n",
            [self.result[@"scanSeconds"] doubleValue],
            self.result[@"totalClasses"] ?: @0,
            self.result[@"tweakCount"] ?: @0,
            self.result[@"conflictCount"] ?: @0];
    [txt appendString:@"【冲突项】\n"];
    if (self.conflicts.count == 0) [txt appendString:@"（无）\n"];
    for (NSDictionary *c in self.conflicts) {
        [txt appendFormat:@"%@ %@  <=  %@\n", c[@"class"] ?: @"?", c[@"sel"] ?: @"?",
                          [(NSArray *)c[@"tweaks"] componentsJoinedByString:@" , "]];
    }
    [txt appendString:@"\n【各插件替换的方法】\n"];
    for (NSDictionary *t in self.tweaks) {
        [txt appendFormat:@"\n● %@ （替换 %@ 方法，冲突 %@）\n", t[@"name"] ?: @"?",
                          t[@"hookCount"] ?: @0, t[@"conflictCount"] ?: @0];
        for (NSDictionary *h in (NSArray *)t[@"hooks"]) {
            [txt appendFormat:@"    %@%@ %@\n", h[@"kind"] ?: @"", h[@"class"] ?: @"?", h[@"sel"] ?: @""];
        }
    }
    NSString *path = @"/var/mobile/Media/CPUWatcher/conflicts_export.txt";
    [txt writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSURL *url = [NSURL fileURLWithPath:path];
    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[ txt, url ]
                                                                     applicationActivities:nil];
    [self presentViewController:av animated:YES completion:nil];
}
@end

@implementation CWConflictDetailViewController
- (instancetype)initWithTweak:(NSDictionary *)t {
    if ((self = [super init])) {
        _tweak = t;
        _hooks = [t[@"hooks"] isKindOfClass:[NSArray class]] ? t[@"hooks"] : @[];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.tweak[@"name"] ?: @"插件";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.dataSource = self;
    _table.delegate = self;
    [self.view addSubview:_table];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.hooks.count ?: 1;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"cwhk";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.textLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    if (self.hooks.count == 0) { cell.textLabel.text = @"（无）"; cell.detailTextLabel.text = @""; return cell; }
    NSDictionary *h = self.hooks[ip.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%@%@", h[@"kind"] ?: @"", h[@"sel"] ?: @""];
    cell.detailTextLabel.text = h[@"class"] ?: @"";
    return cell;
}
@end

#pragma mark - P4 扫描完成回调（C 函数实现，引用前置声明的 gVisiblePrefs）

static void CWScanDoneCallback(CFNotificationCenterRef center, void *observer,
                               CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    if (!name) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gVisiblePrefs) [gVisiblePrefs cwScanDidFinish];
    });
}
static void cwRegisterScanDoneOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        CWScanDoneCallback, CW_NOTIFY_SCAN_DONE, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    });
}

#pragma mark - v0.1.8 插件归因完成回调 + 观察者注册

static void CWTweakProfileDoneCallback(CFNotificationCenterRef center, void *observer,
                                       CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    if (!name) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gVisiblePrefs) [gVisiblePrefs cwTweakProfileDidFinish];
    });
}
static void cwRegisterTweakProfileDoneOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        CWTweakProfileDoneCallback, CW_NOTIFY_TWEAK_PROFILE_DONE, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    });
}

#pragma mark - 诊断动作（修复 v0.1.4 起缺失实现、按钮失效的问题）

@implementation CPUWatcherPrefsController (Diagnostics)

// 插件冲突扫描：发通知让 SpringBoard 内 HUD 扫描，面板等 SCAN_DONE 再读结果。
- (void)runConflictScan:(id)sender {
    CWEnsureDataDir();
    NSString *out = CWConflictPath();
    [[NSFileManager defaultManager] removeItemAtPath:out error:NULL];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CW_NOTIFY_SCAN_CONFLICTS, NULL, NULL, true);
    [self cwShowAlert:@"冲突扫描已启动"
              message:@"正在 SpringBoard 内做 IMP 归属扫描（遍历类方法，耗时数秒）。\n"
                      @"完成后会自动弹出结果页；若长时间无反应，请先注销(Respring)一次再试。"];
}

// SCAN_DONE 回调：读取 conflicts.json 并弹结果页。
- (void)cwScanDidFinish {
    NSDictionary *d = CWReadJSON(CWConflictPath());
    if (!d) {
        [self cwShowAlert:@"读取失败"
                  message:@"没拿到冲突扫描结果。可能 CPUWatcherHUD.dylib 未注入 SpringBoard，"
                          @"或装完 deb 后还没注销过。请注销(Respring)后重试。"];
        return;
    }
    [self cwPresentConflictResult];
}

- (void)cwPresentConflictResult {
    NSDictionary *d = CWReadJSON(CWConflictPath());
    if (!d) return;
    CWConflictViewController *vc = [[CWConflictViewController alloc] initWithResult:d];
    [self.navigationController pushViewController:vc animated:YES];
}

// v0.1.8：越狱插件 CPU/内存归因：发通知让 SpringBoard 内 HUD 采样，等完成再读。
- (void)runTweakProfile:(id)sender {
    CWEnsureDataDir();
    NSString *out = CWTweakProfilePath();
    [[NSFileManager defaultManager] removeItemAtPath:out error:NULL];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CW_NOTIFY_TWEAK_PROFILE, NULL, NULL, true);
    [self cwShowAlert:@"插件归因已启动"
              message:@"正在 SpringBoard 内采样线程 CPU 并归属到各 tweak dylib（约 3 秒）。\n"
                      @"完成后自动弹出排行页。注：仅覆盖注入 SpringBoard 的 tweak。"];
}

- (void)cwTweakProfileDidFinish {
    NSDictionary *d = CWReadJSON(CWTweakProfilePath());
    if (!d) {
        [self cwShowAlert:@"读取失败"
                  message:@"没拿到插件归因结果。可能 CPUWatcherHUD.dylib 未注入 SpringBoard，"
                          @"或装完 deb 后还没注销过。请注销(Respring)后重试。"];
        return;
    }
    [self cwPresentTweakProfileResult];
}

- (void)cwPresentTweakProfileResult {
    NSDictionary *d = CWReadJSON(CWTweakProfilePath());
    if (!d) return;
    CWTweakProfileViewController *vc = [[CWTweakProfileViewController alloc] initWithResult:d];
    [self.navigationController pushViewController:vc animated:YES];
}

@end

#pragma mark - v0.1.8 插件归因结果页

@implementation CWTweakProfileViewController
- (instancetype)initWithResult:(NSDictionary *)r {
    if ((self = [super init])) {
        _result = r;
        _tweaks = [r[@"tweaks"] isKindOfClass:[NSArray class]] ? r[@"tweaks"] : @[];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"插件 CPU/内存归因";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.dataSource = self;
    _table.delegate = self;
    [self.view addSubview:_table];
    NSNumber *dur = _result[@"durationSec"];
    NSString *note = _result[@"note"] ?: @"";
    self.navigationItem.prompt = [NSString stringWithFormat:@"采样 %.1fs · %@",
                                  [dur doubleValue], note];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.tweaks.count ?: 1;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"cwtp";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    if (self.tweaks.count == 0) {
        cell.textLabel.text = @"（采样窗口内无 tweak 占用 CPU，或本机只装了本插件）";
        cell.detailTextLabel.text = @"";
        return cell;
    }
    NSDictionary *t = self.tweaks[ip.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%@   %.1f%%",
                           t[@"name"] ?: @"?", [t[@"cpuPercent"] doubleValue]];
    unsigned long long mem = [t[@"memMappedBytes"] unsignedLongLongValue];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"CPU 窗口消耗 %@ · 映射内存 ≈ %@",
                                 CWFormattedBytes([t[@"cpuDeltaUs"] unsignedLongLongValue]),
                                 CWFormattedBytes(mem)];
    return cell;
}
@end
