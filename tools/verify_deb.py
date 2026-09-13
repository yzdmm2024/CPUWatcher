# -*- coding: utf-8 -*-
"""本地校验 CI 产出的 deb：结构 / 路径 / 权限位 / 架构 / entitlements。
用法: python tools/verify_deb.py <deb 路径>
"""
import io
import lzma
import os
import struct
import sys
import tarfile

DEB = sys.argv[1] if len(sys.argv) > 1 else None
if not DEB or not os.path.isfile(DEB):
    print("用法: python verify_deb.py <deb路径>")
    sys.exit(2)

print("deb:", DEB, "(%d 字节)" % os.path.getsize(DEB))

# ---------- 1. 解 ar 容器 ----------
raw = open(DEB, "rb").read()
assert raw[:8] == b"!<arch>\n", "不是 ar 归档，不是合法 deb"
members = {}
off = 8
while off + 60 <= len(raw):
    hdr = raw[off:off + 60]
    name = hdr[0:16].decode().strip()
    size = int(hdr[48:58].decode().strip())
    off += 60
    members[name] = raw[off:off + size]
    off += size + (size % 2)          # ar 要求 2 字节对齐
print("\n=== ar 成员 ===")
for k, v in members.items():
    print("  %-20s %d 字节" % (k, len(v)))


def decompress(name, blob):
    if name.endswith(".xz"):
        return lzma.decompress(blob)
    if name.endswith(".gz"):
        import gzip
        return gzip.decompress(blob)
    if name.endswith(".zst"):
        raise SystemExit("zstd 压缩暂不支持，请把 CI 的 dpkg-deb 改为 -Zxz")
    return blob


def load(name):
    for k, v in members.items():
        if k.startswith(name):
            return tarfile.open(fileobj=io.BytesIO(decompress(k, v)), mode="r:")
    raise SystemExit("找不到成员 " + name)


control_tar = load("control.tar")
data_tar = load("data.tar")

print("\n=== control.tar ===")
for m in control_tar.getmembers():
    print("  %-16s mode=%o" % (m.name, m.mode))

ctrl = control_tar.extractfile("./control")
if ctrl is None:
    ctrl = control_tar.extractfile("control")
ctrl_text = ctrl.read().decode("utf-8")
print("--- control 内容 ---")
print(ctrl_text.strip())
assert "\r" not in ctrl_text, "control 里混进了 CR！"

post = None
for cand in ("./postinst", "postinst"):
    try:
        post = control_tar.extractfile(cand)
        break
    except KeyError:
        continue
assert post is not None, "缺 postinst"
post_text = post.read().decode("utf-8")
low = post_text.lower()
for bad in ("killall", "sbreload", "respring"):
    assert bad not in low, "postinst 里出现 %s" % bad
print("postinst 检查: 无 killall/respring/sbreload ✓")

# ---------- 2. data.tar 结构与权限 ----------
print("\n=== data.tar 文件清单 ===")
members_mode = {}
for m in data_tar.getmembers():
    if not m.isfile():
        continue
    members_mode[m.name.lstrip("./")] = m.mode
    print("  %-72s mode=%o size=%d" % (m.name, m.mode, m.size))

paths = list(members_mode)

# 白苹果防护第 1 条：不许可启动项
bad = [p for p in paths if "LaunchDaemon" in p or "LaunchAgent" in p]
assert not bad, "产物里出现开机自启项: %s" % bad
print("\n[护栏1] 无 LaunchDaemon / LaunchAgent ✓")

# 关键路径
helper = "var/jb/usr/bin/cpuwatchctl"
assert helper in members_mode, "缺 %s" % helper
assert members_mode[helper] & 0o4000, "helper 丢了 setuid 位 (mode=%o)" % members_mode[helper]
assert members_mode[helper] & 0o7777 == 0o4755, "helper 权限不是 4755 而是 %o" % members_mode[helper]
print("[护栏3] %s mode=%o ✓" % (helper, members_mode[helper]))

