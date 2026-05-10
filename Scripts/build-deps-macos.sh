#!/bin/bash
set -euo pipefail

# ============================================================================
# build-deps-macos.sh - Build C dependencies for native macOS (Apple Silicon)
# ============================================================================
# Builds static libraries (.a) for:
#   OpenSSL, libffi, glib, pixman, opus, libjpeg-turbo,
#   json-glib, spice-protocol, spice-client-glib, libsoup, phodav, …
#
# Target: arm64-apple-macos14.0  (native macOS app; no Mac Catalyst / macabi)
#
# Requirements: Apple Silicon Mac, Xcode CLI tools, meson, ninja, autoconf,
#               automake, libtool, pkg-config, nasm (for libjpeg-turbo)
#
# Output: $PREFIX (default: Vendor-macos-arm64/)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SOURCES_DIR="$PROJECT_DIR/.build-deps-macos/sources"

ARCH="${1:-arm64}"
if [ "$ARCH" != "arm64" ]; then
    echo "ERROR: This project only supports arm64 (Apple Silicon). Got: $ARCH" >&2
    exit 1
fi

MACOS_MIN="14.0"
BUILD_DIR="$PROJECT_DIR/.build-deps-macos-${ARCH}"
PREFIX="$PROJECT_DIR/Vendor-macos-${ARCH}"
TARGET_TRIPLE="${ARCH}-apple-macos${MACOS_MIN}"
SDK="macosx"
SDKROOT=$(xcrun --sdk $SDK --show-sdk-path)
CC="$(xcrun --sdk $SDK --find clang)"
CXX="$(xcrun --sdk $SDK --find clang++)"
AR="$(xcrun --sdk $SDK --find ar)"
RANLIB="$(xcrun --sdk $SDK --find ranlib)"
STRIP="$(xcrun --sdk $SDK --find strip)"

CFLAGS="-target $TARGET_TRIPLE -isysroot $SDKROOT -O2"
CXXFLAGS="$CFLAGS"
LDFLAGS="-target $TARGET_TRIPLE -isysroot $SDKROOT"

AUTOTOOLS_HOST="aarch64-apple-darwin"
MESON_CPU_FAMILY="aarch64"
MESON_CPU="arm64"
HOST="$AUTOTOOLS_HOST"

NJOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)

