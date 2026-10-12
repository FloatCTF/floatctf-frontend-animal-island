#!/usr/bin/env bash
#
# 把三个 @floatctf/* 依赖指向本地 packed tarball。
#
# 为什么需要它：@floatctf/* 尚未发布到 npm，而 `workspace:*` 是 monorepo 内部协议，
# 独立仓库用不了。因此先在 FloatCTF monorepo 里 `pack`，再让本仓库指向那些 tarball。
#
# 用法：
#   ./scripts/use-local-packages.sh [tarball 所在目录]        # 默认 /tmp/pkgs
#
# 生成 tarball（在 FloatCTF monorepo 里）：
#   pnpm run build:packages
#   pnpm --filter @floatctf/frontend-runtime --filter @floatctf/sdk --filter @floatctf/react \
#      pack --pack-destination /tmp/pkgs
#
set -Eeuo pipefail

DIR="${1:-/tmp/pkgs}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[ -d "$DIR" ] || { echo "找不到目录：$DIR" >&2; exit 1; }

declare -A FILES=(
  ["@floatctf/sdk"]="floatctf-sdk-1.0.0.tgz"
  ["@floatctf/frontend-runtime"]="floatctf-frontend-runtime-1.0.0.tgz"
  ["@floatctf/react"]="floatctf-react-1.0.0.tgz"
)

for name in "${!FILES[@]}"; do
  f="$DIR/${FILES[$name]}"
  [ -f "$f" ] || { echo "缺少 $f —— 先在 monorepo 里 pack（见脚本头部注释）" >&2; exit 1; }
done

# 用 python 改 YAML：只在缺少 overrides 时追加，避免重复运行把文件写乱
python3 - "$DIR" <<'PY'
import pathlib, sys
d = sys.argv[1].rstrip("/")
p = pathlib.Path("pnpm-workspace.yaml")
s = p.read_text(encoding="utf-8")
block = (
    "overrides:\n"
    f'  "@floatctf/sdk": "file:{d}/floatctf-sdk-1.0.0.tgz"\n'
    f'  "@floatctf/frontend-runtime": "file:{d}/floatctf-frontend-runtime-1.0.0.tgz"\n'
    f'  "@floatctf/react": "file:{d}/floatctf-react-1.0.0.tgz"\n'
)
if "overrides:" in s:
    head, _, rest = s.partition("overrides:")
    # 丢弃旧的 overrides 段（到下一个顶层 key 或文件尾）
    lines = rest.split("\n")
    idx = 0
    for i, l in enumerate(lines):
        if l and not l.startswith((" ", "\t", "#")):
            idx = i; break
    else:
        idx = len(lines)
    s = head + block + "\n".join(lines[idx:])
else:
    s = s.rstrip("\n") + "\n\n" + block
p.write_text(s, encoding="utf-8")
print(f"  ✓ overrides 已写入 pnpm-workspace.yaml → {d}")
PY

echo "  下一步：pnpm install"
