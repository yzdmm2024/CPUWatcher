//
//  CWConflictScan — 在 SpringBoard 内做 IMP 归属扫描（P4 冲突检测）
//
//  思路（无 root、只读、不 hook）：
//    遍历进程内所有 Objective-C 类（含元类的类方法），对每个方法取 IMP，
//    用 dladdr 查 IMP 实际落点的 dylib；再和 class_getImageName 拿到的
//    「类定义所在 dylib」比对：
//      - IMP 落在某个 tweak dylib，且该类并不是定义在该 tweak 里
//        => 这个 tweak 把该方法替换成了自己的实现（即一次 hook）。
//      - 同一个 (类, 方法) 被 ≥2 个 tweak 命中 => 冲突（多个插件抢同一方法）。
//
//  为什么必须在 SpringBoard 内做：插件都注入在 SpringBoard，设置进程读不到
//  别人的方法实现归属；而本进程就是 SpringBoard，直接问 runtime + dyld 即可，
//  零风险、零权限，结果还是真值（不是靠解析 Filter plist 猜出来的）。
//
//  安全：纯只读，不改任何内存、不调用私有写接口、不起定时器、不 hook。
//  性能：遍历上万类、几十万方法，耗时数秒 —— 调用方务必在后台线程调用。
//

#import "CWConflictScan.h"
#import "CWCommon.h"

#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>

// 判定一个镜像路径是不是「越狱注入的 tweak dylib」（而非系统框架 / 共享缓存）。
static BOOL CWIsTweakImage(NSString *path) {
    if (!path.length) return NO;
    if ([path containsString:@"TweakInject"])      return YES;
    if ([path containsString:@"MobileSubstrate"])  return YES;
    if ([path containsString:@"DynamicLibraries"]) return YES;
    if ([path containsString:@".jbroot"])          return YES;
    // rootless jbroot 注入目录：/var/jb/usr/lib、/var/jb/Library 等
    if ([path hasPrefix:@"/var/jb/"])              return YES;
    return NO;
}

