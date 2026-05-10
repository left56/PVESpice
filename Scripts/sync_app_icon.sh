#!/bin/sh
set -eu
ROOT="${SRCROOT:?}"
SVG="${ROOT}/icon.svg"
OUT="${ROOT}/PVESpiceMac/Resources/Assets.xcassets/AppIcon.appiconset"
STAMP="${OUT}/.generated_from_icon_svg"

if ! test -f "$SVG"; then
	echo "error: missing ${SVG}" >&2
	exit 1
fi

current_hash=$(shasum -a 256 "$SVG" | awk '{print $1}')
if test -f "$STAMP" && read -r saved_hash < "$STAMP" && test "$saved_hash" = "$current_hash"; then
	all_present=true
	for f in \
		icon-16.png icon-16@2x.png icon-32.png icon-32@2x.png \
		icon-128.png icon-128@2x.png icon-256.png icon-256@2x.png \
		icon-512.png icon-512@2x.png
	do
		if ! test -f "${OUT}/${f}"; then
			all_present=false
			break
		fi
	done
	if test "$all_present" = true; then
		exit 0
	fi
fi

if ! command -v rsvg-convert >/dev/null 2>&1; then
	echo "error: rsvg-convert not found; install librsvg (e.g. brew install librsvg) to rasterize icon.svg into the app icon set." >&2
	exit 1
fi

mkdir -p "$OUT"
rsvg-convert -w 16 -h 16 "$SVG" -o "${OUT}/icon-16.png"
rsvg-convert -w 32 -h 32 "$SVG" -o "${OUT}/icon-16@2x.png"
rsvg-convert -w 32 -h 32 "$SVG" -o "${OUT}/icon-32.png"
rsvg-convert -w 64 -h 64 "$SVG" -o "${OUT}/icon-32@2x.png"
rsvg-convert -w 128 -h 128 "$SVG" -o "${OUT}/icon-128.png"
rsvg-convert -w 256 -h 256 "$SVG" -o "${OUT}/icon-128@2x.png"
rsvg-convert -w 256 -h 256 "$SVG" -o "${OUT}/icon-256.png"
rsvg-convert -w 512 -h 512 "$SVG" -o "${OUT}/icon-256@2x.png"
rsvg-convert -w 512 -h 512 "$SVG" -o "${OUT}/icon-512.png"
rsvg-convert -w 1024 -h 1024 "$SVG" -o "${OUT}/icon-512@2x.png"
printf '%s\n' "$current_hash" >"$STAMP"