# Ensure meson/ninja are findable (Homebrew / pip user installs)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
if [ -n "${HOME:-}" ] && [ -d "$HOME/Library/Python" ]; then
    for pydir in "$HOME/Library/Python"/*/bin; do
        [ -d "$pydir" ] && PATH="$pydir:$PATH"
    done
fi
export PATH

# Meson subprojects (spice, libsoup, phodav) need a Python with pip modules when applicable.
export SPICE_HOST_PY="${MESON_HOST_PYTHON:-$(command -v python3)}"

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"

# Library versions
OPENSSL_VERSION="3.2.1"
LIBFFI_VERSION="3.4.6"
GLIB_VERSION="2.78.4"
PIXMAN_VERSION="0.42.2"
OPUS_VERSION="1.4"
LIBJPEG_VERSION="3.1.0"
JSONGLIB_VERSION="1.8.0"
SPICE_PROTOCOL_VERSION="0.14.4"
SPICE_GTK_VERSION="0.42"
# WebDAV / clipboard FILE_LIST (libspice + Phodav stack)
LIBXML2_VERSION="2.12.7"
SQLITE_YEAR="2024"
SQLITE_VERSION="3450100"
# Human-readable version for sqlite3.pc (must match sqlite-autoconf-${SQLITE_VERSION})
SQLITE_PKG_SEMVER="3.45.1"
LIBSOUP_VERSION="3.4.4"
# Required by libsoup 3.4.x meson (HTTP/2); static lib-only, no nghttp apps.
NGHTTP2_VERSION="1.61.0"
# Public Suffix List (libsoup hard-depends on libpsl; release tarball has no subproject wrap).
LIBUNISTRING_VERSION="1.2"
LIBIDN2_VERSION="2.3.7"
LIBPSL_VERSION="0.21.5"
PHODAV_VERSION="3.0"

# ============================================================================
# Helper functions
# ============================================================================

log() {
    echo "=== $(date '+%H:%M:%S') $1 ==="
}

# Try one URL with the same curl fallbacks used across the script.
# LibreSSL + download.gnome.org sometimes returns SSL_ERROR_SYSCALL (curl 35);
# --http1.1 / --ipv4 / --tls-max 1.2 often help on flaky paths.
_curl_fetch_one_url() {
    local dest="$1"
    local url="$2"
    rm -f "$dest"
    local cf=(curl -Lf --http1.1 --connect-timeout 90 --retry 3 --retry-delay 2)
    if "${cf[@]}" -o "$dest" "$url"; then
        return 0
    elif "${cf[@]}" --ipv4 -o "$dest" "$url"; then
        return 0
    elif "${cf[@]}" --ipv4 --tls-max 1.2 -o "$dest" "$url"; then
        return 0
    elif "${cf[@]}" --tls-max 1.2 -o "$dest" "$url"; then
        return 0
    elif command -v wget >/dev/null 2>&1 && wget -q -O "$dest" "$url"; then
        return 0
    fi
    return 1
}

# Same tarball from several bases (identical content/layout as download.gnome.org).
download_gnome_sources() {
    local relpath="$1"
    local dest="$2"
    if [ -f "$dest" ]; then
        return 0
    fi
    log "Downloading $(basename "$dest")"
    local bases=(
        "https://download.gnome.org/sources"
        "https://mirror.csclub.uwaterloo.ca/gnome/sources"
        "https://ftp.acc.umu.se/pub/GNOME/sources"
        "https://www.mirrorservice.org/sites/ftp.gnome.org/pub/GNOME/sources"
    )
    local base url
    for base in "${bases[@]}"; do
        url="${base}/${relpath}"
        if _curl_fetch_one_url "$dest" "$url"; then
            return 0
        fi
        log "WARN: fetch failed (${url}), trying next mirror..."
    done
    log "ERROR: Download failed for $(basename "$dest") (GNOME mirrors exhausted)"
    exit 1
}

# GNOME sources/<pkg>/<subdir>/ uses two-part minor: 3.4.4 -> 3.4, but 3.0 must stay 3.0 (not 3).
gnome_sources_minor_dir() {
    local ver="$1"
    case "$ver" in
    *.*.*) printf '%s\n' "${ver%.*}" ;;
    *) printf '%s\n' "$ver" ;;
    esac
}

download() {
    local url="$1"
    local dest="$2"
    if [ ! -f "$dest" ]; then
        log "Downloading $(basename "$dest")"
        if _curl_fetch_one_url "$dest" "$url"; then
            return 0
        fi
        log "ERROR: Download failed: $url"
        exit 1
    fi
}

# ============================================================================
# Build each dependency
# ============================================================================

mkdir -p "$BUILD_DIR" "$SOURCES_DIR" "$PREFIX/lib" "$PREFIX/include" "$PREFIX/lib/pkgconfig"

# --- OpenSSL ---
build_openssl() {
    log "Building OpenSSL $OPENSSL_VERSION"
    cd "$BUILD_DIR"
    download "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" \
             "$SOURCES_DIR/openssl-${OPENSSL_VERSION}.tar.gz"

    if [ ! -f "$PREFIX/lib/libssl.a" ]; then
        rm -rf openssl-${OPENSSL_VERSION}
        tar xzf "$SOURCES_DIR/openssl-${OPENSSL_VERSION}.tar.gz"
        cd openssl-${OPENSSL_VERSION}

        # Use the appropriate darwin64 config for the host architecture.
        OPENSSL_TARGET="darwin64-${ARCH}-cc"
        CC="$CC" \
        CFLAGS="$CFLAGS" \
        LDFLAGS="$LDFLAGS" \
        ./Configure "$OPENSSL_TARGET" \
            --prefix="$PREFIX" \
            no-shared \
            no-tests \
            no-ui-console

        make -j$NJOBS
        make install_sw
        log "OpenSSL done"
    else
        log "OpenSSL already built"
    fi
}

# --- libffi ---
build_libffi() {
    log "Building libffi $LIBFFI_VERSION"
    cd "$BUILD_DIR"
    download "https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/libffi-${LIBFFI_VERSION}.tar.gz" \
             "$SOURCES_DIR/libffi-${LIBFFI_VERSION}.tar.gz"

    if [ ! -f "$PREFIX/lib/libffi.a" ]; then
        rm -rf libffi-${LIBFFI_VERSION}
        tar xzf "$SOURCES_DIR/libffi-${LIBFFI_VERSION}.tar.gz"
        cd libffi-${LIBFFI_VERSION}

        CC="$CC" CFLAGS="$CFLAGS -Wno-deprecated-declarations" LDFLAGS="$LDFLAGS" \
        ./configure \
            --host=$HOST \
            --prefix="$PREFIX" \
            --enable-static \
            --disable-shared \
            --disable-docs

        # configure enables HAVE_AS_CFI_PSEUDO_OP because the assembler accepts
        # .cfi_startproc, but Apple clang's integrated assembler rejects
        # `.cfi_def_cfa x1, …` in src/aarch64/sysv.S ("invalid CFI advance_loc expression").
        # Disabling the flag makes ffi_cfi.h use no-op CFI macros (stack unwind metadata only).
        find . -name "fficonfig.h" -exec sed -i '' 's/#define HAVE_AS_CFI_PSEUDO_OP 1/\/* HAVE_AS_CFI_PSEUDO_OP disabled for Apple aarch64 macOS toolchain *\//' {} \;

        make -j$NJOBS
        make install
        log "libffi done"
    else
        log "libffi already built"
    fi
}

# --- GLib ---
build_glib() {
    log "Building GLib $GLIB_VERSION"
    cd "$BUILD_DIR"
    download "https://github.com/GNOME/glib/archive/refs/tags/${GLIB_VERSION}.tar.gz" \
             "$SOURCES_DIR/glib-${GLIB_VERSION}.tar.gz"

    if [ ! -f "$PREFIX/lib/libglib-2.0.a" ]; then
        # gdbus-codegen imports distutils.version (removed in CPython 3.12+). Meson must
        # use a Python that still provides it (e.g. 3.11) — not necessarily `python3` on PATH.
        GLIB_PYTHON="${GLIB_CODEGEN_PYTHON:-}"
        if [ -z "$GLIB_PYTHON" ]; then
            for cand in /usr/bin/python3 \
                /opt/homebrew/opt/python@3.11/bin/python3.11 \
                /usr/local/opt/python@3.11/bin/python3.11 \
                "$(command -v python3.11 2>/dev/null)"; do
                [ -n "$cand" ] && [ -x "$cand" ] || continue
                if "$cand" -c 'import distutils.version' 2>/dev/null; then
                    GLIB_PYTHON=$cand
                    break
                fi
            done
        fi
        if [ -z "$GLIB_PYTHON" ]; then
            log "ERROR: No Python with distutils found (GLib 2.78 gdbus-codegen). CPython 3.12+ removed distutils."
            log "Fix: brew install python@3.11, or set GLIB_CODEGEN_PYTHON to such an interpreter, then re-run."
            exit 1
        fi
        log "GLib codegen Python: $GLIB_PYTHON"

        rm -rf glib-${GLIB_VERSION}
        tar xzf "$SOURCES_DIR/glib-${GLIB_VERSION}.tar.gz"
        cd glib-${GLIB_VERSION}

        # GitHub tag archives omit git submodule contents, leaving an empty
        # subprojects/gvdb that makes Meson fail ("no meson.build"). Use the
        # wrap file and clone gvdb from GitHub (same revision as in gvdb.wrap).
        rm -rf subprojects/gvdb
        perl -pi -e 's|https://gitlab.gnome.org/GNOME/gvdb.git|https://github.com/GNOME/gvdb.git|g' subprojects/gvdb.wrap

        cat > macos-cross.ini <<CROSSEOF
[binaries]
c = '$CC'
objc = '$CC'
ar = '$AR'
strip = '$STRIP'
pkg-config = '$(which pkg-config)'
python = '$GLIB_PYTHON'

[built-in options]
c_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-I$PREFIX/include']
c_link_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-L$PREFIX/lib']
objc_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-I$PREFIX/include']
objc_link_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-L$PREFIX/lib']

[host_machine]
system = 'darwin'
subsystem = 'macos'
cpu_family = '$MESON_CPU_FAMILY'
cpu = '$MESON_CPU'
endian = 'little'
CROSSEOF

        meson setup _build \
            --cross-file=macos-cross.ini \
            --prefix="$PREFIX" \
            --default-library=static \
            -Dtests=false \
            -Dglib_debug=disabled \
            -Dlibelf=disabled \
            -Dnls=disabled \
            -Dlibmount=disabled \
            -Dxattr=false

        ninja -C _build -j$NJOBS
        ninja -C _build install
        log "GLib done"
    else
        log "GLib already built"
    fi
}

# --- Pixman ---
build_pixman() {
    log "Building pixman $PIXMAN_VERSION"
    cd "$BUILD_DIR"
    download "https://cairographics.org/releases/pixman-${PIXMAN_VERSION}.tar.gz" \
             "$SOURCES_DIR/pixman-${PIXMAN_VERSION}.tar.gz"

    if [ ! -f "$PREFIX/lib/libpixman-1.a" ]; then
        rm -rf pixman-${PIXMAN_VERSION}
        tar xzf "$SOURCES_DIR/pixman-${PIXMAN_VERSION}.tar.gz"
        cd pixman-${PIXMAN_VERSION}

        cat > macos-cross.ini <<CROSSEOF
[binaries]
c = '$CC'
objc = '$CC'
ar = '$AR'
strip = '$STRIP'

[built-in options]
c_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT']
c_link_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT']
objc_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT']
objc_link_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT']

[host_machine]
system = 'darwin'
subsystem = 'macos'
cpu_family = '$MESON_CPU_FAMILY'
cpu = '$MESON_CPU'
endian = 'little'
CROSSEOF

        meson setup _build \
            --cross-file=macos-cross.ini \
            --prefix="$PREFIX" \
            --default-library=static \
            -Dtests=disabled \
            -Darm-simd=disabled \
            -Dneon=disabled \
            -Da64-neon=disabled

        ninja -C _build -j$NJOBS
        ninja -C _build install
        log "Pixman done"
    else
        log "Pixman already built"
    fi
}

# --- Opus ---
build_opus() {
    log "Building opus $OPUS_VERSION"
    cd "$BUILD_DIR"
    download "https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz" \
             "$SOURCES_DIR/opus-${OPUS_VERSION}.tar.gz"

    if [ ! -f "$PREFIX/lib/libopus.a" ]; then
        rm -rf opus-${OPUS_VERSION}
        tar xzf "$SOURCES_DIR/opus-${OPUS_VERSION}.tar.gz"
        cd opus-${OPUS_VERSION}

        CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
        ./configure \
            --host=$HOST \
            --prefix="$PREFIX" \
            --enable-static \
            --disable-shared \
            --disable-doc \
            --disable-extra-programs

        make -j$NJOBS
        make install
        log "Opus done"
    else
        log "Opus already built"
    fi
}

# --- libjpeg-turbo ---
build_libjpeg() {
    log "Building libjpeg-turbo $LIBJPEG_VERSION"
    cd "$BUILD_DIR"
    download "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${LIBJPEG_VERSION}/libjpeg-turbo-${LIBJPEG_VERSION}.tar.gz" \
             "$SOURCES_DIR/libjpeg-turbo-${LIBJPEG_VERSION}.tar.gz"

    if [ ! -f "$PREFIX/lib/libjpeg.a" ]; then
        rm -rf libjpeg-turbo-${LIBJPEG_VERSION}
        tar xzf "$SOURCES_DIR/libjpeg-turbo-${LIBJPEG_VERSION}.tar.gz"
        cd libjpeg-turbo-${LIBJPEG_VERSION}

        cmake -B _build \
            -DCMAKE_INSTALL_PREFIX="$PREFIX" \
            -DCMAKE_SYSTEM_NAME=Darwin \
            -DCMAKE_SYSTEM_PROCESSOR="$ARCH" \
            -DCMAKE_C_COMPILER="$CC" \
            -DCMAKE_C_COMPILER_AR="$AR" \
            -DCMAKE_OSX_SYSROOT="$SDKROOT" \
            -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
            -DCMAKE_C_FLAGS="$CFLAGS" \
            -DENABLE_SHARED=OFF \
            -DENABLE_STATIC=ON \
            -DWITH_TURBOJPEG=OFF

        cmake --build _build -j$NJOBS
        cmake --install _build
        log "libjpeg-turbo done"
    else
        log "libjpeg-turbo already built"
    fi
}

# --- json-glib ---
build_json_glib() {
    log "Building json-glib $JSONGLIB_VERSION"
    cd "$BUILD_DIR"
    download "https://github.com/GNOME/json-glib/archive/refs/tags/${JSONGLIB_VERSION}.tar.gz" \
             "$SOURCES_DIR/json-glib-${JSONGLIB_VERSION}.tar.gz"

    if [ ! -f "$PREFIX/lib/libjson-glib-1.0.a" ]; then
        rm -rf json-glib-${JSONGLIB_VERSION}
        tar xzf "$SOURCES_DIR/json-glib-${JSONGLIB_VERSION}.tar.gz"
        cd json-glib-${JSONGLIB_VERSION}

        cat > macos-cross.ini <<CROSSEOF
[binaries]
c = '$CC'
objc = '$CC'
ar = '$AR'
strip = '$STRIP'
pkg-config = '$(which pkg-config)'

[built-in options]
c_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-I$PREFIX/include', '-I$PREFIX/include/glib-2.0', '-I$PREFIX/lib/glib-2.0/include']
c_link_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-L$PREFIX/lib']
objc_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-I$PREFIX/include', '-I$PREFIX/include/glib-2.0', '-I$PREFIX/lib/glib-2.0/include']
objc_link_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-L$PREFIX/lib']

[host_machine]
system = 'darwin'
subsystem = 'macos'
cpu_family = '$MESON_CPU_FAMILY'
cpu = '$MESON_CPU'
endian = 'little'
CROSSEOF

        meson setup _build \
            --cross-file=macos-cross.ini \
            --prefix="$PREFIX" \
            --default-library=static \
            -Dtests=false \
            -Dgtk_doc=disabled \
            -Dintrospection=disabled

        ninja -C _build -j$NJOBS
        ninja -C _build install
        log "json-glib done"
    else
        log "json-glib already built"
    fi
}

# --- libxml2 (static; required by libsoup / phodav) ---
build_libxml2() {
    log "Building libxml2 $LIBXML2_VERSION"
    cd "$BUILD_DIR"
    download_gnome_sources "libxml2/2.12/libxml2-${LIBXML2_VERSION}.tar.xz" \
                           "$SOURCES_DIR/libxml2-${LIBXML2_VERSION}.tar.xz"

    if [ ! -f "$PREFIX/lib/libxml2.a" ]; then
        rm -rf "libxml2-${LIBXML2_VERSION}"
        tar xJf "$SOURCES_DIR/libxml2-${LIBXML2_VERSION}.tar.xz"
        cd "libxml2-${LIBXML2_VERSION}"

        CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
        ./configure \
            --host="$HOST" \
            --prefix="$PREFIX" \
            --enable-static \
            --disable-shared \
            --without-python \
            --without-lzma \
            --without-readline \
            --without-debug \
            --without-mem-debug

        make -j$NJOBS
        make install
        log "libxml2 done"
    else
        log "libxml2 already built"
    fi
}

# --- SQLite (static; libsoup cookies / storage) ---
build_sqlite3() {
    log "Building SQLite $SQLITE_VERSION"
    cd "$BUILD_DIR"
    download "https://www.sqlite.org/${SQLITE_YEAR}/sqlite-autoconf-${SQLITE_VERSION}.tar.gz" \
             "$SOURCES_DIR/sqlite-autoconf-${SQLITE_VERSION}.tar.gz"

    if [ ! -f "$PREFIX/lib/libsqlite3.a" ]; then
        rm -rf "sqlite-autoconf-${SQLITE_VERSION}"
        tar xzf "$SOURCES_DIR/sqlite-autoconf-${SQLITE_VERSION}.tar.gz"
        cd "sqlite-autoconf-${SQLITE_VERSION}"

        # Do not use ./configure && make: the default build compiles shell.c (CLI), which pulls
        # extra dependencies; for a static lib we only compile the amalgamation.
        rm -f sqlite3.o libsqlite3.a
        "$CC" $CFLAGS -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION=1 -c sqlite3.c -o sqlite3.o
        "$AR" rcs libsqlite3.a sqlite3.o
        "$RANLIB" libsqlite3.a 2>/dev/null || true
        mkdir -p "$PREFIX/lib" "$PREFIX/include" "$PREFIX/lib/pkgconfig"
        cp libsqlite3.a "$PREFIX/lib/"
        cp sqlite3.h "$PREFIX/include/"
        if [ -f sqlite3ext.h ]; then
            cp sqlite3ext.h "$PREFIX/include/"
        fi
        cat > "$PREFIX/lib/pkgconfig/sqlite3.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: SQLite
Version: $SQLITE_PKG_SEMVER
Description: SQLite library (static amalgamation)
Libs: -L\${libdir} -lsqlite3
Cflags: -I\${includedir}
EOF
        log "sqlite3 done"
    else
        log "sqlite3 already built"
    fi
}

# --- nghttp2 (static; libsoup 3.4+ hard-depends on libnghttp2) ---
build_nghttp2() {
    log "Building nghttp2 $NGHTTP2_VERSION"
    cd "$BUILD_DIR"
    download "https://github.com/nghttp2/nghttp2/releases/download/v${NGHTTP2_VERSION}/nghttp2-${NGHTTP2_VERSION}.tar.xz" \
             "$SOURCES_DIR/nghttp2-${NGHTTP2_VERSION}.tar.xz"

    if [ ! -f "$PREFIX/lib/libnghttp2.a" ]; then
        rm -rf "nghttp2-${NGHTTP2_VERSION}"
        tar xJf "$SOURCES_DIR/nghttp2-${NGHTTP2_VERSION}.tar.xz"
        cd "nghttp2-${NGHTTP2_VERSION}"

        # Cross: without this, configure sets ac_cv_type_uid_t=no and emits
        # #define uid_t int / gid_t int into config.h; Apple SDK already typedefs
        # them → "cannot combine with previous 'type-name'".
        ac_cv_type_uid_t=yes \
            ./configure \
            --host="$HOST" \
            --prefix="$PREFIX" \
            --enable-static \
            --disable-shared \
            --enable-lib-only \
            CC="$CC" \
            CFLAGS="$CFLAGS" \
            LDFLAGS="$LDFLAGS" \
            AR="$AR" \
            RANLIB="$RANLIB"

        make -j$NJOBS
        make install
        log "nghttp2 done"
    else
        log "nghttp2 already built"
    fi
}

# --- libunistring (static; libidn2 dependency) ---
build_libunistring() {
    log "Building libunistring $LIBUNISTRING_VERSION"
    cd "$BUILD_DIR"
    download "https://ftp.gnu.org/gnu/libunistring/libunistring-${LIBUNISTRING_VERSION}.tar.gz" \
             "$SOURCES_DIR/libunistring-${LIBUNISTRING_VERSION}.tar.gz"

    if [ ! -f "$PREFIX/lib/libunistring.a" ]; then
        rm -rf "libunistring-${LIBUNISTRING_VERSION}"
        tar xzf "$SOURCES_DIR/libunistring-${LIBUNISTRING_VERSION}.tar.gz"
        cd "libunistring-${LIBUNISTRING_VERSION}"

        CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
        ./configure \
            --host="$HOST" \
            --prefix="$PREFIX" \
            --enable-static \
            --disable-shared \
            --disable-nls

        make -j$NJOBS
        make install
        log "libunistring done"
    else
        log "libunistring already built"
    fi
}

# --- libidn2 (static; libpsl / IDNA) ---
build_libidn2() {
    log "Building libidn2 $LIBIDN2_VERSION"
    cd "$BUILD_DIR"
    download "https://ftp.gnu.org/gnu/libidn/libidn2-${LIBIDN2_VERSION}.tar.gz" \
             "$SOURCES_DIR/libidn2-${LIBIDN2_VERSION}.tar.gz"

    if [ ! -f "$PREFIX/lib/libidn2.a" ]; then
        rm -rf "libidn2-${LIBIDN2_VERSION}"
        tar xzf "$SOURCES_DIR/libidn2-${LIBIDN2_VERSION}.tar.gz"
        cd "libidn2-${LIBIDN2_VERSION}"

        CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
        ./configure \
            --host="$HOST" \
            --prefix="$PREFIX" \
            --enable-static \
            --disable-shared \
            --disable-nls

        make -j$NJOBS
        make install
        log "libidn2 done"
    else
        log "libidn2 already built"
    fi
}

# --- libpsl (static; libsoup dependency) ---
build_libpsl() {
    log "Building libpsl $LIBPSL_VERSION"
    cd "$BUILD_DIR"
    download "https://github.com/rockdaboot/libpsl/releases/download/${LIBPSL_VERSION}/libpsl-${LIBPSL_VERSION}.tar.gz" \
             "$SOURCES_DIR/libpsl-${LIBPSL_VERSION}.tar.gz"

    if [ ! -f "$PREFIX/lib/libpsl.a" ]; then
        rm -rf "libpsl-${LIBPSL_VERSION}"
        tar xzf "$SOURCES_DIR/libpsl-${LIBPSL_VERSION}.tar.gz"
        cd "libpsl-${LIBPSL_VERSION}"

        # Embed PSL data; use libidn2 for IDNA (matches our stack).
        CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
        ./configure \
            --host="$HOST" \
            --prefix="$PREFIX" \
            --enable-static \
            --disable-shared \
            --disable-gtk-doc \
            --enable-builtin=libidn2

        make -j$NJOBS
        make install
        log "libpsl done"
    else
        log "libpsl already built"
    fi
}

# --- libsoup 3.x (static; TLS via glib-networking at runtime; 3.4.x has no tls_crypto meson option) ---
build_libsoup3() {
    log "Building libsoup $LIBSOUP_VERSION"
    cd "$BUILD_DIR"
    download_gnome_sources "libsoup/$(gnome_sources_minor_dir "$LIBSOUP_VERSION")/libsoup-${LIBSOUP_VERSION}.tar.xz" \
                           "$SOURCES_DIR/libsoup-${LIBSOUP_VERSION}.tar.xz"

    if [ ! -f "$PREFIX/lib/libsoup-3.0.a" ]; then
        rm -rf "libsoup-${LIBSOUP_VERSION}"
        tar xJf "$SOURCES_DIR/libsoup-${LIBSOUP_VERSION}.tar.xz"
        cd "libsoup-${LIBSOUP_VERSION}"

        cat > macos-cross-libsoup.ini <<CROSSEOF
[binaries]
c = '$CC'
objc = '$CC'
ar = '$AR'
strip = '$STRIP'
pkg-config = '$(which pkg-config)'
python = '${SPICE_HOST_PY}'

[built-in options]
c_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-I$PREFIX/include', '-I$PREFIX/include/glib-2.0', '-I$PREFIX/lib/glib-2.0/include', '-I$PREFIX/include/libxml2']
c_link_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-L$PREFIX/lib', '-lidn2', '-lunistring', '-framework', 'CoreFoundation']
objc_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-I$PREFIX/include', '-I$PREFIX/include/glib-2.0', '-I$PREFIX/lib/glib-2.0/include', '-I$PREFIX/include/libxml2']
objc_link_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-L$PREFIX/lib', '-lidn2', '-lunistring', '-framework', 'CoreFoundation']

[host_machine]
system = 'darwin'
subsystem = 'macos'
cpu_family = '$MESON_CPU_FAMILY'
cpu = '$MESON_CPU'
endian = 'little'
CROSSEOF

        meson setup _build \
            --cross-file=macos-cross-libsoup.ini \
            --prefix="$PREFIX" \
            --default-library=static \
            -Dtls_check=false \
            -Dntlm=disabled \
            -Dbrotli=disabled \
            -Ddocs=disabled \
            -Dvapi=disabled \
            -Dintrospection=disabled \
            -Dsysprof=disabled \
            -Dtests=false \
            -Dautobahn=disabled \
            -Dgssapi=disabled

        ninja -C _build -j$NJOBS
        ninja -C _build install
        log "libsoup done"
    else
        log "libsoup already built"
    fi
}

# --- phodav 3.x (static; SPICE clipboard WebDAV virtual tree) ---
download_phodav_source() {
    local minor rel xz bz2 base url
    minor=$(gnome_sources_minor_dir "$PHODAV_VERSION")
    rel="phodav/${minor}/phodav-${PHODAV_VERSION}.tar.xz"
    xz="$SOURCES_DIR/phodav-${PHODAV_VERSION}.tar.xz"
    bz2="$SOURCES_DIR/phodav-${PHODAV_VERSION}.tar.bz2"
    if [ -f "$xz" ] || [ -f "$bz2" ]; then
        return 0
    fi
    log "Downloading phodav-${PHODAV_VERSION}.tar.xz"
    rm -f "$xz" "$bz2"
    local bases=(
        "https://download.gnome.org/sources"
        "https://mirror.csclub.uwaterloo.ca/gnome/sources"
        "https://ftp.acc.umu.se/pub/GNOME/sources"
        "https://www.mirrorservice.org/sites/ftp.gnome.org/pub/GNOME/sources"
    )
    for base in "${bases[@]}"; do
        url="${base}/${rel}"
        if _curl_fetch_one_url "$xz" "$url"; then
            return 0
        fi
        log "WARN: fetch failed (${url}), trying next mirror..."
    done
    log "WARN: GNOME mirrors failed; trying GitLab archive (.tar.bz2)"
    if _curl_fetch_one_url "$bz2" "https://gitlab.gnome.org/GNOME/phodav/-/archive/${PHODAV_VERSION}/phodav-${PHODAV_VERSION}.tar.bz2"; then
        return 0
    fi
    log "ERROR: phodav download failed (GNOME + GitLab)"
    return 1
}

build_phodav3() {
    log "Building phodav $PHODAV_VERSION"
    cd "$BUILD_DIR"
    download_phodav_source || exit 1

    if [ ! -f "$PREFIX/lib/libphodav-3.0.a" ]; then
        rm -rf "phodav-${PHODAV_VERSION}"
        if [ -f "$SOURCES_DIR/phodav-${PHODAV_VERSION}.tar.xz" ]; then
            tar xJf "$SOURCES_DIR/phodav-${PHODAV_VERSION}.tar.xz"
        else
            tar xjf "$SOURCES_DIR/phodav-${PHODAV_VERSION}.tar.bz2"
        fi
        cd "phodav-${PHODAV_VERSION}"

        cat > macos-cross-phodav.ini <<CROSSEOF
[binaries]
c = '$CC'
objc = '$CC'
ar = '$AR'
strip = '$STRIP'
pkg-config = '$(which pkg-config)'
python = '${SPICE_HOST_PY}'

[built-in options]
c_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-I$PREFIX/include', '-I$PREFIX/include/glib-2.0', '-I$PREFIX/lib/glib-2.0/include', '-I$PREFIX/include/libxml2', '-I$PREFIX/include/libsoup-3.0']
c_link_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-L$PREFIX/lib', '-framework', 'CoreFoundation']
objc_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-I$PREFIX/include', '-I$PREFIX/include/glib-2.0', '-I$PREFIX/lib/glib-2.0/include', '-I$PREFIX/include/libxml2', '-I$PREFIX/include/libsoup-3.0']
objc_link_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-L$PREFIX/lib', '-framework', 'CoreFoundation']

[host_machine]
system = 'darwin'
subsystem = 'macos'
cpu_family = '$MESON_CPU_FAMILY'
cpu = '$MESON_CPU'
endian = 'little'
CROSSEOF

        meson setup _build \
            --cross-file=macos-cross-phodav.ini \
            --prefix="$PREFIX" \
            --default-library=static

        ninja -C _build -j$NJOBS
        ninja -C _build install
        log "phodav done"
    else
        log "phodav already built"
    fi
}

# --- spice-protocol (headers only) ---
build_spice_protocol() {
    log "Building spice-protocol $SPICE_PROTOCOL_VERSION"
    cd "$BUILD_DIR"
    download "https://gitlab.freedesktop.org/spice/spice-protocol/-/archive/v${SPICE_PROTOCOL_VERSION}/spice-protocol-v${SPICE_PROTOCOL_VERSION}.tar.gz" \
             "$SOURCES_DIR/spice-protocol-${SPICE_PROTOCOL_VERSION}.tar.gz"

    if [ ! -d "$PREFIX/include/spice-1" ]; then
        rm -rf spice-protocol-v${SPICE_PROTOCOL_VERSION}
        tar xzf "$SOURCES_DIR/spice-protocol-${SPICE_PROTOCOL_VERSION}.tar.gz"
        cd spice-protocol-v${SPICE_PROTOCOL_VERSION}

        meson setup _build \
            --prefix="$PREFIX"

        ninja -C _build install
        log "spice-protocol done"
    else
        log "spice-protocol already built"
    fi
}

# --- spice-gtk (client library only, no GTK) ---
build_spice_client() {
    log "Building spice-gtk $SPICE_GTK_VERSION (client-glib only)"
    cd "$BUILD_DIR"
    download "https://gitlab.freedesktop.org/spice/spice-gtk/-/archive/v${SPICE_GTK_VERSION}/spice-gtk-v${SPICE_GTK_VERSION}.tar.gz" \
             "$SOURCES_DIR/spice-gtk-${SPICE_GTK_VERSION}.tar.gz"

    local SPICE_COMMON_COMMIT="58d375e5eadc6fb9e587e99fd81adcb95d01e8d6"
    local KEYCODEMAPDB_COMMIT="14cdba29ecd7448310fe4ff890e67830b1a40f64"
    download "https://gitlab.freedesktop.org/spice/spice-common/-/archive/${SPICE_COMMON_COMMIT}/spice-common-${SPICE_COMMON_COMMIT}.tar.gz" \
             "$SOURCES_DIR/spice-common-${SPICE_COMMON_COMMIT}.tar.gz"
    download "https://gitlab.com/keycodemap/keycodemapdb/-/archive/${KEYCODEMAPDB_COMMIT}/keycodemapdb-${KEYCODEMAPDB_COMMIT}.tar.gz" \
             "$SOURCES_DIR/keycodemapdb-${KEYCODEMAPDB_COMMIT}.tar.gz"

    if [ ! -f "$PREFIX/lib/libspice-client-glib-2.0.a" ] || [ ! -f "$PREFIX/lib/.pvespice_spice_webdav_v1" ]; then
        rm -rf spice-gtk-v${SPICE_GTK_VERSION}
        tar xzf "$SOURCES_DIR/spice-gtk-${SPICE_GTK_VERSION}.tar.gz"
        cd spice-gtk-v${SPICE_GTK_VERSION}

        rm -rf subprojects/spice-common
        mkdir -p subprojects/spice-common
        tar xzf "$SOURCES_DIR/spice-common-${SPICE_COMMON_COMMIT}.tar.gz" \
            --strip-components=1 -C subprojects/spice-common

        rm -rf subprojects/keycodemapdb
        mkdir -p subprojects/keycodemapdb
        tar xzf "$SOURCES_DIR/keycodemapdb-${KEYCODEMAPDB_COMMIT}.tar.gz" \
            --strip-components=1 -C subprojects/keycodemapdb

        # spice-common Meson runs Python codegen (needs six, pyparsing). Homebrew python3 is
        # PEP 668 "externally managed" — pip install to system fails. Use a dedicated venv.
        SPICE_HOST_PY="${MESON_HOST_PYTHON:-$(command -v python3)}"
        if [ -z "$SPICE_HOST_PY" ] || [ ! -x "$SPICE_HOST_PY" ]; then
            log "ERROR: python3 not found (spice-common needs pyparsing). Set MESON_HOST_PYTHON if needed."
            exit 1
        fi
        if ! "$SPICE_HOST_PY" -c 'import six, pyparsing' 2>/dev/null; then
            SPICE_CODEGEN_VENV="$BUILD_DIR/spice-codegen-venv"
            log "Creating Python venv for spice-common at $SPICE_CODEGEN_VENV (six, pyparsing)"
            if ! command -v python3 >/dev/null 2>&1; then
                log "ERROR: python3 not on PATH (cannot create venv)"
                exit 1
            fi
            if [ ! -x "$SPICE_CODEGEN_VENV/bin/python3" ]; then
                python3 -m venv "$SPICE_CODEGEN_VENV" || {
                    log "ERROR: python3 -m venv failed (install python with venv support)"
                    exit 1
                }
            fi
            "$SPICE_CODEGEN_VENV/bin/pip" install -q --upgrade pip
            "$SPICE_CODEGEN_VENV/bin/pip" install -q six pyparsing || {
                log "ERROR: pip install six pyparsing failed in $SPICE_CODEGEN_VENV"
                exit 1
            }
            SPICE_HOST_PY="$SPICE_CODEGEN_VENV/bin/python3"
        fi
        if ! "$SPICE_HOST_PY" -c 'import six, pyparsing' 2>/dev/null; then
            log "ERROR: Python modules six/pyparsing still missing ($SPICE_HOST_PY)."
            exit 1
        fi

        # Patch 1: make GStreamer deps optional
        python3 - << 'PYEOF'
import re, sys
with open('meson.build') as f:
    content = f.read()
pattern = r"gstreamer_version = '1\.10'.*?endforeach"
replacement = (
    "spice_glib_has_gstreamer = false\n"
    "_gst_probe = dependency('gstreamer-1.0', required: false)\n"
    "if _gst_probe.found()\n"
    "  foreach dep : ['gstreamer-1.0', 'gstreamer-base-1.0', 'gstreamer-app-1.0', 'gstreamer-audio-1.0', 'gstreamer-video-1.0']\n"
    "    spice_glib_deps += dependency(dep, version: '>= 1.10')\n"
    "  endforeach\n"
    "  spice_glib_has_gstreamer = true\n"
    "  spice_gtk_config_data.set('HAVE_GSTREAMER', '1')\n"
    "endif"
)
new, n = re.subn(pattern, replacement, content, flags=re.DOTALL)
assert n == 1, f"Expected 1 GStreamer block replacement, got {n}"
with open('meson.build', 'w') as f:
    f.write(new)
print("meson.build: GStreamer is now optional")
PYEOF

        # Patch 2: make channel-display-gst.c conditional
        python3 - << 'PYEOF'
with open('src/meson.build') as f:
    content = f.read()
content = content.replace("  'channel-display-gst.c',\n", "")
marker = "spice_client_glib_lib = library("
conditional = (
    "if spice_glib_has_gstreamer\n"
    "  spice_client_glib_sources += files('channel-display-gst.c')\n"
    "else\n"
    "  spice_client_glib_sources += files('channel-display-vtb.c')\n"
    "endif\n"
)
assert marker in content, "library() call not found in src/meson.build"
content = content.replace(marker, conditional + marker, 1)
with open('src/meson.build', 'w') as f:
    f.write(content)
print("src/meson.build: channel-display-gst.c is now conditional")
PYEOF

        # Patch 3: guard GStreamer-specific include/decl in channel-display-priv.h
        python3 - << 'PYEOF'
with open('src/channel-display-priv.h') as f:
    content = f.read()
content = content.replace(
    '#include <gst/gst.h>',
    '#ifdef HAVE_GSTREAMER\n#include <gst/gst.h>\n#endif'
)
content = content.replace(
    'gboolean hand_pipeline_to_widget(display_stream *st,  GstPipeline *pipeline);',
    '#ifdef HAVE_GSTREAMER\ngboolean hand_pipeline_to_widget(display_stream *st,  GstPipeline *pipeline);\n#endif'
)
with open('src/channel-display-priv.h', 'w') as f:
    f.write(content)
print("channel-display-priv.h: GStreamer guarded")
PYEOF

        # Patch 4: guard GStreamer-specific code in channel-display.c
        python3 - << 'PYEOF'
with open('src/channel-display.c') as f:
    content = f.read()

old_sig = (
    "    signals[SPICE_DISPLAY_OVERLAY] =\n"
    "        g_signal_new(\"gst-video-overlay\",\n"
)
sig_start = content.index(old_sig)
sig_end = content.index("GST_TYPE_PIPELINE);", sig_start) + len("GST_TYPE_PIPELINE);")
content = (content[:sig_start] +
           "#ifdef HAVE_GSTREAMER\n" +
           content[sig_start:sig_end] + "\n#endif" +
           content[sig_end:])

old_func = (
    "G_GNUC_INTERNAL\n"
    "gboolean hand_pipeline_to_widget(display_stream *st, GstPipeline *pipeline)\n"
)
new_func = (
    "#ifdef HAVE_GSTREAMER\n"
    "G_GNUC_INTERNAL\n"
    "gboolean hand_pipeline_to_widget(display_stream *st, GstPipeline *pipeline)\n"
)
assert old_func in content, "hand_pipeline_to_widget not found in channel-display.c"
idx = content.index(old_func)
brace_idx = content.index('{', idx + len(old_func))
depth = 1
brace_idx += 1
while depth > 0:
    c = content[brace_idx]
    if c == '{': depth += 1
    elif c == '}': depth -= 1
    brace_idx += 1
content = (content[:idx] + new_func +
           content[idx+len(old_func):brace_idx] + "\n#endif\n" +
           content[brace_idx:])

with open('src/channel-display.c', 'w') as f:
    f.write(content)
print("channel-display.c: hand_pipeline_to_widget guarded")
PYEOF

        # Patch 5: install VideoToolbox H.264/H.265 decoder
        cp "$SCRIPT_DIR/channel-display-vtb.c" src/channel-display-vtb.c
        echo "Installed VideoToolbox decoder"

        # Patch 6: wrap spice-gstaudio.c in HAVE_GSTREAMER guard
        {
            printf '#include "config.h"\n#ifdef HAVE_GSTREAMER\n'
            cat src/spice-gstaudio.c
            printf '\n#endif /* HAVE_GSTREAMER */\n'
        } > src/spice-gstaudio.c.new
        mv src/spice-gstaudio.c.new src/spice-gstaudio.c
        echo "spice-gstaudio.c: wrapped in HAVE_GSTREAMER guard"

        # Patch 6b: guard GStreamer audio header and call in spice-audio.c
        python3 - << 'PYEOF'
