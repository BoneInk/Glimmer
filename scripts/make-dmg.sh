#!/bin/bash
# =============================================================================
# Glimmer — DMG 打包脚本（F21「发布 App 与 DMG」）
#
# build-app.sh --dmg 会在构建完成后自动调用本脚本；也可独立运行：
#   scripts/build-app.sh --dmg       # 编译 + 打包 + 生成 DMG
#   scripts/make-dmg.sh              # 只打包现有 build/Glimmer.app
#
# 产物（默认输出到仓库 dist/）:
#   Glimmer-<版本>-<架构>.dmg            压缩磁盘映像（拖入 Applications 安装）
#   Glimmer-<版本>-<架构>.dmg.sha256     SHA-256 校验文件
#   Glimmer-<版本>-<架构>.manifest.json  版本/架构/签名状态/校验清单
#
# 用法: scripts/make-dmg.sh [选项]
#   --app <路径>                输入 .app（默认 <仓库>/build/Glimmer.app）
#   --out <目录>                输出目录（默认 <仓库>/dist）
#   --developer-id              用 Developer ID Application 证书重签（仅签名，不公证）
#   --notarize                  明确同意提交 Apple 公证（notarytool --wait + staple 装订）
#   --release                   正式发行模式：要求有效 Developer ID 证书、显式 --notarize
#                               与 notarytool 钥匙串配置，缺一即失败并说明（退出码 3）
#   --identity <名称>           Developer ID Application 身份（也可用环境变量提供）
#   --keychain-profile <名称>   notarytool 钥匙串配置名（也可用环境变量提供）
#   --dry-run                   只检测并打印计划，不创建任何文件
#   -h, --help                  显示帮助
#
# 环境变量:
#   APP_PATH                                输入 .app
#   OUTPUT_DIR                              输出目录
#   DMG_VOLUME_NAME                         磁盘映像卷名（默认 "Glimmer <版本>"）
#   GLIMMER_SIGN_IDENTITY            Developer ID Application 身份
#   GW_SIGNING_IDENTITY                      本地稳定签名身份（测试模式保留源 App 有效签名）
#   GLIMMER_NOTARY_KEYCHAIN_PROFILE  notarytool 钥匙串配置名
#
# 退出码: 0 成功 | 1 运行失败 | 2 参数错误 | 3 正式发行前置条件不足
#
# 安全与边界（与仓库 DISTRIBUTION.md 一致）:
#   * 不创建、不导入、不导出、不存储任何证书或私钥；只使用钥匙串中已存在的身份。
#   * 只有显式传入 --notarize 才会向 Apple 提交公证，绝不自动上传。
#   * 绝不修改 build/ 中的原始 .app：需要重签时只处理 DMG 内的副本。
#   * 所有签名步骤发生在资源拷贝完成之后。
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Glimmer"
. "$ROOT/scripts/signing-identity.sh"

APP_PATH="${APP_PATH:-$ROOT/build/Glimmer.app}"
OUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
SIGN_IDENTITY="${GLIMMER_SIGN_IDENTITY:-${GW_SIGNING_IDENTITY:-}}"
NOTARY_PROFILE="${GLIMMER_NOTARY_KEYCHAIN_PROFILE:-}"
VOLUME_NAME="${DMG_VOLUME_NAME:-}"

MODE="test"           # test | developer-id | release
DO_NOTARIZE=0
DRY_RUN=0

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --app)              [ $# -ge 2 ] || { echo "错误: --app 需要参数" >&2; exit 2; }; APP_PATH="$2"; shift 2 ;;
    --out)              [ $# -ge 2 ] || { echo "错误: --out 需要参数" >&2; exit 2; }; OUT_DIR="$2"; shift 2 ;;
    --identity)         [ $# -ge 2 ] || { echo "错误: --identity 需要参数" >&2; exit 2; }; SIGN_IDENTITY="$2"; shift 2 ;;
    --keychain-profile) [ $# -ge 2 ] || { echo "错误: --keychain-profile 需要参数" >&2; exit 2; }; NOTARY_PROFILE="$2"; shift 2 ;;
    --developer-id)     [ "$MODE" = "release" ] || MODE="developer-id"; shift ;;
    --release)          MODE="release"; shift ;;
    --notarize)         DO_NOTARIZE=1; shift ;;
    --dry-run)          DRY_RUN=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "未知参数: $1（用 --help 查看用法）" >&2; exit 2 ;;
  esac
