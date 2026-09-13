# -*- coding: utf-8 -*-
"""通过 gh api (api.github.com) 把本地 HEAD 的整棵树推送到 GitHub。

用法: python push_via_gh_api.py <repo_dir> <owner/repo> <branch> <commit_message>

为什么需要这个脚本：本机沙箱到 github.com:443（git 传输端点）极不稳定，
api.github.com 才是稳的。走 Git Data API：blobs -> trees -> commits -> PATCH refs。

⚠️ 相对 F:\\BaiduNetdiskDownload 里那份原版的关键修复：
    原版把 `git show HEAD:<path>` 的**原始文件内容**直接塞进
    {"content": ..., "encoding": "base64"}，但那个字段要求的是**真正的 base64**。
    GitHub 对非法 base64 会做宽容处理 → 每个被"上传"的文件在远端都变成几百字节乱码。
    表现：CI 读到的工作流文件是垃圾 → 运行 0 秒失败，且 name 退化成文件路径。
    修复：b64encode 之后再发。并新增 verify()，推完立刻逐文件比对 blob sha，
    任何不一致直接报错，不给静默损坏留机会。
"""
import base64
import json
import subprocess
import sys
import time

if len(sys.argv) < 5:
    print(__doc__)
    sys.exit(2)

REPO_DIR, SLUG, BRANCH, MESSAGE = sys.argv[1:5]


def gh(method, path, payload=None, tries=4):
    for i in range(tries):
        cmd = ["gh", "api", "-X", method, path]
        if payload is not None:
            cmd += ["--input", "-"]
        p = subprocess.run(
            cmd,
            input=(json.dumps(payload).encode() if payload is not None else None),
            capture_output=True,
        )
        if p.returncode == 0:
            out = p.stdout.decode("utf-8")
            return json.loads(out) if out.strip() else {}
        err = p.stderr.decode("utf-8", "replace")
        if any(k in err for k in ("307", "502", "503", "EOF", "timeout")):
            print("  retry %d (%s)" % (i + 1, err.strip()[:140]))
            time.sleep(2)
            continue
        raise RuntimeError("gh api %s %s failed: %s" % (method, path, err[:800]))
    raise RuntimeError("gh api %s %s: 重试耗尽" % (method, path))


def git(*args):
    p = subprocess.run(["git", "-C", REPO_DIR] + list(args), capture_output=True)
    if p.returncode != 0:
        raise RuntimeError(
            "git %s failed: %s" % (" ".join(args[:3]), p.stderr.decode("utf-8", "replace")[:500])
        )
    return p.stdout


# 1. 远程 head + 递归树
remote_ref = gh("GET", "repos/%s/git/ref/heads/%s" % (SLUG, BRANCH))
base_sha = remote_ref["object"]["sha"]
base_tree = gh("GET", "repos/%s/git/commits/%s" % (SLUG, base_sha))["tree"]["sha"]
rt = gh("GET", "repos/%s/git/trees/%s?recursive=1" % (SLUG, base_tree))
remote_files = {
    e["path"]: (e["sha"], e.get("mode", "100644"))
    for e in rt.get("tree", [])
    if e["type"] == "blob"
}
print("remote %s head=%s, remote blobs=%d" % (BRANCH, base_sha[:10], len(remote_files)))

# 2. 本地 HEAD 树
out = git("ls-tree", "-r", "-z", "HEAD").decode("utf-8")
local_files = {}
for entry in [e for e in out.split("\0") if e]:
    meta, path = entry.split("\t", 1)
    mode, _typ, sha = meta.split()[:3]
    local_files[path] = (mode, sha)
print("local tracked files: %d" % len(local_files))

tree_entries = []
uploads = reuses = deletes = 0
for path, (mode, sha) in sorted(local_files.items()):
    if path in remote_files and remote_files[path][0] == sha:
        reuses += 1
        continue
    # 关键：这里必须是真正的 base64
    raw = git("show", "HEAD:" + path)
    b64 = base64.b64encode(raw).decode("ascii")
    blob = gh("POST", "repos/%s/git/blobs" % SLUG, {"content": b64, "encoding": "base64"})
    # 立刻校验：远端算出来的 sha 必须和本地对象 sha 一致，否则就是内容被改了
    if blob["sha"] != sha:
        raise RuntimeError(
            "blob 上传后 sha 不匹配：%s\n  local=%s\n  remote=%s\n"
            "  说明内容被改写了，拒绝继续。" % (path, sha, blob["sha"])
        )
    tree_entries.append({"path": path, "mode": mode, "type": "blob", "sha": blob["sha"]})
    uploads += 1
    print("  upload:", path)

for path in sorted(remote_files):
    if path not in local_files:
        tree_entries.append({"path": path, "mode": "100644", "type": "blob", "sha": None})
        deletes += 1
        print("  delete:", path)

print("reuse=%d upload=%d delete=%d" % (reuses, uploads, deletes))
if not tree_entries:
    print("远程树已与本地一致，无需推送")
    sys.exit(0)

# 3. tree -> commit -> 更新 ref
tree = gh("POST", "repos/%s/git/trees" % SLUG, {"base_tree": base_tree, "tree": tree_entries})
commit = gh(
    "POST",
    "repos/%s/git/commits" % SLUG,
    {"message": MESSAGE, "tree": tree["sha"], "parents": [base_sha]},
)
gh("PATCH", "repos/%s/git/refs/heads/%s" % (SLUG, BRANCH), {"sha": commit["sha"]})
print("PUSHED: %s -> %s (commit %s)" % (BRANCH, SLUG, commit["sha"]))

# 4. 收尾校验：拉回远程树，逐文件比对 blob sha
print("verifying remote tree ...")
check_tree = commit["tree"]["sha"]
rt2 = gh("GET", "repos/%s/git/trees/%s?recursive=1" % (SLUG, check_tree))
remote2 = {
    e["path"]: e["sha"] for e in rt2.get("tree", []) if e["type"] == "blob"
}
bad = []
for path, (_mode, sha) in local_files.items():
    if remote2.get(path) != sha:
        bad.append(path)
extra = [p for p in remote2 if p not in local_files]
if bad or extra:
    print("FATAL: 远程树与本地不一致")
    for p in bad:
        print("  mismatch:", p)
    for p in extra:
        print("  extra:", p)
    sys.exit(1)
print("VERIFIED: %d 个文件远程与本地 blob sha 全部一致" % len(local_files))
