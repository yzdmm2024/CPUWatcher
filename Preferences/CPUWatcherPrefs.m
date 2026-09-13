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

static id CWPrefGet(NSString *key) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite];
    return [d objectForKey:key];
}

static void CWPrefSet(NSString *key, id value) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite];
    [d setObject:value forKey:key];
    [d synchronize];

    // 让设置进程之外也能感知（SpringBoard 侧读同一份 plist）
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.axs.cpuwatcher.prefs.changed"),
                                         NULL, NULL, true);
}

static void CWHUDSend(BOOL on) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         on ? CFSTR("com.axs.cpuwatcher.hud.on")
                                            : CFSTR("com.axs.cpuwatcher.hud.off"),
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

@interface CWMonitorViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) CWHelperSession *session;
@property (nonatomic, strong) CWSampler *fallbackSampler;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) CWSnapshot *snapshot;
@property (nonatomic, assign) BOOL usingHelper;
@property (nonatomic, copy)   NSString *statusText;
@end

@implementation CWMonitorViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"实时监控";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, self.view.bounds.size.width - 32, 36)];
    _statusLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    _statusLabel.numberOfLines = 2;
    _statusLabel.textColor = [UIColor secondaryLabelColor];
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _statusText = @"准备中…";

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = 52.0;
    [self.view addSubview:_table];

    _session = [CWHelperSession new];
    _fallbackSampler = [CWSampler new];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat top = self.view.safeAreaInsets.top;
    _statusLabel.frame = CGRectMake(16, top + 6, self.view.bounds.size.width - 32, 40);
    _table.frame = CGRectMake(0, top + 50, self.view.bounds.size.width,
                              self.view.bounds.size.height - top - 50);
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
    self.usingHelper = [self.session startWithIntervalMs:intervalMs duration:CW_HELPER_HARD_LIMIT_SEC];

    if (self.usingHelper) {
        self.statusText = [NSString stringWithFormat:@"特权助手已启动（PID %d，最长 %d 秒后自动停止）",
                           self.session.pid, CW_HELPER_HARD_LIMIT_SEC];
    } else {
        [self.fallbackSampler prime];
        CWTier t = CWDetectTier();
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
        case CWTierFull:       return @"可读每进程 CPU / 内存";
        case CWTierProcBasic:  return @"仅进程列表 + 内核估算占比";
        case CWTierGlobalOnly: return @"仅全局 CPU 与内存";
    }
    return @"";
}

- (void)tick {
    if (self.usingHelper) {
        NSDictionary *d = CWReadJSON(CWSnapshotPath());
        if (d) {
            self.snapshot = [CWSnapshot snapshotFromDictionary:d];
        } else {
            self.statusText = @"特权助手已启动，等待首个采样…";
        }
    } else {
        self.snapshot = [self.fallbackSampler sample];
    }
    self.statusLabel.text = self.statusText;
    [self.table reloadData];
}

#pragma mark 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSUInteger n = self.snapshot.processes.count;
    return n > 25 ? 25 : n;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (!self.snapshot) return @"进程（按 CPU 排序）";
    return [NSString stringWithFormat:@"进程（按 CPU 排序）  全局 %.0f%%  内存 %@ / %@",
            self.snapshot.totalCPUPercent,
            CWFormattedBytes(self.snapshot.memUsedBytes),
            CWFormattedBytes(self.snapshot.memTotalBytes)];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"cwproc";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
        cell.detailTextLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
    }

    NSArray<CWProcInfo *> *procs = self.snapshot.processes;
    if (indexPath.row >= (NSInteger)procs.count) return cell;

    CWProcInfo *p = procs[indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%.1f%%   %@", p.cpuPercent, p.name];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"PID %ld   内存 %@   线程 %ld",
                                 (long)p.pid,
                                 p.memBytes ? CWFormattedBytes(p.memBytes) : @"—",
                                 (long)p.threadCount];
    return cell;
}

@end

#pragma mark - 根面板

@interface CPUWatcherPrefsController : PSListController
@end

@implementation CPUWatcherPrefsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"CPU 监视器";
    [self rebuildSpecifiers];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // iOS 14 的 PSListController 在 viewWillAppear 同帧重建 specifiers 会把表格刷空，
    // 推到下一 runloop 并加 try/catch 兜底。
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { [self rebuildSpecifiers]; }
        @catch (NSException *e) { NSLog(@"[CPUWatcher] 重建面板失败: %@", e.reason); }
    });
}

