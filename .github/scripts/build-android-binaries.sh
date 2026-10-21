#!/usr/bin/env bash
# ==============================================================================
# build-android-binaries.sh
#
# Compiles nfqws2 for Android architectures:
#   - android-arm    (armeabi-v7a, 32-bit ARM, thumb, API 21+)
#   - android-arm64  (arm64-v8a, 64-bit ARM, 16 KB page-size, API 21+)
#   - android-x86    (x86, 32-bit x86, API 21+)
#   - android-x86_64 (x86_64, 64-bit x86_64, 16 KB page-size, API 21+)
#
# Incorporates Android specifics:
#   1. Clang cross-compilation via Android NDK (API level 21).
#   2. Static linking of netfilter libs (libmnl, libnfnetlink, libnetfilter_queue).
#   3. Static linking of LuaJIT (openresty/luajit2).
#   4. Android bionic compatibility shims (getifaddrs shim, -llog).
#   5. Netfilter queue bionic header fix (libnetfilter_queue-android.patch).
#   6. Hardware fastpath TLS reassembly fix from nfqws2-keenetic (001-tls-reasm-fastpath.patch).
#   7. 16 KB page size alignment (-Wl,-z,max-page-size=16384) for Android 15+.
#   8. DT cleaning with termux-elf-cleaner to prevent legacy Android linker warnings.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
PATCHES_DIR="$REPO_DIR/.github/patches"

TARGET_ABI="${1:-all}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_DIR}"

ZAPRET2_REPO="${ZAPRET2_REPO:-https://github.com/bol-van/zapret2.git}"
ZAPRET2_TAG="${ZAPRET2_TAG:-v1.0.6}"
ZAPRET2_SHA="${ZAPRET2_SHA:-221d7dff24bfec0cd5ac0a5070b8acef2008af3d}" # v1.0.6

LUAJIT_RELEASE="${LUAJIT_RELEASE:-2.1-20250826}"
LUAJIT_VER="2.1"
LUAJIT_LUAVER="5.1"
LUAJIT_SHA256="5a49743ad6ce4b7f19aac71b55a08052c1feb62750f051982082c12bf62f39c0"

LIBMNL_VER="1.0.5"
LIBMNL_SHA256="274b9b919ef3152bfb3da3a13c950dd60d6e2bcd54230ffeca298d03b40d0525"
LIBNFNETLINK_VER="1.0.2"
LIBNFNETLINK_SHA256="b064c7c3d426efb4786e60a8e6859b82ee2f2c5e49ffeea640cfe4fe33cbc376"
LIBNETFILTER_QUEUE_VER="1.0.5"
LIBNETFILTER_QUEUE_SHA256="f9ff3c11305d6e03d81405957bdc11aea18e0d315c3e3f48da53a24ba251b9f5"

ELF_CLEANER_VER="${ELF_CLEANER_VER:-v3.0.1}"
ELF_CLEANER_SHA256="59645fb25b84d11f108436e83d9df5e874ba4eb76ab62948869a23a3ee692fa7"

API="21"

