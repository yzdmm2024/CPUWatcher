export ARCHS = arm64 arm64e
export TARGET = iphone:clang:14.0:14.5
export THEOS_PACKAGE_SCHEME = rootless
export THEOS_DEVICE_IP_OVERRIDE = 127.0.0.1

# 未知变量在 theos 中无害；用于关掉 -Werror，避免一条无害 warning 卡死 CI。
export GO_EASY_ON_ME = 1

include $(THEOS)/makefiles/common.mk

# ---------------------------------------------------------------------------
# 1) 悬浮窗 Tweak：只注入 SpringBoard。
#    硬性约束：%ctor 里不做任何 IO / 不起定时器，只有用户显式开启悬浮窗后才建窗。
# ---------------------------------------------------------------------------
TWEAK_NAME = CPUWatcherHUD
# CWCommon.m 只提供 JSON 原子写与公共路径，不含任何定时器/线程，注入 SpringBoard 是安全的。
CPUWatcherHUD_FILES = src/hud/CPUWatcherHUD.xm src/shared/CWCommon.m
CPUWatcherHUD_FRAMEWORKS = UIKit Foundation
CPUWatcherHUD_CFLAGS = -fobjc-arc -fobjc-exceptions -Isrc -I$(THEOS_PROJECT_DIR)/src/shared

include $(THEOS_MAKE_PATH)/tweak.mk

# ---------------------------------------------------------------------------
# 2) 按需特权助手 cpuwatchctl
#    不注册 launchd、开机零执行。由设置面板 spawn，面板返回即被 kill。
# ---------------------------------------------------------------------------
TOOL_NAME = cpuwatchctl
cpuwatchctl_FILES = src/helper/main.m src/shared/CWCommon.m src/shared/CWSampler.m
cpuwatchctl_FRAMEWORKS = Foundation
cpuwatchctl_CFLAGS = -fobjc-arc -Isrc -I$(THEOS_PROJECT_DIR)/src/shared
cpuwatchctl_INSTALL_PATH = /usr/bin
cpuwatchctl_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/entitlements/cpuwatchctl.entitlements

include $(THEOS_MAKE_PATH)/tool.mk

# ---------------------------------------------------------------------------
# 3) 设置面板。必须自包含（不能引用只编进 helper / tweak 的类），
#    否则在设置进程里 dlopen 会报 symbol not found in flat namespace，
#    表现就是「设置 -> CPU 监视器」直接不显示。
# ---------------------------------------------------------------------------
BUNDLE_NAME = CPUWatcherPrefs
CPUWatcherPrefs_FILES = Preferences/CPUWatcherPrefs.m src/shared/CWCommon.m src/shared/CWSampler.m
CPUWatcherPrefs_INSTALL_PATH = /Library/PreferenceBundles
CPUWatcherPrefs_CFLAGS = -fobjc-arc -fobjc-exceptions -Isrc -I$(THEOS_PROJECT_DIR)/src/shared
CPUWatcherPrefs_FRAMEWORKS = UIKit Foundation
CPUWatcherPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