- (void)rebuildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];

    PSSpecifier *g1 = [PSSpecifier groupSpecifierWithName:@"状态"];
    [g1 setProperty:@"默认静默：不点开监控页就不会有任何采样进程，不耗电。"
             forKey:@"footerText"];
    [specs addObject:g1];

    [specs addObject:[self rowWithLabel:@"版本" get:@selector(getVersion:)]];

    CWTier tier = CWDetectTier();
    PSSpecifier *tierRow = [self rowWithLabel:@"采集权限" get:@selector(getTierValue:)];
    [tierRow setProperty:CWTierName(tier) forKey:@"value"];
    [specs addObject:tierRow];

    PSSpecifier *g2 = [PSSpecifier groupSpecifierWithName:@"诊断"];
    [g2 setProperty:CWTierDetail(tier) forKey:@"footerText"];
    [specs addObject:g2];

    [specs addObject:[self buttonWithName:@"实时监控（打开后开始采集）"
                                   action:@selector(openMonitor:)]];

    [specs addObject:[self buttonWithName:@"采集权限自检"
                                   action:@selector(runSelfCheck:)]];

    PSSpecifier *g3 = [PSSpecifier groupSpecifierWithName:@"悬浮窗"];
    [g3 setProperty:@"开启后，只有在「实时监控」页处于前台时才显示悬浮窗；返回上级页立即消失并停止刷新。"
             forKey:@"footerText"];
    [specs addObject:g3];

    PSSpecifier *hudSwitch = [PSSpecifier preferenceSpecifierNamed:@"监控页显示悬浮窗"
                                                            target:self
                                                               set:@selector(setHUD:specifier:)
                                                               get:@selector(getHUD:)
                                                            detail:nil
                                                              cell:PSSwitchCell
                                                              edit:nil];
    [specs addObject:hudSwitch];

    PSSpecifier *g4 = [PSSpecifier groupSpecifierWithName:@"安全设计"];
    [g4 setProperty:@"① 不注册任何 LaunchDaemon，开机零执行；② 悬浮窗不 hook 任何系统方法，"
                     @"只监听通知；③ 采集进程有 60 秒硬性存活上限与孤儿看门狗；"
                     @"④ 数据写在 /var/mobile/Media/CPUWatcher，不污染越狱目录。"
             forKey:@"footerText"];
    [specs addObject:g4];

    self.specifiers = specs;
    [self reloadSpecifiers];
}

- (PSSpecifier *)rowWithLabel:(NSString *)label get:(SEL)getter {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:label
                                                    target:self
                                                       set:nil
                                                       get:getter
                                                    detail:nil
                                                      cell:PSTitleValueCell
                                                      edit:nil];
    return s;
}

- (id)getVersion:(PSSpecifier *)spec {
    NSString *v = [[NSBundle bundleForClass:[self class]]
                   objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return v ?: @"0.1.0";
}

- (id)getTierValue:(PSSpecifier *)spec {
    return CWTierName(CWDetectTier());
}

// PSButtonCell 的坑（SuperScreenshot v6.02 踩过）：
// 选择器必须带冒号、方法必须吃一个参数，否则 PSButtonCell 找不到实现，按钮点了完全没反应。
// setAction: 在 SDK 头文件里不存在，只能用 setButtonAction:。
- (PSSpecifier *)buttonWithName:(NSString *)name action:(SEL)action {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name
                                                    target:self
                                                       set:nil
                                                       get:nil
                                                    detail:nil
                                                      cell:PSButtonCell
                                                      edit:nil];
    [s setButtonAction:action];
    return s;
}

/// 点击回调的 sender 在不同 iOS 版本上可能是 PSSpecifier，也可能是承载它的 cell，统一兼容。
static PSSpecifier *CWSenderSpecifier(id sender) {
    if ([sender isKindOfClass:[PSSpecifier class]]) return sender;
    if ([sender respondsToSelector:@selector(specifier)]) {
        id s = [sender specifier];
        if ([s isKindOfClass:[PSSpecifier class]]) return s;
    }
    return nil;
}

#pragma mark 动作

- (void)openMonitor:(id)sender {
    CWMonitorViewController *vc = [CWMonitorViewController new];
    [self.navigationController pushViewController:vc animated:YES];
}

- (id)getHUD:(PSSpecifier *)spec {
    return @([CWPrefGet(kPrefHUDWithPage) boolValue]);
}

- (void)setHUD:(id)value specifier:(PSSpecifier *)spec {
    CWPrefSet(kPrefHUDWithPage, @([value boolValue]));
}

- (void)runSelfCheck:(id)sender {
    CWEnsureDataDir();

    NSMutableString *msg = [NSMutableString string];
    [msg appendFormat:@"采集权限档位：%@\n", CWTierName(CWDetectTier())];
    [msg appendFormat:@"当前进程 euid：%d\n", geteuid()];

    NSString *helper = CWHelperLaunchPath();
    [msg appendFormat:@"特权助手：%@\n", helper ? helper : @"未找到"];
    [msg appendFormat:@"数据目录：%@\n", CW_DATA_DIR];

    CWSampler *s = [CWSampler new];
    [s prime];
    usleep(300 * 1000);
    CWSnapshot *snap = [s sample];
    [msg appendFormat:@"实测全局 CPU：%.0f%%（%ld 核）\n", snap.totalCPUPercent, (long)snap.cpuCount];
    [msg appendFormat:@"实测可见进程数：%lu", (unsigned long)snap.processes.count];

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"自检结果"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
