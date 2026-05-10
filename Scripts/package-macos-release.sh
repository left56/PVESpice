#!/usr/bin/env bash
set -euo pipefail

# 在仓库根目录执行 Release 构建并生成待上传 GitHub Releases 的 zip。
# 产物: Distribution/macos-arm64/PVESpice-<MARKETING_VERSION>-macos-arm64.zip（目录被 .gitignore 忽略）

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! MARKETING_VERSION="$(awk -F'= ' '/MARKETING_VERSION = /{gsub(/;/,"",$2); print $2; exit}' PVESpice.xcodeproj/project.pbxproj)"; then
	echo "ERROR: 无法从 project.pbxproj 解析 MARKETING_VERSION" >&2
	exit 1
fi
if [[ -z "$MARKETING_VERSION" ]]; then
	echo "ERROR: MARKETING_VERSION 为空" >&2
	exit 1
fi

"${ROOT}/build_release.sh"

APP="${ROOT}/.build/release-derived/Build/Products/Release/PVESpice.app"
if [[ ! -d "$APP" ]]; then
	echo "ERROR: 未找到 $APP" >&2
	exit 1
fi

OUT="${ROOT}/Distribution/macos-arm64"
mkdir -p "$OUT"
ZIP="${OUT}/PVESpice-${MARKETING_VERSION}-macos-arm64.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> 已生成（勿提交 Git）: $ZIP"