void CWRunConflictScan(void) {
    @autoreleasepool {
        NSDate *start = [NSDate date];

        // ① 收集 tweak 镜像集合（真实加载的 dylib）
        NSMutableSet<NSString *> *tweakImgs = [NSMutableSet set];
        uint32_t imgCount = _dyld_image_count();
        for (uint32_t i = 0; i < imgCount; i++) {
            const char *nm = _dyld_get_image_name(i);
            if (!nm) continue;
            NSString *p = [NSString stringWithUTF8String:nm];
            if (CWIsTweakImage(p)) [tweakImgs addObject:p];
        }

        // ② 取所有类
        int classCount = objc_getClassList(NULL, 0);
        if (classCount <= 0) {
            CWEnsureDataDir();
            CWWriteJSONAtomically(@{ @"ts":@([NSDate timeIntervalSinceReferenceDate]),
                                    @"pid":@(getpid()),
                                    @"scanSeconds":@(-[start timeIntervalSinceNow]),
                                    @"totalClasses":@0, @"tweakCount":@0,
                                    @"conflictCount":@0, @"tweaks":@[], @"conflicts":@[],
                                    @"note":@"objc_getClassList 返回 0" },
                                 CWConflictPath());
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CW_NOTIFY_SCAN_DONE, NULL, NULL, true);
            return;
        }

        Class *classes = (Class *)malloc(sizeof(Class) * (size_t)classCount);
        objc_getClassList(classes, classCount);

        // tweakName -> @{ hookCount, hooks:[{class,sel,kind}] }
        NSMutableDictionary<NSString *, NSMutableDictionary *> *tweakMap = [NSMutableDictionary dictionary];
        // "class sel" -> NSMutableSet<tweakName>
        NSMutableDictionary<NSString *, NSMutableSet *> *conflictMap = [NSMutableDictionary dictionary];

        for (int i = 0; i < classCount; i++) {
            Class cls = classes[i];
            if (!cls) continue;
            const char *clsNameC = class_getName(cls);
            if (!clsNameC) continue;
            NSString *clsName = @(clsNameC);
            const char *defImgC = class_getImageName(cls);
            NSString *defImg = defImgC ? @(defImgC) : nil;

            Class meta = objc_getMetaClass(clsNameC);

            // 处理一批方法（实例方法 + 类方法）。用 block 避免重复代码。
            void (^scanList)(Class, NSString *) = ^(Class target, NSString *kind){
                if (!target) return;
                unsigned int mcount = 0;
                Method *methods = class_copyMethodList(target, &mcount);
                if (!methods) return;
                for (unsigned int j = 0; j < mcount; j++) {
                    Method m = methods[j];
                    IMP imp = method_getImplementation(m);
                    if (!imp) continue;
                    Dl_info info;
                    if (!dladdr((void *)imp, &info) || !info.dli_fname) continue;
                    NSString *impImg = @(info.dli_fname);
                    if (![tweakImgs containsObject:impImg]) continue; // 正常方法（系统/共享缓存）
                    // 落在 tweak 镜像：若是 tweak 自己定义的类则跳过（那是它自己的方法，不算 hook）
                    if (defImg && [defImg isEqualToString:impImg]) continue;

                    NSString *tweakName = impImg.lastPathComponent;
                    NSString *selName = @(sel_getName(method_getName(m)));
                    NSString *key = [NSString stringWithFormat:@"%@ %@%@", clsName, kind, selName];

                    NSMutableDictionary *rec = tweakMap[tweakName];
                    if (!rec) {
                        rec = [NSMutableDictionary dictionary];
                        rec[@"hookCount"] = @(0);
                        rec[@"hooks"] = [NSMutableArray array];
                        tweakMap[tweakName] = rec;
                    }
                    NSInteger hc = [rec[@"hookCount"] integerValue] + 1;
                    rec[@"hookCount"] = @(hc);
                    [rec[@"hooks"] addObject:@{ @"class": clsName, @"sel": selName, @"kind": kind }];

                    NSMutableSet *owners = conflictMap[key];
                    if (!owners) { owners = [NSMutableSet set]; conflictMap[key] = owners; }
                    [owners addObject:tweakName];
                }
                free(methods);
            };

            scanList(cls, @"-");
            scanList(meta, @"+");
        }

        free(classes);

        // ③ 汇总
        NSMutableArray *tweaksArr = [NSMutableArray array];
        for (NSString *name in tweakMap) {
            NSMutableDictionary *rec = tweakMap[name];
            NSInteger hookCount = [rec[@"hookCount"] integerValue];
            NSInteger conflictCount = 0;
            for (NSString *key in conflictMap) {
                NSMutableSet *owners = conflictMap[key];
                if (owners.count >= 2 && [owners containsObject:name]) conflictCount++;
            }
            NSMutableDictionary *out = [NSMutableDictionary dictionary];
            out[@"name"] = name;
            out[@"hookCount"] = @(hookCount);
            out[@"conflictCount"] = @(conflictCount);
            out[@"hooks"] = rec[@"hooks"];
            [tweaksArr addObject:out];
        }
        // 按 hookCount 降序（替换越多的插件越值得先看）
        [tweaksArr sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"hookCount" ascending:NO]]];

        NSMutableArray *conflictsArr = [NSMutableArray array];
        for (NSString *key in conflictMap) {
            NSMutableSet *owners = conflictMap[key];
            if (owners.count >= 2) {
                // key 形如 "Class -sel" 或 "Class +sel"
                NSArray *parts = [key componentsSeparatedByString:@" "];
                NSString *cls = parts.firstObject ?: @"?";
                NSString *selk = parts.count > 1 ? parts[1] : @"?";
                [conflictsArr addObject:@{ @"class": cls,
                                          @"sel": selk,
                                          @"tweaks": [owners allObjects] }];
            }
        }

        NSDictionary *result = @{
            @"ts":            @([NSDate timeIntervalSinceReferenceDate]),
            @"pid":           @(getpid()),
            @"scanSeconds":   @(-[start timeIntervalSinceNow]),
            @"totalClasses":  @(classCount),
            @"tweakCount":    @(tweaksArr.count),
            @"conflictCount": @(conflictsArr.count),
            @"tweaks":        tweaksArr,
            @"conflicts":     conflictsArr,
        };

        CWEnsureDataDir();
        BOOL ok = CWWriteJSONAtomically(result, CWConflictPath());

        // 写成功/失败都不静默：广播完成通知，面板据此读取。
        // 即便写失败也广播，让面板能给出「写不进」提示而非干等。
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CW_NOTIFY_SCAN_DONE, NULL, NULL, true);
        (void)ok;
    }
}
