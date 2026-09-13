//
//  CWSampler.h — 全局 CPU / 内存 / 进程列表采样
//  CPUWatcher
//

#import <Foundation/Foundation.h>
#import "CWCommon.h"

/// 一条进程采样记录
@interface CWProcInfo : NSObject
@property (nonatomic, assign) NSInteger pid;
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, assign) double    cpuPercent;   // 相对单核，可超过 100
@property (nonatomic, assign) unsigned long long memBytes;
@property (nonatomic, assign) NSInteger threadCount;

// ---- 能耗 / 唤醒（来自 proc_pid_rusage，只有 root 拿得到） ----
// 内核给的是**进程启动至今的累计值**，所以这里同时提供累计量与速率。
// 速率 = 本次累计 - 上次累计 / 时间差，这才是能用来排序的"当前耗电"。
// 「CPU 不高但待机耗电翻倍」的插件，看 cpuPercent 会漏掉，看 energyNJPerSec 才抓得到。
@property (nonatomic, assign) unsigned long long energyNJ;        // 累计耗电，纳焦
@property (nonatomic, assign) unsigned long long wakeups;         // 累计中断唤醒次数
@property (nonatomic, assign) double energyNJPerSec;              // 纳焦/秒
@property (nonatomic, assign) double wakeupsPerSec;               // 次/秒
@property (nonatomic, assign) BOOL   hasEnergy;                   // 该进程是否成功取到能耗数据

- (NSDictionary *)dictionaryRepresentation;
+ (instancetype)fromDictionary:(NSDictionary *)d;
@end

/// 一次完整采样结果
@interface CWSnapshot : NSObject
@property (nonatomic, assign) NSTimeInterval timestamp;
@property (nonatomic, assign) double    totalCPUPercent;  // 0..100(ncpu)
@property (nonatomic, assign) NSInteger cpuCount;
@property (nonatomic, assign) double    memUsedRatio;     // 0..1
@property (nonatomic, assign) unsigned long long memUsedBytes;
@property (nonatomic, assign) unsigned long long memTotalBytes;
@property (nonatomic, assign) NSInteger tier;
@property (nonatomic, copy)   NSArray<CWProcInfo *> *processes;

- (NSDictionary *)dictionaryRepresentation;
+ (instancetype)snapshotFromDictionary:(NSDictionary *)d;
@end

@interface CWSampler : NSObject
/// 首次取样没有前值，只能建立基线。调用一次后再进入循环。
- (void)prime;
/// 采样一次。两次调用之间的时间差越接近预期，CPU% 越准。
- (CWSnapshot *)sample;
@end