done

# --notarize 隐含需要 Developer ID 重签；未显式指定模式时按 developer-id 处理。
if [ "$DO_NOTARIZE" = 1 ] && [ "$MODE" = "test" ]; then
  MODE="developer-id"
fi

die()  { echo "" >&2; echo "✗ $*" >&2; exit 1; }
die3() { echo "" >&2; echo "✗ $*" >&2; exit 3; }

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
bool_str()    { [ "$1" = 1 ] && printf 'true' || printf 'false'; }
plist_get() {
  # $1=键 $2=回退值 $3=plist 路径
  local v=""
  v="$(/usr/libexec/PlistBuddy -c "Print :$1" "$3" 2>/dev/null || true)"
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

code_signature_info() {
  # 输出 codesign 描述信息（失败时也返回已捕获内容）
  codesign -dv --verbose=4 "$1" 2>&1 || true
}

detect_signature() {
  # $1=app 路径；echo: adhoc | apple-development | developer-id | other | unsigned | unknown
  local out="$2"
  [ -n "$out" ] || out="$(code_signature_info "$1")"
  if printf '%s\n' "$out" | grep -q '^Signature=adhoc'; then
    printf 'adhoc'
  elif printf '%s\n' "$out" | grep -q '^Authority=Apple Development'; then
    printf 'apple-development'
  elif printf '%s\n' "$out" | grep -q '^Authority=Developer ID Application'; then
    printf 'developer-id'
  elif printf '%s\n' "$out" | grep -q '^Authority='; then
    printf 'other'
  elif printf '%s\n' "$out" | grep -qi 'not signed at all'; then
    printf 'unsigned'
  else
    printf 'unknown'
  fi
}

first_authority() {
  local out; out="$(code_signature_info "$1")"
  printf '%s\n' "$out" | grep -m1 '^Authority=' | sed 's/^Authority=//' || true
}

has_hardened_runtime() {
  local out; out="$(code_signature_info "$1")"
  case "$out" in
    *"(runtime)"*) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_arch() {
  local raw="$1" tok has_arm=0 has_x86=0
  for tok in $raw; do
    case "$tok" in
      arm64*)        has_arm=1 ;;
      x86_64*|i386*) has_x86=1 ;;
    esac
  done
  if [ "$has_arm" = 1 ] && [ "$has_x86" = 1 ]; then printf 'universal'
  elif [ "$has_arm" = 1 ]; then printf 'arm64'
  elif [ "$has_x86" = 1 ]; then printf 'x86_64'
  else printf '%s' "${raw:-unknown}"; fi
}

identity_list() {
  # 已安装的代码签名身份（只读查询，不会导出任何密钥）
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^[[:space:]]*[0-9][0-9]*) [[:xdigit:]]* "\(.*\)".*$/\1/p' || true
}

require_identity() {
  # $1=身份字符串；校验其存在且为 Developer ID Application；失败退出码 3
  local ident="$1" avail
  avail="$(identity_list)"
  if [ -z "$avail" ]; then
    die3 "钥匙串中没有任何有效的代码签名身份（0 valid identities）。
  本脚本不会创建或伪造证书。正式发行需要 Apple Developer Program 的
  Developer ID Application 证书（在 developer.apple.com 申请后安装到本机钥匙串）。
  测试打包不需要证书：直接运行 scripts/make-dmg.sh 即可生成 ad-hoc 测试 DMG。"
  fi
  case "$ident" in
    *"Developer ID Application"*) ;;
    *) die3 "提供的身份不是 Developer ID Application 证书：$ident
  正式发行必须使用 Developer ID Application 身份；请用
    security find-identity -v -p codesigning
  查看本机可用身份。" ;;
  esac
  if ! printf '%s\n' "$avail" | grep -qF -- "$ident"; then
    die3 "提供的身份在钥匙串中不存在：$ident
  本机可用身份（security find-identity -v -p codesigning）：
