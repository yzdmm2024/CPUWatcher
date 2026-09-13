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

static NSString * const kPrefsSuite      = @"com.axs.cpuwatcher";
static NSString * const kPrefHUDWithPage = @"hudWithMonitorPage";
static NSString * const kPrefSortMode    = @"lastSortMode";

static id CWPrefGet(NSString *key) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite];
    return [d objectForKey:key];
}

static void CWPrefSet(NSString *key, id value) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite];
    [d setObject:value forKey:key];
    [d synchronize];
}

static void CWHUDSend(BOOL on) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         on ? CW_NOTIFY_HUD_ON : CW_NOTIFY_HUD_OFF,
                                         NULL, NULL, true);
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
    CWSortByCPU = 0,
    CWSortByEnergy,     // 纳焦/秒 —— 抓「CPU 不高但耗电」的插件
    CWSortByWakeups,    // 中断唤醒次数/秒 —— 抓「不休眠、反复唤醒」的插件
};

@interface CWMonitorViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) CWHelperSession *session;
@property (nonatomic, strong) CWSampler *fallbackSampler;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UISegmentedControl *sortControl;
@property (nonatomic, strong) CWSnapshot *snapshot;
@property (nonatomic, strong) NSArray<CWProcInfo *> *sorted;
@property (nonatomic, assign) CWSortMode sortMode;
@property (nonatomic, assign) BOOL usingHelper;
@property (nonatomic, assign) BOOL energyAvailable;
@property (nonatomic, assign) NSInteger helperMisses;
@property (nonatomic, copy)   NSString *statusText;
@end

@implementation CWMonitorViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"实时监控";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.sortMode = (CWSortMode)[CWPrefGet(kPrefSortMode) integerValue];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, self.view.bounds.size.width - 32, 36)];
    _statusLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    _statusLabel.numberOfLines = 2;
    _statusLabel.textColor = [UIColor secondaryLabelColor];
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _statusText = @"准备中…";

    _sortControl = [[UISegmentedControl alloc] initWithItems:@[ @"CPU", @"耗电", @"唤醒" ]];
    _sortControl.selectedSegmentIndex = (NSInteger)self.sortMode;
    [_sortControl addTarget:self action:@selector(onSortChanged:) forControlEvents:UIControlEventValueChanged];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = 58.0;
    [self.view addSubview:_statusLabel];
    [self.view addSubview:_sortControl];
    [self.view addSubview:_table];

    _session = [CWHelperSession new];
    _fallbackSampler = [CWSampler new];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat top = self.view.safeAreaInsets.top;
    _statusLabel.frame = CGRectMake(16, top + 6, w - 32, 40);
    _sortControl.frame = CGRectMake(16, top + 50, w - 32, 32);
    _table.frame = CGRectMake(0, top + 88, w, self.view.bounds.size.height - top - 88);
}

- (void)onSortChanged:(UISegmentedControl *)sc {
    self.sortMode = (CWSortMode)sc.selectedSegmentIndex;
    CWPrefSet(kPrefSortMode, @(self.sortMode));
    [self resort];
    [self.table reloadData];
}

#pragma mark 生命周期的核心：进来才开，出去就关

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self startMonitoring];
}

- (void)viewWillDisappear:(BOOL)animated {
    // 必须在主线程同步把它杀掉，不能丢给后台队列 —— 用户返回了就必须马上停。
    [self stopMonitoring];
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

    if (self.usingHelper) {
        self.statusText = [NSString stringWithFormat:@"采样助手已启动（PID %d，最长 %d 秒后自动停止）",
                           self.session.pid, CW_HELPER_HARD_LIMIT_SEC];
    } else {
        [self.fallbackSampler prime];
        CWTier t = CWDetectTier();
        // 降级不装死：明确说清拿不到什么，而不是给个空表让人以为没进程。
        self.statusText = [NSString stringWithFormat:@"%@：%@\n%@",
                           CWTierName(t), CWFormatTierShort(t), self.session.failReason ?: @""];
    }

    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                  target:self
                                                selector:@selector(tick)
                                                userInfo:nil
                                                 repeats:YES];

    if ([CWPrefGet(kPrefHUDWithPage) boolValue]) CWHUDSend(YES);
    [self tick];
}

- (void)stopMonitoring {
    [self.timer invalidate];
    self.timer = nil;
    [self.session stop];

    if ([CWPrefGet(kPrefHUDWithPage) boolValue]) CWHUDSend(NO);

    // 面板离开后不留快照，避免悬浮窗或别的工具读到陈旧数据
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
    self.statusLabel.text = self.statusText;
    [self resort];
    [self.table reloadData];
}

#pragma mark 排序

- (void)resort {
    NSArray<CWProcInfo *> *procs = self.snapshot.processes ?: @[];
    self.energyAvailable = NO;
    for (CWProcInfo *p in procs) { if (p.hasEnergy) { self.energyAvailable = YES; break; } }

    NSArray<CWProcInfo *> *arr = [procs sortedArrayUsingComparator:^NSComparisonResult(CWProcInfo *a, CWProcInfo *b) {
        double av = 0, bv = 0;
        switch (self.sortMode) {
            case CWSortByEnergy:  av = a.energyNJPerSec; bv = b.energyNJPerSec; break;
            case CWSortByWakeups: av = a.wakeupsPerSec;  bv = b.wakeupsPerSec;  break;
            default:              av = a.cpuPercent;     bv = b.cpuPercent;     break;
        }
        if (av > bv) return NSOrderedAscending;
        if (av < bv) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    self.sorted = arr;
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
    if (self.sortMode != CWSortByCPU && !self.energyAvailable) {
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

    // 第一行永远显示当前排序依据，第二行显示其它维度，方便交叉判断
    NSString *primary;
    if (self.sortMode == CWSortByEnergy) {
        primary = p.hasEnergy ? [NSString stringWithFormat:@"%@   %@", CWFormatPower(p.energyNJPerSec), p.name]
                              : [NSString stringWithFormat:@"能耗不可读   %@", p.name];
    } else if (self.sortMode == CWSortByWakeups) {
        primary = [NSString stringWithFormat:@"%.0f 次/秒   %@", p.wakeupsPerSec, p.name];
    } else {
        primary = [NSString stringWithFormat:@"%.1f%%   %@", p.cpuPercent, p.name];
    }
    cell.textLabel.text = primary;

    cell.detailTextLabel.text = [NSString stringWithFormat:
        @"PID %ld   CPU %.1f%%   唤醒 %.0f/s   内存 %@   线程 %ld",
        (long)p.pid, p.cpuPercent, p.wakeupsPerSec,
        p.memBytes ? CWFormattedBytes(p.memBytes) : @"—", (long)p.threadCount];
    return cell;
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
@interface CPUWatcherPrefsController : PSListController
@end

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
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
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
                          @"① 悬浮窗组件（CPUWatcherHUD.dylib）还没被注入 SpringBoard；\n"
                          @"② 装完 deb 后还没注销过 SpringBoard。\n\n"
                          @"提示：本功能依赖 HUD 组件，装完 deb 后请注销（Respring）一次再试。"];
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
