#!/bin/bash
# =============================================================================
# Glimmer — 发布打包入口（F21）
#
# 默认行为：把现有 build/Glimmer.app 交给 scripts/make-dmg.sh 生成 DMG。
# 需要先构建时加 --build（调用 scripts/build-app.sh），签名/公证参数原样透传。
#
# 用法:
#   scripts/package-release.sh                 # 用现有 .app 打包并保留其有效测试签名
#   scripts/package-release.sh --build         # 先构建（CONFIG=${CONFIG:-release}）再打包
#   scripts/package-release.sh --build --clean # 清理后完整构建再打包
#   scripts/package-release.sh --developer-id --identity "Developer ID Application: ... (TEAMID)"
#   scripts/package-release.sh --release --notarize --identity ... --keychain-profile ...
#   scripts/package-release.sh --verify dist/Glimmer-0.1.0-arm64.dmg
#
# 透传给 make-dmg.sh 的参数:
#   --app <路径> --out <目录> --developer-id --release --notarize
#   --identity <名称> --keychain-profile <名称> --dry-run
#
# 签名/公证说明见 DISTRIBUTION.md。安全边界与 make-dmg.sh 相同：
# 不创建/导出证书，不自动上传公证，不修改 build/ 中的原始 .app。
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAKE_DMG="$ROOT/scripts/make-dmg.sh"
BUILD_APP="$ROOT/scripts/build-app.sh"