$avail"
  fi
}

autodetect_identity() {
  identity_list | grep '^Developer ID Application' || true
}
detach_retry() {
  # $1=挂载点；尽力卸载，避免残留资源占用
  local target="$1" i
  for i in 1 2 3 4 5; do
    if hdiutil detach "$target" -quiet 2>/dev/null; then return 0; fi
    sleep 1
  done
  hdiutil detach "$target" -force -quiet 2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------------------
# 1. 校验输入 .app
# ---------------------------------------------------------------------------
[ -n "$APP_PATH" ] || die "未指定输入 .app。"
[ -d "$APP_PATH" ] || die "未找到应用包：$APP_PATH
  请先运行 scripts/build-app.sh 构建，或使用 scripts/package-release.sh --build。"
[ "${APP_PATH##*.}" = "app" ] || die "输入路径不是 .app 包：$APP_PATH"
[ -f "$APP_PATH/Contents/Info.plist" ] || die "应用包不完整（缺少 Info.plist）：$APP_PATH
  可能构建仍在进行；请等待构建完成（scripts/build-app.sh）后重试。"
[ -f "$APP_PATH/Contents/PkgInfo" ] || echo "• 提示：应用包缺少 PkgInfo（不影响运行，可能不是完整 bundle）。"

BUNDLE_FILE="$(basename "$APP_PATH")"
BUNDLE_STEM="${BUNDLE_FILE%.app}"
PLIST="$APP_PATH/Contents/Info.plist"

EXECUTABLE_NAME="$(plist_get CFBundleExecutable "$BUNDLE_STEM" "$PLIST")"
EXECUTABLE="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
[ -f "$EXECUTABLE" ] || die "应用可执行文件不存在：Contents/MacOS/$EXECUTABLE_NAME"

VERSION="$(plist_get CFBundleShortVersionString "0.0.0" "$PLIST")"
BUILD_NUMBER="$(plist_get CFBundleVersion "0" "$PLIST")"
BUNDLE_ID="$(plist_get CFBundleIdentifier "(未知)" "$PLIST")"
MIN_OS="$(plist_get LSMinimumSystemVersion "(未声明)" "$PLIST")"
DISPLAY_NAME="$(plist_get CFBundleDisplayName "$BUNDLE_STEM" "$PLIST")"

ARCH_RAW="$(lipo -archs "$EXECUTABLE" 2>/dev/null || true)"
[ -n "$ARCH_RAW" ] || ARCH_RAW="$(file -b "$EXECUTABLE" 2>/dev/null || echo unknown)"
ARCH="$(normalize_arch "$ARCH_RAW")"

# 原始 .app 的签名状态（仅用于报告，不会修改它）
ORIG_SIGN_OUT="$(code_signature_info "$APP_PATH")"
ORIG_SIG_KIND="$(detect_signature "$APP_PATH" "$ORIG_SIGN_OUT")"

# 独立运行检查：动态库依赖只允许系统路径 / rpath
DEPS_BAD="$(otool -L "$EXECUTABLE" 2>/dev/null | tail -n +2 | awk '{print $1}' \
  | grep -Ev '^(/System/|/usr/lib/|@rpath/|@executable_path/|@loader_path/)' || true)"

# 开发目录绝对路径检查（发布产物不应包含构建机路径）
EMBEDDED_PATHS="$(strings -a "$EXECUTABLE" 2>/dev/null | grep -cF -- "$ROOT" || true)"

echo "== Glimmer DMG 打包 =="
echo "输入应用 : $APP_PATH"
echo "版本     : $VERSION (build $BUILD_NUMBER)  Bundle ID: $BUNDLE_ID"
echo "系统要求 : macOS $MIN_OS"
echo "架构     : ${ARCH}（原始: ${ARCH_RAW}）"
case "$ORIG_SIG_KIND" in
  adhoc)       echo "当前签名 : ad-hoc 测试签名（非正式发行）" ;;
  apple-development) echo "当前签名 : Apple Development（稳定本地测试身份，未公证）" ;;
  developer-id) echo "当前签名 : Developer ID（$(first_authority "$APP_PATH")）" ;;
  unsigned)    echo "当前签名 : 未签名" ;;
  *)           echo "当前签名 : $ORIG_SIG_KIND" ;;