with open('src/spice-audio.c') as f:
    content = f.read()

content = content.replace(
    '#include "spice-gstaudio.h"',
    '#ifdef HAVE_GSTREAMER\n#include "spice-gstaudio.h"\n#endif'
)

old_block = (
    '    self = SPICE_AUDIO(spice_gstaudio_new(session, context, name));\n'
    '    if (self != NULL) {\n'
    '        spice_g_signal_connect_object(session, "notify::enable-audio", G_CALLBACK(session_enable_audio), self, 0);\n'
    '        spice_g_signal_connect_object(session, "channel-new", G_CALLBACK(channel_new), self, G_CONNECT_AFTER);\n'
    '        update_audio_channels(self, session);\n'
    '    }\n'
)
new_block = (
    '#ifdef HAVE_GSTREAMER\n'
    '    self = SPICE_AUDIO(spice_gstaudio_new(session, context, name));\n'
    '    if (self != NULL) {\n'
    '        spice_g_signal_connect_object(session, "notify::enable-audio", G_CALLBACK(session_enable_audio), self, 0);\n'
    '        spice_g_signal_connect_object(session, "channel-new", G_CALLBACK(channel_new), self, G_CONNECT_AFTER);\n'
    '        update_audio_channels(self, session);\n'
    '    }\n'
    '#endif\n'
)
assert old_block in content, "spice_gstaudio_new block not found in spice-audio.c"
content = content.replace(old_block, new_block, 1)

