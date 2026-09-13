# CPUWatcher（CPU 监视器）

越狱插件（rootless / Relaxin / iOS 16.6.1）。用来**找出是哪个插件在烧 CPU、哪两个插件在抢同一个方法**。

包名 `com.axs.cpuwatcher` ｜ 安装路径 `/var/jb` ｜ 初始版本 `0.1.0`

---

## 两条硬约束（设计上的最高优先级）

**A. 不许白苹果。** 不注册任何 LaunchDaemon / LaunchAgent，开机零执行。

**B. 按需激活，用完即停。** 默认静默。只有「实时监控」页在前台时才采样，返回上级页立即停止。不允许常驻后台监测。

---

## 组件

| 组件 | 位置 | 说明 |
|---|---|---|
| `CPUWatcherHUD.dylib` | `/var/jb/usr/lib/TweakInject/` | 悬浮窗。只注入 SpringBoard，**不 hook 任何系统方法**，`%ctor` 里只注册一个 Darwin 通知观察者 |
| `cpuwatchctl` | `/var/jb/usr/bin/`（setuid 4755） | 按需特权采样助手。**不是守护进程**，由设置面板 spawn，面板返回即被 SIGKILL |
| `CPUWatcherPrefs.bundle` | `/var/jb/Library/PreferenceBundles/` | 设置面板 |
| 数据目录 | `/var/mobile/Media/CPUWatcher/` | 采样结果。写在用户区，不污染越狱目录，Filza / 爱思可直接取走 |

## 按需激活模型

```
静默态（采样 0 次，耗电 0）
   │  用户点开「设置 → CPU 监视器 → 实时监控」
   ▼
采集中（面板 viewDidAppear 里 posix_spawn 拉起 cpuwatchctl）
   │  返回上级页 / 退出面板 / 3 秒心跳超时 / alarm(60) 硬上限
   ▼
立即 kill，回到静默态
```

三重停机保障：
1. 面板 `viewWillDisappear` 主线程同步 `SIGKILL`
2. helper 内孤儿看门狗 —— 父进程变成 launchd(1) 就退出
3. helper 自身 `alarm(60)` —— 到点无条件自杀

## 能力档位（运行时探测，如实显示，不假装全能）

| 档位 | 触发条件 | 能力 |
|---|---|---|
| 完整模式 | setuid root 生效 | 每进程 CPU / 内存 / 能耗 / 唤醒次数 + 采样剖析 |
| 基础模式 | 无 root，但 `sysctl(KERN_PROC_ALL)` 可读 | 进程列表 + 内核估算的 CPU 占比 |
| 受限模式 | 以上都不行 | 仅全局 CPU + 内存 |

> hook 冲突扫描是纯静态解析 dylib 文件，不需要任何特权，三档都可用。

## 构建

**deb 只能走 GitHub Actions（theos）**。本地 Windows 的 lld 18 生成的 dyld 绑定信息有缺陷，装机会报
`bad bind opcode 0x00`；而且 helper 必须带 entitlements（`ldid` 是 Mach-O，Windows 上跑不了）。

```bash
git add -A && git commit -m "v0.1.0: 初始版本"
git push origin main          # 失败就改用 push_via_gh_api.py（走 api.github.com，稳）
gh run list --repo yzdmm2024/CPUWatcher --limit 1
gh run download <RUN_ID> --repo yzdmm2024/CPUWatcher --dir E:\temp_ci
```

CI 里有 5 道护栏，任一不过直接失败：
1. 产物里不能出现 LaunchDaemon / LaunchAgent
2. postinst 不能有 `killall` / `respring`
3. `cpuwatchctl` 必须是 4755
4. 签名里必须真的有 `platform-application` + `task_for_pid-allow`
5. 三个二进制必须是 fat（arm64 + arm64e）

## 手工验证（SSH 到设备）

```bash
# 助手本身能不能跑
/var/jb/usr/bin/cpuwatchctl --version
/var/jb/usr/bin/cpuwatchctl --oneshot        # 打印一次采样 JSON

# 静默态确认：不该有任何 cpuwatchctl 进程
ps -ax | grep cpuwatchctl
```

## 版本规则

小版本 +0.1（`0.1.0` → `0.1.1`），大版本 +1.0。

## 待真机验证

1. iOS 16.6.1 是否认可第三方 setuid root 二进制 → 决定能否进「完整模式」
2. `RUSAGE_INFO_V4` 的 `ri_billed_energy` 是否有值 → 决定能耗排行
3. rootless 下 `task_for_pid` 是否放行 → 决定采样剖析
4. ElleKit 是否会把 `.dylib.disabled` 也加载 → 决定插件隔离模块的改名策略
5. 设置面板（沙盒进程）能否 `posix_spawn` 越狱目录下的二进制 → 决定按需激活是否成立