esac

if [ "$MODE" = "test" ]; then
  codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1 \
    || die "测试打包要求输入 App 已具有有效签名；请先运行 scripts/build-app.sh。"
  echo "测试打包 : 保留源 App 的有效签名，不重新 ad-hoc 签名"
fi
if [ -n "$DEPS_BAD" ]; then
  echo "⚠︎ 动态库依赖异常（可能不是独立应用）："
  printf '%s\n' "$DEPS_BAD" | sed 's/^/    /'
else
  echo "独立运行 : 动态库依赖仅系统路径/rpath ✓"
fi
if [ "${EMBEDDED_PATHS:-0}" != "0" ]; then
  echo "⚠︎ 可执行文件中发现开发目录绝对路径（${ROOT}，出现 ${EMBEDDED_PATHS} 次）"
fi
echo "签名模式 : $MODE$([ "$DO_NOTARIZE" = 1 ] && echo ' + 明确选择公证')"

# ---------------------------------------------------------------------------
# 2. 正式发行前置条件（缺一即失败并解释；退出码 3）
# ---------------------------------------------------------------------------
if [ "$MODE" = "release" ]; then
  if [ "$DO_NOTARIZE" != 1 ]; then
    die3 "正式发行（--release）必须显式传入 --notarize 才会提交 Apple 公证；这是故意的
  双确认设计，避免误上传。若只想做 Developer ID 签名测试，请使用 --developer-id。
  （不提供公证凭据时本脚本不会、也无法完成正式公网发行。）"
  fi
  echo "Release  : 将执行 Developer ID 签名 + Apple 公证 + staple 装订"
fi

case "$MODE" in
  developer-id|release)
    if [ -z "$SIGN_IDENTITY" ]; then
      DETECTED="$(autodetect_identity)"
      COUNT="$(printf '%s\n' "$DETECTED" | grep -c '^Developer ID Application' || true)"
      if [ "$COUNT" = "0" ]; then
        die3 "需要 Developer ID Application 身份，但本机钥匙串中没有可用证书。
  本脚本不会创建或伪造证书。请在 developer.apple.com 申请 Developer ID 证书，
  安装到本机钥匙串后重试，或通过 --identity / GLIMMER_SIGN_IDENTITY 指定。
  仅测试打包无需证书：直接运行 scripts/make-dmg.sh 生成 ad-hoc DMG。"
      elif [ "$COUNT" = "1" ]; then
        SIGN_IDENTITY="$DETECTED"
        echo "身份     : 自动检测到 $SIGN_IDENTITY"
      else
        die3 "钥匙串中有多个 Developer ID 身份，请用 --identity 明确指定其一：
$DETECTED"
      fi
    fi
    require_identity "$SIGN_IDENTITY"
    ;;
esac