with open('src/spice-audio.c', 'w') as f:
    f.write(content)
print("spice-audio.c: GStreamer audio guarded")
PYEOF

        # Patch 7: add missing standard headers before jpeglib.h
        python3 - << 'PYEOF'
with open('src/channel-display-priv.h') as f:
    content = f.read()
content = content.replace(
    '#include <jpeglib.h>',
    '#include <stdio.h>\n#include <stddef.h>\n#include <stdbool.h>\n#include <jpeglib.h>'
)
with open('src/channel-display-priv.h', 'w') as f:
    f.write(content)
print("channel-display-priv.h: added stdio.h/stddef.h/stdbool.h before jpeglib.h")
PYEOF

        # Patch 8: guard hand_pipeline_to_widget call in channel-display-mjpeg.c
        python3 - << 'PYEOF'
with open('src/channel-display-mjpeg.c') as f:
    content = f.read()
old = '    hand_pipeline_to_widget(stream, NULL);\n'
new = '#ifdef HAVE_GSTREAMER\n    hand_pipeline_to_widget(stream, NULL);\n#endif\n'
assert old in content, "hand_pipeline_to_widget call not found in channel-display-mjpeg.c"
content = content.replace(old, new, 1)
with open('src/channel-display-mjpeg.c', 'w') as f:
    f.write(content)