DO_BUILD=0
DO_CLEAN=0
VERIFY_DMG=""
PASS_ARGS=()

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() { echo "" >&2; echo "✗ $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --build)  DO_BUILD=1; shift ;;
    --clean)  DO_CLEAN=1; shift ;;
    --verify) [ $# -ge 2 ] || { echo "错误: --verify 需要 DMG 路径" >&2; exit 2; }; VERIFY_DMG="$2"; shift 2 ;;
    --app|--out|--identity|--keychain-profile)
              [ $# -ge 2 ] || { echo "错误: $1 需要参数" >&2; exit 2; }
              PASS_ARGS[${#PASS_ARGS[@]}]="$1"; PASS_ARGS[${#PASS_ARGS[@]}]="$2"; shift 2 ;;
    --developer-id|--release|--notarize|--dry-run)
              PASS_ARGS[${#PASS_ARGS[@]}]="$1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1（用 --help 查看用法）" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# 校验模式：挂载 DMG 检查结构与校验和（只读，不修改任何内容）
# ---------------------------------------------------------------------------
verify_dmg() {
  local dmg="$1"
  [ -f "$dmg" ] || die "未找到 DMG：$dmg"
  [ "${dmg##*.}" = "dmg" ] || die "不是 .dmg 文件：$dmg"

  local tmp mnt rc=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/glimmer-verify.XXXXXX")"
  mnt="$tmp/mnt"
  mkdir -p "$mnt"

  echo "== 校验 DMG: $dmg =="
  if ! hdiutil attach "$dmg" -readonly -nobrowse -quiet -mountpoint "$mnt"; then
    rm -rf "$tmp"
    die "DMG 挂载失败，可能文件损坏。"
  fi

  local app_found="" p
  for p in "$mnt"/*.app; do
    [ -e "$p" ] || continue
    if [ -n "$app_found" ]; then
      echo "✗ 映像根目录存在多个 .app"
      rc=1
    fi
    app_found="$p"
  done
  if [ -z "$app_found" ]; then
    echo "✗ 映像根目录没有 .app"
    rc=1
  else
    echo "✓ 应用存在: $(basename "$app_found")"
  fi

  if [ -L "$mnt/Applications" ]; then
    local target
    target="$(readlink "$mnt/Applications")"
    if [ "$target" = "/Applications" ]; then
      echo "✓ Applications 符号链接 → /Applications（可拖拽安装）"
    else
      echo "✗ Applications 符号链接指向 ${target}（应为 /Applications）"
      rc=1
    fi
  else
    echo "✗ 缺少 Applications 符号链接"
    rc=1
  fi

  if [ -n "$app_found" ]; then
    if codesign --verify --deep --strict "$app_found" >/dev/null 2>&1; then
      echo "✓ 应用代码签名结构有效"
    else
      echo "✗ 应用代码签名校验失败"
      rc=1
    fi
    local plist exe_name exe ver arch raw has_arm has_x86
    plist="$app_found/Contents/Info.plist"
    exe_name="$(basename "$app_found" .app)"
    exe_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$plist" 2>/dev/null || printf '%s' "$exe_name")"
    exe="$app_found/Contents/MacOS/$exe_name"
    ver="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null || echo "?")"
    raw="$(lipo -archs "$exe" 2>/dev/null || echo "?")"
    has_arm=0; has_x86=0
    case "$raw" in *arm64*) has_arm=1 ;; esac
    case "$raw" in *x86_64*) has_x86=1 ;; esac
    if [ "$has_arm" = 1 ] && [ "$has_x86" = 1 ]; then arch="universal"
    elif [ "$has_arm" = 1 ]; then arch="arm64"
    elif [ "$has_x86" = 1 ]; then arch="x86_64"
    else arch="$raw"; fi
    echo "• 版本 ${ver}，架构 ${arch}"
    local sig_out
    sig_out="$(codesign -dv --verbose=4 "$app_found" 2>&1 || true)"
    if printf '%s\n' "$sig_out" | grep -q '^Signature=adhoc'; then
      echo "• 签名类型: ad-hoc（测试构建，非正式发行）"
    elif printf '%s\n' "$sig_out" | grep -q '^Authority=Apple Development'; then
      echo "• 签名类型: Apple Development（稳定本地测试身份，未公证）"
    elif printf '%s\n' "$sig_out" | grep -q '^Authority=Developer ID Application'; then
      echo "• 签名类型: Developer ID Application"
    fi
  fi

  if [ -f "$dmg.sha256" ]; then
    local expect actual
    expect="$(awk '{print $1}' "$dmg.sha256" | head -n 1)"
    actual="$(shasum -a 256 "$dmg" | awk '{print $1}')"
    if [ -n "$expect" ] && [ "$expect" = "$actual" ]; then
      echo "✓ SHA-256 与 $dmg.sha256 一致"
    else
      echo "✗ SHA-256 不一致（期望 ${expect}，实际 ${actual}）"
      rc=1
    fi
  else
    echo "• 未找到 $dmg.sha256，跳过 SHA-256 校验"
  fi

  hdiutil detach "$mnt" -quiet 2>/dev/null || hdiutil detach "$mnt" -force -quiet 2>/dev/null || true
  rm -rf "$tmp"

  if [ "$rc" = 0 ]; then
    echo "== 校验通过 =="
  else
    echo "== 校验失败 ==" >&2
  fi
  exit "$rc"
}

if [ -n "$VERIFY_DMG" ]; then
  verify_dmg "$VERIFY_DMG"
fi

# ---------------------------------------------------------------------------
# 打包模式
# ---------------------------------------------------------------------------
[ -x "$MAKE_DMG" ] || die "缺少打包脚本：$MAKE_DMG"

if [ "$DO_BUILD" = 1 ]; then
  [ -x "$BUILD_APP" ] || die "缺少构建脚本：$BUILD_APP"
  if [ "$DO_CLEAN" = 1 ]; then
    echo "== 清理并完整构建 =="
    "$BUILD_APP" --clean
  else
    echo "== 构建（增量）=="
    "$BUILD_APP"
  fi
elif [ "${#PASS_ARGS[@]}" = 0 ]; then
  # 未指定 --app/--out 等参数时，提前给出更友好的缺应用提示
  if [ ! -d "$ROOT/build/Glimmer.app" ]; then
    die "未找到 build/Glimmer.app。
  请先构建：scripts/package-release.sh --build
  或手动运行：scripts/build-app.sh"
  fi
fi

echo "== 调用 make-dmg.sh =="
if [ "${#PASS_ARGS[@]}" -gt 0 ]; then
  "$MAKE_DMG" "${PASS_ARGS[@]}"
else
  "$MAKE_DMG"
fi