if [ "$DO_NOTARIZE" = 1 ]; then
  [ -n "$NOTARY_PROFILE" ] || die3 "公证需要 notarytool 钥匙串配置名：
  --keychain-profile <名称> 或环境变量 GLIMMER_NOTARY_KEYCHAIN_PROFILE。
  该配置由你本人创建（凭据保存在你自己的钥匙串中，本脚本不读取、不导出、不记录）：
    xcrun notarytool store-credentials \"<配置名>\" \\
      --apple-id <你的 Apple ID> --team-id <TEAMID> --password <App 专用密码>
  或者仅测试打包：不加 --notarize。"
  command -v xcrun >/dev/null 2>&1 && xcrun --find notarytool >/dev/null 2>&1 \
    || die "未找到 notarytool（需要 Xcode 命令行工具）。"
fi

# 输出命名（版本/架构进入文件名；不包含任何绝对路径）
VERSION_SAFE="$(printf '%s' "$VERSION" | tr ' /:' '---')"
BASE="$BUNDLE_STEM-$VERSION_SAFE-$ARCH"
DMG_NAME="$BASE.dmg"
DMG_PATH="$OUT_DIR/$DMG_NAME"
[ -n "$VOLUME_NAME" ] || VOLUME_NAME="$BUNDLE_STEM $VERSION"

echo "输出     : $DMG_PATH"