print("channel-display-mjpeg.c: guarded hand_pipeline_to_widget call")
PYEOF

        cat > macos-cross.ini <<CROSSEOF
[binaries]
c = '$CC'
objc = '$CC'
ar = '$AR'
strip = '$STRIP'
pkg-config = '$(which pkg-config)'
python = '${SPICE_HOST_PY}'

[built-in options]
c_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-I$PREFIX/include', '-I$PREFIX/include/glib-2.0', '-I$PREFIX/lib/glib-2.0/include', '-I$PREFIX/include/json-glib-1.0', '-I$PREFIX/include/spice-1', '-I$PREFIX/include/pixman-1', '-I$PREFIX/include/libxml2', '-I$PREFIX/include/libsoup-3.0', '-I$PREFIX/include/libphodav-3.0', '-DHAVE_SPICE']
c_link_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-L$PREFIX/lib', '-framework', 'CoreFoundation', '-framework', 'CoreMedia', '-framework', 'CoreVideo', '-framework', 'VideoToolbox']
objc_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-I$PREFIX/include', '-I$PREFIX/include/glib-2.0', '-I$PREFIX/lib/glib-2.0/include', '-I$PREFIX/include/json-glib-1.0', '-I$PREFIX/include/spice-1', '-I$PREFIX/include/pixman-1', '-I$PREFIX/include/libxml2', '-I$PREFIX/include/libsoup-3.0', '-I$PREFIX/include/libphodav-3.0', '-DHAVE_SPICE']
objc_link_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-L$PREFIX/lib', '-framework', 'CoreFoundation', '-framework', 'CoreMedia', '-framework', 'CoreVideo', '-framework', 'VideoToolbox']

