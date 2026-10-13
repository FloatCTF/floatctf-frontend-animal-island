#!/usr/bin/env bash
#
# 把三个 @floatctf/* 依赖指向本地 packed tarball。
#
# 为什么需要它：@floatctf/sdk、@floatctf/frontend-runtime、@floatctf/react **尚未发布到
# npm**，而 `workspace:*` 是 monorepo 内部协议，独立 checkout（含 CI）用不了。
#
# 用法：
#   ./scripts/use-local-packages.sh [tarball 所在目录]        # 默认 /tmp/pkgs
#
# 生成 tarball（在 FloatCTF monorepo 里，用平台自带的打包脚本：确定性命名 + fail-closed 校验）：
#   git clone --depth 1 https://github.com/FloatCTF/floatctf.git /tmp/floatctf
#   cd /tmp/floatctf && pnpm install --frozen-lockfile
#   ./scripts/package-sdk-dist.sh /tmp/pkgs
#   # → floatctf-sdk-<V>.tgz / floatctf-react-<V>.tgz / floatctf-frontend-runtime-<V>.tgz
#
# 本脚本**不写死版本号**：按 `floatctf-<pkg>-<version>.tgz` 通配解析，并要求三包版本一致；
# 同时拒绝「没有 dist/ 入口」的空壳 tarball（只在源码树里裸 `pnpm pack` 的典型产物）。
#
# 为什么必须写 `overrides`（而不是只改 package.json 的直接依赖）：
#   1. `@floatctf/react` 自身依赖 `@floatctf/sdk`，这条**传递依赖**也要被改写，
#      否则它仍会去 registry 找而 404；
#   2. pnpm 11 起 `package.json` 的 `pnpm.overrides` **不再被读取**（只打一行 WARN），
#      必须写在 `pnpm-workspace.yaml`；
#   3. overrides 同样覆盖 package.json 里写的 `^1.0.0` 与 `workspace:*`，
#      因此本脚本**不改 package.json**（独立 checkout 里没有 workspace 可解析）。
set -Eeuo pipefail

die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }

DIR="${1:-/tmp/pkgs}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[ -d "$DIR" ] \
	|| die "找不到 tarball 目录：$DIR（先用 monorepo 的 scripts/package-sdk-dist.sh <dir> 生成）"
DIR="$(cd "$DIR" && pwd)"

command -v python3 >/dev/null 2>&1 || die "需要 python3 改写 pnpm-workspace.yaml"
command -v tar >/dev/null 2>&1 || die "需要 tar 校验 tarball 内容"

# resolve_tarball <短名> → stdout: "<绝对路径>\t<版本>"
resolve_tarball() {
	local short="$1"
	local -a hits=()
	shopt -s nullglob
	local f
	for f in "$DIR/floatctf-$short-"*.tgz "$DIR/$short-"*.tgz; do
		hits+=("$f")
	done
	shopt -u nullglob
	[ "${#hits[@]}" -gt 0 ] \
		|| die "在 $DIR 找不到 $short 的 tarball（期望 floatctf-$short-<version>.tgz）"
	[ "${#hits[@]}" -eq 1 ] \
		|| die "在 $DIR 匹配到多个 $short tarball，无法确定用哪个版本：${hits[*]}"

	local path base version members
	path="${hits[0]}"
	base="$(basename "$path")"
	version="${base#floatctf-$short-}"
	version="${version%.tgz}"
	[ -n "$version" ] || die "无法从 $base 解析版本号"

	# 空壳保护：三个包的 files 只含 dist + README，缺 dist 入口说明打包前没有构建。
	# 注意**不要**写成 `tar tzf … | grep -q …`：grep 命中即退出会让 tar 收到 SIGPIPE，
	# 在 `set -o pipefail` 下整条管道变成非 0，把「存在」误判成「缺失」。
	members="$(tar tzf "$path")" || die "无法读取 tarball：$base"
	case $'\n'"$members"$'\n' in
		*$'\n'"package/dist/index.js"$'\n'*) ;;
		*) die "$base 里没有 package/dist/index.js —— 打包前没有构建（请用 monorepo 的 scripts/package-sdk-dist.sh）" ;;
	esac

	printf '%s\t%s' "$path" "$version"
}

SDK="$(resolve_tarball sdk)"
REACT="$(resolve_tarball react)"
RUNTIME="$(resolve_tarball frontend-runtime)"

F_SDK="${SDK%%$'\t'*}" && V_SDK="${SDK#*$'\t'}"
F_REACT="${REACT%%$'\t'*}" && V_REACT="${REACT#*$'\t'}"
F_RUNTIME="${RUNTIME%%$'\t'*}" && V_RUNTIME="${RUNTIME#*$'\t'}"

[ "$V_SDK" = "$V_REACT" ] && [ "$V_SDK" = "$V_RUNTIME" ] \
	|| die "三个包版本不一致：sdk=$V_SDK react=$V_REACT frontend-runtime=$V_RUNTIME（monorepo 里版本必须统一）"

info "使用 @floatctf/* = $V_SDK（tarball 来自 $DIR）"

# 用 python 改 YAML：只在缺少 overrides 时追加/替换，避免重复运行把文件写乱。
# 只传**文件名**（overrides 里的 file: 是相对 `DIR` 拼出来的），不要传绝对路径。
PKGS_DIR="$DIR" \
	T_SDK="$(basename "$F_SDK")" T_REACT="$(basename "$F_REACT")" T_RUNTIME="$(basename "$F_RUNTIME")" \
	python3 - <<'PY'
import os
import pathlib
import re
import sys

d = os.environ["PKGS_DIR"].rstrip("/")
block = "overrides:\n" + "".join(
	f'  "{name}": "file:{d}/{filename}"\n'
	for name, filename in (
		("@floatctf/sdk", os.environ["T_SDK"]),
		("@floatctf/react", os.environ["T_REACT"]),
		("@floatctf/frontend-runtime", os.environ["T_RUNTIME"]),
	)
)

p = pathlib.Path("pnpm-workspace.yaml")
s = p.read_text(encoding="utf-8") if p.exists() else ""

# pnpm 11 默认拦截依赖的构建脚本；esbuild 的 postinstall 不放行，`vite build` 起不来
# （旧名 onlyBuiltDependencies 已失效，必须用 allowBuilds 的 map 形式）。
if not re.search(r"(?m)^allowBuilds:\s*$", s):
	sys.exit(
		"pnpm-workspace.yaml 缺少 allowBuilds 段（pnpm 11 默认拦截构建脚本）。"
		"应包含：\nallowBuilds:\n  esbuild: true"
	)
if not re.search(r'(?m)^\s+"?esbuild"?:\s*true\s*$', s):
	sys.exit("pnpm-workspace.yaml 的 allowBuilds 未放行 esbuild: true（vite build 会失败）")

if re.search(r"(?m)^overrides:\s*$", s):
	head, _, rest = s.partition("overrides:")
	lines = rest.split("\n")
	idx = len(lines)
	for i, line in enumerate(lines):
		# 照旧实现：丢弃旧 overrides 段（到下一个顶层 key 或文件尾）
		if line and not line.startswith((" ", "\t", "#")):
			idx = i
			break
	s = head + block + "\n".join(lines[idx:])
else:
	s = s.rstrip("\n") + "\n\n" + block
p.write_text(s, encoding="utf-8")
print(f"  ✓ overrides 已写入 pnpm-workspace.yaml → {d}")
PY

info "下一步：pnpm install --no-lockfile && pnpm build"