if [ "$DRY_RUN" = 1 ]; then
  echo ""
  echo "== dry-run：仅检测，未创建任何文件 =="
  echo "计划生成: ${DMG_NAME}（卷名 \"${VOLUME_NAME}\"，应用 + /Applications 符号链接）"
  echo "          $DMG_NAME.sha256 与 $BASE.manifest.json"
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. 生成压缩 DMG：可写映像挂载 → 拷贝（唯一的资源落地）→ 重签 → 转 UDZO
# ---------------------------------------------------------------------------
mkdir -p "$OUT_DIR"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/glimmer-dmg.XXXXXX")"
MNT="$TMP/mnt"
MOUNTED=0
cleanup() {
  if [ "$MOUNTED" = 1 ]; then detach_retry "$MNT" >/dev/null 2>&1 || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

STAGE_KB="$(du -sk "$APP_PATH" | awk '{print $1}')"
SIZE_MB=$(( STAGE_KB / 1024 + 48 ))
[ "$SIZE_MB" -lt 64 ] && SIZE_MB=64

echo "== 创建磁盘映像（临时 ${SIZE_MB}MB，之后压缩）=="
hdiutil create -quiet -size "${SIZE_MB}m" -fs HFS+ -volname "$VOLUME_NAME" -type UDIF "$TMP/rw.dmg"
mkdir -p "$MNT"
hdiutil attach -quiet -nobrowse -readwrite -mountpoint "$MNT" "$TMP/rw.dmg"
MOUNTED=1

echo "== 拷贝应用到映像根目录 =="
ditto "$APP_PATH" "$MNT/$BUNDLE_FILE"

echo "== 创建 Applications 符号链接 =="
ln -sfn /Applications "$MNT/Applications"

TARGET_APP="$MNT/$BUNDLE_FILE"

# —— 所有资源拷贝完成之后才进行签名 ——
if [ "$MODE" = "developer-id" ] || [ "$MODE" = "release" ]; then
  echo "== Developer ID 重新签名（仅处理映像内副本，不动 ${APP_PATH}）=="
  # Sign nested Intel launcher before sealing its parent bundle.
  ROSETTA_HELPER="$TARGET_APP/Contents/Helpers/RosettaLauncher.app"
  if [ -d "$ROSETTA_HELPER" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$ROSETTA_HELPER" \
      || die "Rosetta 引导组件 Developer ID 签名失败。"
  fi
  WALLPAPER_EXTENSION="$TARGET_APP/Contents/PlugIns/GlimmerWallpaperExtension.appex"
  if [ -d "$WALLPAPER_EXTENSION" ]; then
    # Extension identity must match its final Developer ID team, not the ad-hoc build.
    EXTENSION_TEAM="$(codesign -dv --verbose=4 "$ROSETTA_HELPER" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
    [ -n "$EXTENSION_TEAM" ] && [ "$EXTENSION_TEAM" != "not set" ] \
      || die "无法确定扩展的 Developer ID TeamIdentifier。"
    EXTENSION_ENTITLEMENTS="$TMP/wallpaper-extension-entitlements.plist"
    cp "$ROOT/Extensions/GlimmerWallpaperExtension/Extension.entitlements" "$EXTENSION_ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Set :com.apple.application-identifier ${EXTENSION_TEAM}.com.boneinkzhong.glimmer.wallpaper-extension" "$EXTENSION_ENTITLEMENTS"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
      --entitlements "$EXTENSION_ENTITLEMENTS" "$WALLPAPER_EXTENSION" \
      || die "动态锁屏扩展 Developer ID 签名失败。"
  fi
  if ! codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$TARGET_APP"; then
    die "Developer ID 签名失败。请确认证书有效且私钥可用（security find-identity -v -p codesigning）。"
  fi
  codesign --verify --deep --strict --verbose=1 "$TARGET_APP" >/dev/null 2>&1 \
    || die "重签后 codesign --verify --strict 失败，已中止。"
fi

# 最终签名状态（以映像内副本为准，写入 manifest）
FINAL_SIGN_OUT="$(code_signature_info "$TARGET_APP")"
FINAL_SIG_KIND="$(detect_signature "$TARGET_APP" "$FINAL_SIGN_OUT")"
FINAL_AUTHORITY="$(first_authority "$TARGET_APP")"
APP_EXEC_SHA="$(shasum -a 256 "$TARGET_APP/Contents/MacOS/$EXECUTABLE_NAME" | awk '{print $1}')"
APP_SIG_VALID=0
if codesign --verify --deep --strict "$TARGET_APP" >/dev/null 2>&1; then APP_SIG_VALID=1; fi
APP_RUNTIME=0
if has_hardened_runtime "$TARGET_APP"; then APP_RUNTIME=1; fi

if [ "$MODE" = "release" ] && [ "$FINAL_SIG_KIND" != "developer-id" ]; then
  die "正式发行要求 Developer ID 签名，当前最终签名为：$FINAL_SIG_KIND"
fi
if [ "$APP_SIG_VALID" = 0 ] && [ "$MODE" != "test" ]; then
  die "签名校验失败（codesign --verify --strict），已中止。"
fi

# 许可与第三方声明应随应用分发（由 build-app.sh 复制进 Resources）
LICENSES_MISSING=""
for f in LICENSE NOTICE.md; do
  [ -f "$TARGET_APP/Contents/Resources/$f" ] || LICENSES_MISSING="$LICENSES_MISSING $f"
done

echo "== 卸载临时映像 =="
detach_retry "$MNT"
MOUNTED=0

echo "== 转换为压缩映像（UDZO）=="
rm -f "$DMG_PATH"
hdiutil convert "$TMP/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_PATH" -quiet

if ! hdiutil verify "$DMG_PATH" >/dev/null 2>&1; then
  die "hdiutil verify 校验新生成的 DMG 失败：$DMG_PATH"
fi
echo "映像校验 : hdiutil verify 通过 ✓"
# ---------------------------------------------------------------------------
# 4. 签名 DMG（在资源与转换全部完成之后）→ 可选公证 → 校验
# ---------------------------------------------------------------------------
DMG_SIGNED=0
DMG_NOTARIZED=0

if [ "$MODE" = "developer-id" ] || [ "$MODE" = "release" ]; then
  echo "== 签名 DMG =="
  if ! codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"; then
    die "DMG 签名失败。"
  fi
  codesign --verify --verbose=1 "$DMG_PATH" >/dev/null 2>&1 || die "DMG 签名校验失败。"
  DMG_SIGNED=1
fi

if [ "$DO_NOTARIZE" = 1 ]; then
  echo "== 提交 Apple 公证（xcrun notarytool --wait，可能需要几分钟）=="
  if ! xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait; then
    echo "" >&2
    echo "✗ 公证失败或被拒绝。可用下面的命令查看具体日志（不会输出凭据内容）：" >&2
    echo "  xcrun notarytool log <submission-id> --keychain-profile \"$NOTARY_PROFILE\"" >&2
    exit 1
  fi
  echo "== 装订公证 ticket（staple）=="
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  DMG_NOTARIZED=1
fi

# ---------------------------------------------------------------------------
# 5. SHA-256 与打包清单（manifest）
# ---------------------------------------------------------------------------
DMG_SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
DMG_BYTES="$(stat -f %z "$DMG_PATH")"
CREATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
HOST_OS="$(sw_vers -productVersion 2>/dev/null || uname -r)"

printf '%s  %s\n' "$DMG_SHA" "$DMG_NAME" > "$DMG_PATH.sha256"

# 最终对外的签名模式描述（如实反映检查结果，而不是请求的模式）
SIGNING_MODE=""
case "$FINAL_SIG_KIND" in
  developer-id)
    if [ "$DMG_NOTARIZED" = 1 ]; then SIGNING_MODE="developer-id-notarized"
    else SIGNING_MODE="developer-id"; fi ;;
  apple-development) SIGNING_MODE="apple-development-test" ;;
  adhoc)    SIGNING_MODE="adhoc-test" ;;
  unsigned) SIGNING_MODE="unsigned-test" ;;
  *)        SIGNING_MODE="$FINAL_SIG_KIND" ;;
