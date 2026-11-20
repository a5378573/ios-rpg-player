#!/bin/sh
# 拉取 mkxp 引擎（RPG Maker XP / VX / VX Ace）的 iOS 静态库。
#
# 不自己编译 Ruby：上游 mateo-m/mkxp-z-apple-mobile 的 CI 已经把
# 「引擎核心 + 三个 Ruby 版本的 binding + 全部依赖库」打成 v24 包，
# ANGLE（OpenGL ES on Metal）单独发布在 mateo-m/empo-deps。
# 本脚本只负责下载、校验 sha256、解压到 Vendor/。
#
# 用法：
#   Scripts/fetch_engine.sh            # 首次拉取，已拉取则跳过
#   Scripts/fetch_engine.sh --force    # 强制重下
#
# 产物：
#   Vendor/mkxp/            MANIFEST LINK include/ assets/ iphoneos/ iphonesimulator/
#   Vendor/angle/           iphoneos/{lib,include} iphonesimulator/{lib,include}
#   Vendor/.fetched-pin     记录版本，避免重复下载

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"

ENGINE_REPO="mateo-m/mkxp-z-apple-mobile"
ENGINE_VERSION="v24"
ENGINE_ASSET="mkxp-z-ios.tar.gz"
ENGINE_SHA256="2ca3b5b0eb003b8af1a5b5323e0d924663dbc4c631733b045778ab9310c96866"

ANGLE_REPO="mateo-m/empo-deps"
ANGLE_VERSION="angle-2026-11-19"
ANGLE_ASSET="angle-apple-prebuilt.tar.gz"
ANGLE_SHA256="89077b8af161d026da2400f91459d16aac4789db5b69bf5b515104dc4c765460"

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    *) echo "fetch_engine: 未知参数 $arg" >&2; exit 2 ;;
  esac
done

# sha256 工具在不同系统上叫法不同。
# GNU coreutils 在文件名含反斜杠时会用 "\<hash>" 转义输出，
# 这里统一只取前 64 位十六进制。
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | sed 's/^\\//' | cut -c1-64 | tr -d '\r'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -c1-64 | tr -d '\r'
  else
    python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
  fi
}

PIN="$ENGINE_VERSION $ENGINE_SHA256 $ANGLE_VERSION $ANGLE_SHA256"

if [ "$FORCE" = "0" ] && [ -f "$VENDOR/.fetched-pin" ] \
   && [ "$(cat "$VENDOR/.fetched-pin")" = "$PIN" ] \
   && [ -f "$VENDOR/mkxp/include/app_bridge.h" ] \
   && [ -f "$VENDOR/mkxp/iphoneos/lib/libmkxpz-core.a" ] \
   && [ -f "$VENDOR/angle/iphoneos/lib/libANGLE_static.a" ]; then
  echo "==> 引擎已就绪（$ENGINE_VERSION / $ANGLE_VERSION），跳过下载"
  exit 0
fi

mkdir -p "$VENDOR"
# 工作目录放在项目内：有些环境（Git Bash / 沙箱）的 TMPDIR 是 Windows 反斜杠路径，
# 会让 tar / rm 解析失败。
WORK="$ROOT/.build/engine-download"
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT INT TERM

download() {
  # $1 = url, $2 = 目标文件, $3 = 期望 sha256, $4 = 名称
  url="$1"; dest="$2"; want="$3"; name="$4"
  echo "==> 下载 $name"
  if ! curl -fL --retry 3 --retry-delay 2 -o "$dest" "$url"; then
    echo "fetch_engine: 下载失败：$url" >&2
    echo "  提示：GitHub 直连不稳时可设置代理，或手动下载后放到 $dest" >&2
    exit 1
  fi
  got="$(sha256_of "$dest")"
  if [ "$got" != "$want" ]; then
    echo "fetch_engine: $name 校验失败" >&2
    echo "  期望 $want" >&2
    echo "  实际 $got" >&2
    exit 1
  fi
}

download \
  "https://github.com/$ENGINE_REPO/releases/download/$ENGINE_VERSION/$ENGINE_ASSET" \
  "$WORK/$ENGINE_ASSET" "$ENGINE_SHA256" "mkxp 引擎 $ENGINE_VERSION"

download \
  "https://github.com/$ANGLE_REPO/releases/download/$ANGLE_VERSION/$ANGLE_ASSET" \
  "$WORK/$ANGLE_ASSET" "$ANGLE_SHA256" "ANGLE $ANGLE_VERSION"

echo "==> 解压"
mkdir -p "$WORK/mkxp" "$WORK/angle"
tar -xzf "$WORK/$ENGINE_ASSET" -C "$WORK/mkxp"
tar -xzf "$WORK/$ANGLE_ASSET" -C "$WORK/angle"

# 引擎包必须自带这些，否则说明上游包结构变了
for need in MANIFEST LINK include/app_bridge.h iphoneos/lib/libmkxpz-core.a \
            iphoneos/lib/mkxp31-merged.o iphoneos/ruby-stdlib assets/Shaders; do
  if [ ! -e "$WORK/mkxp/$need" ]; then
    echo "fetch_engine: 引擎包缺少 $need，上游结构可能已变" >&2
    exit 1
  fi
done

if [ ! -f "$WORK/angle/iphoneos/lib/libANGLE_static.a" ]; then
  echo "fetch_engine: ANGLE 包缺少 iphoneos/lib/libANGLE_static.a" >&2
  exit 1
fi

rm -rf "$VENDOR/mkxp" "$VENDOR/angle"
mv "$WORK/mkxp" "$VENDOR/mkxp"
mv "$WORK/angle" "$VENDOR/angle"
printf '%s\n' "$PIN" > "$VENDOR/.fetched-pin"

printf '\n==> 完成\n'
printf '  引擎版本   %s\n' "$(sed -n 's/^tag=//p' "$VENDOR/mkxp/MANIFEST")"
printf '  提交       %s\n' "$(sed -n 's/^commit=//p' "$VENDOR/mkxp/MANIFEST")"
printf '  ANGLE      %s\n' "$(sed -n 's/^angle=//p' "$VENDOR/mkxp/MANIFEST")"
printf '  RGSS 掩码  %s （7 = XP/VX/VX Ace 全支持）\n' "$(sed -n 's/^rgss_mask=//p' "$VENDOR/mkxp/MANIFEST")"
printf '  静态库     %s 个\n' "$(ls "$VENDOR/mkxp/iphoneos/lib" | wc -l | tr -d ' ')"
printf '\n下一步：xcodegen generate --spec project.yml\n'