[host_machine]
system = 'darwin'
subsystem = 'macos'
cpu_family = '$MESON_CPU_FAMILY'
cpu = '$MESON_CPU'
endian = 'little'
CROSSEOF

        meson setup _build \
            --cross-file=macos-cross.ini \
            --prefix="$PREFIX" \
            --default-library=static \
            -Dgtk=disabled \
            -Dwebdav=enabled \
            -Dusbredir=disabled \
            -Dpolkit=disabled \
            -Dlz4=disabled \
            -Dsasl=disabled \
            -Dsmartcard=disabled \
            -Dcoroutine=gthread \
            -Dvapi=disabled \
            -Dgtk_doc=disabled \
            -Dintrospection=disabled \
            -Dopus=enabled \
            -Dspice-common:tests=false

        ninja -C _build -j$NJOBS src/libspice-client-glib-2.0.a
        ninja -C _build install 2>/dev/null || \
            cp _build/src/libspice-client-glib-2.0.a "$PREFIX/lib/"
        touch "$PREFIX/lib/.pvespice_spice_webdav_v1"
        log "spice-gtk done"
    else
        log "spice-gtk already built"
    fi
}

# ============================================================================
# Build order (respecting dependencies)
# ============================================================================

log "Starting native macOS arm64 dependency build (min macOS ${MACOS_MIN})"
log "Target triple: $TARGET_TRIPLE"
log "Build directory: $BUILD_DIR"
log "Install prefix: $PREFIX"
log "macOS SDK: $SDKROOT"

build_openssl
build_libffi
build_glib        # depends on: libffi
build_pixman
build_opus
build_libjpeg
build_json_glib   # depends on: glib
build_libxml2
build_sqlite3
build_nghttp2
build_libunistring
build_libidn2
build_libpsl
build_libsoup3
build_phodav3
build_spice_protocol
build_spice_client # depends on: all of the above (webdav → libphodav + libsoup)

log "All dependencies built successfully!"
log "Static libraries in: $PREFIX/lib/"
log "Headers in: $PREFIX/include/"

echo ""
echo "Built libraries:"
ls -la "$PREFIX/lib/"*.a 2>/dev/null || echo "  (none found)"
