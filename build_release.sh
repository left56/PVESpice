#!/usr/bin/env bash
set -euo pipefail

# 在仓库根目录执行 Release 构建（原生 macOS，非 Mac Catalyst）。
# 用法: ./build_release.sh
# 产物: .build/release-derived/Build/Products/Release/PVESpice.app

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# 预置依赖（与 Xcode 中 VENDOR_DIR 一致）：Phodav 3 + libsoup 3，供 spice_bridge 链接及后续 WebDAV。
VENDOR_ARM64="${ROOT}/Vendor-macos-arm64"
PHODAV_HEADER="${VENDOR_ARM64}/include/libphodav-3.0/libphodav/phodav.h"
if [[ ! -d "$VENDOR_ARM64" ]]; then
	echo "ERROR: 未找到 Vendor 树 $VENDOR_ARM64（请先按仓库文档准备 arm64 依赖）" >&2
	exit 1
fi
if [[ ! -f "$PHODAV_HEADER" ]]; then
	echo "ERROR: 未找到 Phodav 头文件 $PHODAV_HEADER" >&2
	exit 1
fi
for lib in libphodav-3.0.a libsoup-3.0.a; do
	if [[ ! -f "${VENDOR_ARM64}/lib/$lib" ]]; then
		echo "ERROR: 未找到 ${VENDOR_ARM64}/lib/$lib" >&2
		exit 1
	fi
done
export PKG_CONFIG_PATH="${VENDOR_ARM64}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
if command -v pkg-config >/dev/null 2>&1; then
	if ! pkg-config --exists libphodav-3.0 libsoup-3.0; then
		echo "ERROR: pkg-config 无法解析 libphodav-3.0 / libsoup-3.0（检查 PKG_CONFIG_PATH=$PKG_CONFIG_PATH）" >&2
		exit 1
	fi
	echo "==> pkg-config libphodav-3.0: $(pkg-config --modversion libphodav-3.0)"
	echo "==> pkg-config libsoup-3.0: $(pkg-config --modversion libsoup-3.0)"
fi

PROJECT="PVESpice.xcodeproj"
SCHEME="PVESpice"
CONFIGURATION="Release"
DERIVED_DATA="${ROOT}/.build/release-derived"

if ! command -v xcodebuild >/dev/null 2>&1; then
	echo "ERROR: xcodebuild 不在 PATH 中（请安装 Xcode 并执行 xcode-select）" >&2
	exit 1
fi

if [ ! -d "$ROOT/$PROJECT" ]; then
	echo "ERROR: 未找到 $PROJECT（请在 PVESpice 仓库根目录运行）" >&2
	exit 1
fi

echo "==> xcodebuild $SCHEME ($CONFIGURATION), derivedData: $DERIVED_DATA"

xcodebuild \
	-project "$PROJECT" \
	-scheme "$SCHEME" \
	-configuration "$CONFIGURATION" \
	-destination "generic/platform=macOS" \
	-derivedDataPath "$DERIVED_DATA" \
	ONLY_ACTIVE_ARCH=YES \
	build

APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/PVESpice.app"
if [ ! -d "$APP" ]; then
	echo "ERROR: 构建完成但未找到 $APP" >&2
	exit 1
fi

echo "==> 完成: $APP"