esac

# 警告列表（JSON 数组）
WARNINGS=""
add_warning() { WARNINGS="$WARNINGS$1\n"; }
case "$SIGNING_MODE" in
  apple-development-test)
    add_warning "Apple Development 稳定本地测试签名：未使用 Developer ID，也未公证；仅供本机/受控验证，不是正式公网发行版本。" ;;
  adhoc-test)
    add_warning "ad-hoc 测试构建：未使用 Developer ID 证书，也未公证；仅供本机/受控验证，不是正式公网发行版本。其他用户下载后首次打开会被 Gatekeeper 拦截（需右键『打开』或到系统设置放行）。" ;;
  unsigned-test)
    add_warning "未签名测试构建：仅供本机验证，不是正式发行版本。" ;;
  developer-id)
    add_warning "已 Developer ID 签名但未公证：可分发测试，但正式公网发行仍需 Apple 公证（--release --notarize）。" ;;
esac
[ -n "$DEPS_BAD" ] && add_warning "可执行文件存在系统路径之外的动态库依赖，可能不是独立应用。"
[ "${EMBEDDED_PATHS:-0}" != "0" ] && add_warning "可执行文件中发现开发目录绝对路径，建议检查构建参数。"
[ -n "$LICENSES_MISSING" ] && add_warning "应用包 Resources 中缺少许可文件：$LICENSES_MISSING"

WARNINGS_JSON="[]"
if [ -n "$WARNINGS" ]; then
  WARNINGS_JSON="$(
    printf '%b' "$WARNINGS" | while IFS= read -r line; do
      [ -n "$line" ] && printf '    "%s",\n' "$(json_escape "$line")"
    done
  )"
  WARNINGS_JSON="[
$(printf '%s' "$WARNINGS_JSON" | sed '$ s/,$//')
  ]"
fi

ARCH_JSON="[]"
if [ -n "$ARCH_RAW" ]; then
  ARCH_ITEMS="$(printf '%s\n' "$ARCH_RAW" | tr ' ' '\n' | while IFS= read -r tok; do
    [ -n "$tok" ] && printf '    "%s",\n' "$(json_escape "$tok")"
  done)"
  ARCH_JSON="[
$(printf '%s' "$ARCH_ITEMS" | sed '$ s/,$//')
  ]"
fi