# ── 1. Locate Android NDK ─────────────────────────────────────────────────────
find_ndk() {
  if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64" ]; then
    echo "$ANDROID_NDK_HOME"
    return 0
  fi
  if [ -n "${ANDROID_NDK_LATEST_HOME:-}" ] && [ -d "$ANDROID_NDK_LATEST_HOME/toolchains/llvm/prebuilt/linux-x86_64" ]; then
    echo "$ANDROID_NDK_LATEST_HOME"
    return 0
  fi
  for cand in \
    "${ANDROID_SDK_ROOT:-/opt/android-sdk}/ndk"/* \
    "/usr/local/lib/android/sdk/ndk"/* \
    "$HOME/Android/Sdk/ndk"/*; do
    if [ -d "$cand/toolchains/llvm/prebuilt/linux-x86_64" ]; then
      echo "$cand"
      return 0
    fi
  done
  return 1
}

NDK_DIR=$(find_ndk) || {
  echo "::error::Android NDK not found! Set ANDROID_NDK_HOME." >&2
  exit 1
}
echo "==> Using Android NDK: $NDK_DIR"
TOOLCHAIN="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64"

# ── 2. Download and prepare termux-elf-cleaner ────────────────────────────────
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nfqws2-build.XXXXXX")
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

fetch_verified() { # <url> <dest> <sha256>
  curl -sSLf -o "$2" "$1"
  printf '%s  %s\n' "$3" "$2" | sha256sum -c -
}

ELF_CLEANER="$WORK_DIR/elf-cleaner"
if command -v termux-elf-cleaner >/dev/null 2>&1; then
  ELF_CLEANER=$(command -v termux-elf-cleaner)
else
  echo "==> Downloading termux-elf-cleaner $ELF_CLEANER_VER..."
  fetch_verified \
    "https://github.com/termux/termux-elf-cleaner/releases/download/${ELF_CLEANER_VER}/termux-elf-cleaner" \
    "$ELF_CLEANER" "$ELF_CLEANER_SHA256"
  chmod +x "$ELF_CLEANER"
fi

# ── 3. Source archives cache ──────────────────────────────────────────────────
SRC_CACHE="$WORK_DIR/sources"
mkdir -p "$SRC_CACHE"

echo "==> Fetching third-party dependency source tarballs..."
fetch_verified "https://github.com/openresty/luajit2/archive/refs/tags/v${LUAJIT_RELEASE}.tar.gz" \
  "$SRC_CACHE/luajit2.tar.gz" "$LUAJIT_SHA256"
fetch_verified "https://www.netfilter.org/pub/libmnl/libmnl-${LIBMNL_VER}.tar.bz2" \
  "$SRC_CACHE/libmnl.tar.bz2" "$LIBMNL_SHA256"
fetch_verified "https://www.netfilter.org/pub/libnfnetlink/libnfnetlink-${LIBNFNETLINK_VER}.tar.bz2" \
  "$SRC_CACHE/libnfnetlink.tar.bz2" "$LIBNFNETLINK_SHA256"
fetch_verified "https://www.netfilter.org/pub/libnetfilter_queue/libnetfilter_queue-${LIBNETFILTER_QUEUE_VER}.tar.bz2" \
  "$SRC_CACHE/libnetfilter_queue.tar.bz2" "$LIBNETFILTER_QUEUE_SHA256"

echo "==> Fetching zapret2 $ZAPRET2_SHA (tag $ZAPRET2_TAG)..."
git init -q "$SRC_CACHE/zapret2"
git -C "$SRC_CACHE/zapret2" fetch -q --depth 1 "$ZAPRET2_REPO" "$ZAPRET2_SHA"
git -C "$SRC_CACHE/zapret2" checkout -q FETCH_HEAD

echo "==> Applying nfqws2-keenetic 001-tls-reasm-fastpath.patch..."
patch --batch --fuzz=0 -p1 -d "$SRC_CACHE/zapret2" < "$PATCHES_DIR/001-tls-reasm-fastpath.patch"

# ── 4. Architecture build function ───────────────────────────────────────────
READELF="$TOOLCHAIN/bin/llvm-readelf"
[ -x "$READELF" ] || READELF=$(command -v readelf)
[ -n "$READELF" ] || { echo "::error::readelf not found" >&2; exit 1; }

verify_binary() { # <abi> <file>
  local abi="$1" f="$2" machine want
  # LC_ALL=C: readelf localizes section names, which breaks these matches
  machine=$(LC_ALL=C "$READELF" -h "$f" | sed -n 's/^ *Machine: *//p')
  case "$abi" in
    android-arm) want="ARM" ;;
    android-arm64) want="AArch64" ;;
    android-x86) want="Intel 80386" ;;
    android-x86_64) want="Advanced Micro Devices X86-64" ;;
  esac
  [ "${machine#"$want"}" != "$machine" ] || {
    echo "::error::[$abi] wrong architecture: $machine" >&2; exit 1; }

  case "$abi" in
    android-arm64|android-x86_64)
      local align bad=0
      while read -r align; do
        [ "$((align))" -ge 16384 ] || bad=1
      done < <(LC_ALL=C "$READELF" -lW "$f" | awk '/^ *LOAD/ { print $NF }')
      [ "$bad" = 0 ] || { echo "::error::[$abi] LOAD alignment below 16 KB" >&2; exit 1; }
      ;;
  esac

  local need extra=""
  while read -r need; do
    case "$need" in
      libc.so|libm.so|libdl.so|liblog.so|libz.so) ;;
      *) extra="$extra${extra:+, }$need" ;;
    esac
  done < <(LC_ALL=C "$READELF" -d "$f" | sed -n 's/^ *0x[0-9a-f]* *(NEEDED) *Shared library: \[\(.*\)\]$/\1/p')
  [ -z "$extra" ] || { echo "::error::[$abi] unexpected NEEDED libraries: $extra" >&2; exit 1; }

  LC_ALL=C grep -qa -- "fastpath-workaround" "$f" || {
    echo "::error::[$abi] fastpath-workaround missing from the binary; the 001 patch did not land" >&2; exit 1; }
  echo "--- [$abi] verification passed (arch, alignment, deps, patch)"
}