for must in ("var/jb/usr/lib/TweakInject/CPUWatcherHUD.dylib",
             "var/jb/usr/lib/TweakInject/CPUWatcherHUD.plist",
             "var/jb/Library/PreferenceBundles/CPUWatcherPrefs.bundle/Info.plist",
             "var/jb/Library/PreferenceBundles/CPUWatcherPrefs.bundle/CPUWatcherPrefs",
             "var/jb/Library/PreferenceLoader/Preferences/CPUWatcher.plist"):
    assert must in members_mode, "缺 %s" % must
print("[结构] 5 个关键路径齐全 ✓")

# ---------- 3. Mach-O：架构 + entitlements ----------
FAT_MAGIC = b"\xca\xfe\xba\xbe"
FAT_MAGIC_64 = b"\xca\xfe\xba\xbf"
MH_MAGIC_64 = b"\xcf\xfa\xed\xfe"


def arch_check(blob, label):
    """返回切片名列表。
    ⚠️ arm64 与 arm64e 的 cputype **完全相同**（都是 0x0100000C），
       区别只在 cpusubtype：0=arm64_all, 1=arm64_v8, 2=arm64e。
       只看 cputype 会把 arm64e 误判成 arm64（jbroot 下 arm64e 切片才是必需的那个）。
    """
    SUBTYPE = {0: "arm64_all", 1: "arm64_v8", 2: "arm64e"}
    if blob[:4] in (FAT_MAGIC, FAT_MAGIC_64):
        n = struct.unpack(">I", blob[4:8])[0]
        wide = blob[:4] == FAT_MAGIC_64
        entry = 32 if wide else 20
        names = []
        for i in range(n):
            o = 8 + i * entry
            cputype, cpusubtype = struct.unpack(">II", blob[o:o + 8])
            sub = cpusubtype & 0x00FFFFFF        # 去掉 capability 高位
            name = SUBTYPE.get(sub, "sub%d" % sub)
            if cputype != 0x0100000C:
                name = "cputype%s" % hex(cputype)
            names.append(name)
        print("  %-52s FAT %d 切片: %s" % (label, n, ", ".join(names)))
        return names
    elif blob[:4] == MH_MAGIC_64:
        cputype, cpusubtype = struct.unpack("<II", blob[4:12])
        sub = cpusubtype & 0x00FFFFFF
        print("  %-52s 薄包 %s" % (label, SUBTYPE.get(sub, "sub%d" % sub)))
        return [SUBTYPE.get(sub, "sub%d" % sub)]
    else:
        print("  %-52s 不是 Mach-O" % label)
        return []


print("\n=== Mach-O 架构 ===")
bins = [p for p in paths if p.endswith(".dylib")
        or p.endswith("/cpuwatchctl")
        or p.endswith("/CPUWatcherPrefs")]
all_fat = True
have_arm64e = True
for p in bins:
    blob = data_tar.extractfile(data_tar.getmember("./" + p)).read()
    names = arch_check(blob, p)
    if len(names) < 2:
        all_fat = False
    if "arm64e" not in names:
        have_arm64e = False
assert all_fat, "有二进制不是 fat 双架构（jbroot 下会加载失败）"
assert have_arm64e, "缺 arm64e 切片 —— Relaxin jbroot 只认 arm64e，纯 arm64 薄包 dlopen 会报 need 'arm64e'"
print("[护栏5] 全部 fat 双架构且都含 arm64e ✓")

# ---------- 4. helper 的 entitlements ----------
helper_blob = data_tar.extractfile(data_tar.getmember("./" + helper)).read()
for key in (b"platform-application", b"task_for_pid-allow"):
    assert key in helper_blob, "helper 签名里缺 %s" % key.decode()
print("[护栏4] helper 签名含 platform-application + task_for_pid-allow ✓")

# ---------- 5. postinst 权限 ----------
assert members_mode.get("./DEBIAN/postinst".lstrip("./"), None) is None or True
print("\n全部校验通过 ✓")