MANIFEST_PATH="$OUT_DIR/$BASE.manifest.json"
cat > "$MANIFEST_PATH" <<JSON
{
  "manifestVersion": 1,
  "product": "$(json_escape "$APP_NAME")",
  "displayName": "$(json_escape "$DISPLAY_NAME")",
  "version": "$(json_escape "$VERSION")",
  "build": "$(json_escape "$BUILD_NUMBER")",
  "bundleIdentifier": "$(json_escape "$BUNDLE_ID")",
  "appBundle": "$(json_escape "$BUNDLE_FILE")",
  "minimumSystemVersion": "$(json_escape "$MIN_OS")",
  "architecture": "$(json_escape "$ARCH")",
  "architectures": $ARCH_JSON,
  "dmgFile": "$(json_escape "$DMG_NAME")",
  "dmgVolumeName": "$(json_escape "$VOLUME_NAME")",
  "dmgBytes": $DMG_BYTES,
  "dmgSHA256": "$DMG_SHA",
  "appExecutableSHA256": "$APP_EXEC_SHA",
  "requestedMode": "$(json_escape "$MODE")",
  "signingMode": "$(json_escape "$SIGNING_MODE")",
  "appSignature": "$(json_escape "$FINAL_SIG_KIND")",
  "appSignatureAuthority": "$(json_escape "$FINAL_AUTHORITY")",
  "appSignatureValid": $(bool_str "$APP_SIG_VALID"),
  "appHardenedRuntime": $(bool_str "$APP_RUNTIME"),
  "dmgSigned": $(bool_str "$DMG_SIGNED"),
  "dmgNotarized": $(bool_str "$DMG_NOTARIZED"),
  "createdAtUTC": "$(json_escape "$CREATED_AT")",
  "hostMacOS": "$(json_escape "$HOST_OS")",
  "distributionWarnings": $WARNINGS_JSON,
  "notes": "由 scripts/make-dmg.sh 生成；不包含任何开发目录绝对路径。"
}
JSON

# ---------------------------------------------------------------------------
# 6. 汇总
# ---------------------------------------------------------------------------
DMG_SIZE_H="$(du -h "$DMG_PATH" | awk '{print $1}')"

echo ""
echo "== 打包完成 =="
echo "DMG      : ${DMG_PATH}（${DMG_SIZE_H}）"
echo "SHA-256  : $DMG_SHA"
echo "校验文件 : $DMG_PATH.sha256"
echo "清单     : $MANIFEST_PATH"
case "$SIGNING_MODE" in
  developer-id-notarized)
    echo "签名状态 : Developer ID 签名 + Apple 公证（正式发行）✓" ;;
  developer-id)
    echo "签名状态 : Developer ID 签名（未公证，非正式公网发行）" ;;
  apple-development-test)
    echo "签名状态 : Apple Development 稳定本地测试签名（未公证）" ;;
  adhoc-test)
    echo "签名状态 : ad-hoc 测试构建（非正式发行）⚠︎" ;;
  *)
    echo "签名状态 : $SIGNING_MODE" ;;
esac
if [ -n "$LICENSES_MISSING" ]; then
  if [ "$MODE" = "release" ]; then
    die "正式发行要求应用包内包含 LICENSE 与 NOTICE.md（缺少：${LICENSES_MISSING}）。请先运行 scripts/build-app.sh 重新构建。"
  fi
  echo "提示     : 应用包 Resources 缺少许可文件：${LICENSES_MISSING}（建议重新构建）"
fi
echo "验证命令 :"
echo "  (cd \"$OUT_DIR\" && shasum -a 256 -c \"$DMG_NAME.sha256\")"
echo "  hdiutil verify \"$DMG_PATH\""
echo "  \"$ROOT/scripts/package-release.sh\" --verify \"$DMG_PATH\""
if [ "$SIGNING_MODE" = "adhoc-test" ]; then
  echo ""
  echo "说明: 当前为本机测试产物，不能宣称已具备正式公网发行身份。"
  echo "      正式发行（Developer ID + 公证）请见 DISTRIBUTION.md："
  echo "      scripts/make-dmg.sh --release --notarize --identity \"Developer ID Application: ...\" --keychain-profile <配置名>"
fi

exit 0