build_single_abi() {
  local abi="$1"
  local target=""
  local cpu=""
  local sysmalloc=""
  local hostcc=""
  local pagesize=""

  case "$abi" in
    android-arm|armeabi-v7a)
      abi="android-arm"
      target="armv7a-linux-androideabi"
      cpu="-mthumb"
      sysmalloc="-DLUAJIT_USE_SYSMALLOC"
      hostcc="cc -m32"
      pagesize=""
      ;;
    android-arm64|arm64-v8a)
      abi="android-arm64"
      target="aarch64-linux-android"
      cpu=""
      sysmalloc=""
      hostcc="cc"
      # Android 15 compatibility: 16 KB max page size
      pagesize="-Wl,-z,max-page-size=16384"
      ;;
    android-x86|x86)
      abi="android-x86"
      target="i686-linux-android"
      cpu=""
      sysmalloc="-DLUAJIT_USE_SYSMALLOC"
      hostcc="cc -m32"
      pagesize=""
      ;;
    android-x86_64|x86_64)
      abi="android-x86_64"
      target="x86_64-linux-android"
      cpu=""
      sysmalloc=""
      hostcc="cc"
      pagesize="-Wl,-z,max-page-size=16384"
      ;;
    *)
      echo "::error::Unknown ABI: $abi" >&2
      exit 1
      ;;
  esac

  echo "===================================================================="
  echo "Building nfqws2 for $abi (target=$target, API=$API)..."
  echo "===================================================================="

  local build_dir="$WORK_DIR/build-$abi"
  local deps_dir="$build_dir/deps"
  mkdir -p "$deps_dir/include" "$deps_dir/lib" "$deps_dir/lib/pkgconfig"

  local CC="$TOOLCHAIN/bin/clang --target=${target}${API}"
  local AR="$TOOLCHAIN/bin/llvm-ar"
  local AS="$CC"
  local LD="$TOOLCHAIN/bin/ld"
  local RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
  local STRIP="$TOOLCHAIN/bin/llvm-strip"
  local MINSIZE="-Oz -flto=auto -ffunction-sections -fdata-sections"
  local LDMINSIZE="-Wl,--gc-sections -flto=auto"

  # A) Build LuaJIT
  echo "--- [$abi] Building LuaJIT ---"
  local luajit_src="$build_dir/luajit2"
  mkdir -p "$luajit_src"
  tar -xzf "$SRC_CACHE/luajit2.tar.gz" -C "$luajit_src" --strip-components=1
  (
    cd "$luajit_src"
    make BUILDMODE=static XCFLAGS="$sysmalloc -DLUAJIT_DISABLE_FFI" \
         HOST_CC="$hostcc" CROSS="" CC="$CC" TARGET_AR="$AR rcus" \
         TARGET_STRIP="$STRIP" TARGET_CFLAGS="$cpu $MINSIZE" \
         TARGET_LDFLAGS="$LDMINSIZE" -j"$(nproc)"
    make install PREFIX="" DESTDIR="$deps_dir"
  )

  # B) Build Netfilter libraries (libmnl, libnfnetlink, libnetfilter_queue)
  echo "--- [$abi] Building netfilter libraries ---"
  local nf_libs=("libmnl" "libnfnetlink" "libnetfilter_queue")
  for lib in "${nf_libs[@]}"; do
    local lib_src="$build_dir/$lib"
    mkdir -p "$lib_src"
    tar -xjf "$SRC_CACHE/$lib.tar.bz2" -C "$lib_src" --strip-components=1
    if [ "$lib" = "libnetfilter_queue" ] && [ -f "$PATCHES_DIR/libnetfilter_queue-android.patch" ]; then
      patch -p1 -d "$lib_src" < "$PATCHES_DIR/libnetfilter_queue-android.patch"
    fi
    (
      cd "$lib_src"
      CC="$CC" AR="$AR" RANLIB="$RANLIB" LD="$LD" \
      CFLAGS="$cpu $MINSIZE -Wno-implicit-function-declaration -I$deps_dir/include" \
      LDFLAGS="$LDMINSIZE -L$deps_dir/lib" \
      PKG_CONFIG_PATH="$deps_dir/lib/pkgconfig" \
      ./configure --prefix="" --host="$target" --enable-static --disable-shared --disable-dependency-tracking
      make install -j"$(nproc)" DESTDIR="$deps_dir"
    )
    if [ -f "$deps_dir/lib/pkgconfig/$lib.pc" ]; then
      sed -i "s|^prefix=.*|prefix=$deps_dir|g" "$deps_dir/lib/pkgconfig/$lib.pc"
    fi
  done

  # C) Build zapret2 nfqws2
  echo "--- [$abi] Building nfqws2 binary ---"
  local zapret_src="$build_dir/zapret2"
  cp -a "$SRC_CACHE/zapret2" "$zapret_src"
  (
    cd "$zapret_src/nfq2"
    CC="$CC" AR="$AR" RANLIB="$RANLIB" STRIP="$STRIP" \
    CFLAGS="-I$deps_dir/include $cpu $MINSIZE -Wno-implicit-function-declaration" \
    LDFLAGS="-L$deps_dir/lib $LDMINSIZE $pagesize" \
    make LUA_JIT=1 OPTIMIZE=-Oz \
         LUA_CFLAGS="-I$deps_dir/include/luajit-$LUAJIT_VER" \
         LUA_LIB="-L$deps_dir/lib -lluajit-$LUAJIT_LUAVER" \
         -j"$(nproc)" android
  )

  local built_bin="$zapret_src/nfq2/nfqws2"
  [ -f "$built_bin" ] || {
    echo "::error::nfqws2 failed to compile for $abi!" >&2
    exit 1
  }

  # D) Clean ELF binary
  if [ -n "$ELF_CLEANER" ] && [ -x "$ELF_CLEANER" ]; then
    echo "--- [$abi] Running termux-elf-cleaner ---"
    "$ELF_CLEANER" --api-level "$API" "$built_bin" || true
  fi

  # verify the exact file that will be shipped
  verify_binary "$abi" "$built_bin"

  # E) Copy to destination
  local dest_dir="$OUTPUT_DIR/binaries/$abi"
  mkdir -p "$dest_dir"
  cp -f "$built_bin" "$dest_dir/nfqws2"
  chmod 755 "$dest_dir/nfqws2"

  echo "==> Successfully built $abi nfqws2: $dest_dir/nfqws2 ($(wc -c < "$dest_dir/nfqws2") bytes)"
}

# ── 5. Main Dispatch ──────────────────────────────────────────────────────────
if [ "$TARGET_ABI" = "all" ]; then
  for a in android-arm android-arm64 android-x86 android-x86_64; do
    build_single_abi "$a"
  done
else
  build_single_abi "$TARGET_ABI"
fi

echo "===================================================================="
echo "Build complete! All binaries placed in $OUTPUT_DIR/binaries/"
echo "===================================================================="
