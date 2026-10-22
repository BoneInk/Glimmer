#!/bin/bash
# Glimmer 可重复构建脚本（SwiftPM / swiftc CLI，不依赖完整 Xcode 工程）
#
# 用法:
#   scripts/build-app.sh              # 编译 + 生成 .app（优先稳定 Apple Development 身份）
#   scripts/build-app.sh --clean      # 清理后重新构建
#   scripts/build-app.sh --dmg        # 额外生成 DMG 与 SHA-256（见 scripts/make-dmg.sh）
#   scripts/build-app.sh --typecheck  # 只做类型检查，不产出 .app
#
# 环境:
#   CONFIG=release|debug              （默认 release）
#   GW_SCOPE=full|local               full=全部模块（默认）；local=仅本地播放模块，
#                                     用于其他并行模块尚未完成时验证本地功能
#   GW_SOURCES="dir1 dir2"            自定义源码目录（相对 Sources/Glimmer），配合 GW_SCOPE=local
#   GW_SIGNING_IDENTITY=<身份或SHA>    显式指定现有签名身份；否则唯一 Apple Development，最后才 ad-hoc
#   GW_SWIFT_SOURCES_ROOT=<目录>      使用固定的 Sources 快照，避免并行修改打断长时间编译
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Glimmer"
BUNDLE_ID="com.boneinkzhong.glimmer"
VERSION="0.17.0"
BUILD_NUMBER="42"
CONFIG="${CONFIG:-release}"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
DEPLOY_TARGET="arm64-apple-macos26.0"
# 默认输出 build/；并行会话共用该目录时可用 GW_OUT_DIR 指定独立目录，避免互相覆盖。
OUT="${GW_OUT_DIR:-$ROOT/build}"
APP="$OUT/$APP_NAME.app"
SWIFT_SOURCES_ROOT="${GW_SWIFT_SOURCES_ROOT:-$ROOT/Sources}"
SRC="$SWIFT_SOURCES_ROOT/Glimmer"
. "$ROOT/scripts/signing-identity.sh"
SIGN_IDENTITY="$(gw_resolve_signing_identity)"
export GW_SIGNING_IDENTITY="$SIGN_IDENTITY"

DO_CLEAN=0
DO_DMG=0
DO_TYPECHECK=0
for arg in "$@"; do
  case "$arg" in
    --clean) DO_CLEAN=1 ;;
    --dmg) DO_DMG=1 ;;
    --typecheck) DO_TYPECHECK=1 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

# 源码范围：默认包含全部模块；local 范围只包含本地播放相关目录（B01 的所有权范围），
# 排除其他并行会话正在开发的模块（Steam/、Policies/、Playlist/、Settings/、
# UI/Workshop/、UI/Policies/），用于在没有并行模块干扰的情况下验证本地功能。
# 正式交付必须使用默认 full 范围。
SCOPE="${GW_SCOPE:-full}"
LOCAL_DIRS_DEFAULT="App Desktop Display Import LockScreen Media Model SelfTest Store Support UI"
PRUNE_PATHS_DEFAULT="$SRC/Steam $SRC/Policies $SRC/Playlist $SRC/Settings $SRC/UI/Workshop $SRC/UI/Policies"

collect_sources() {
  if [ "$SCOPE" = "full" ]; then
    find "$SRC" -name '*.swift'
    find "$SWIFT_SOURCES_ROOT/SceneBackendShared" -name '*.swift'
    return
  fi
  local dirs="${GW_SOURCES:-$LOCAL_DIRS_DEFAULT}"
  for dir in $dirs; do
    if [ "$dir" = "UI" ]; then
      # UI 根目录下是本会话的文件；UI 的任何子目录都归并行会话所有（Workshop/Policies/Settings…），
      # 因此这里统一剪枝，避免后续新增并行目录再次破坏本地构建。
      find "$SRC/UI" -mindepth 1 -type d -prune -o -name '*.swift' -print 2>/dev/null
    else
      find "$SRC/$dir" -name '*.swift' 2>/dev/null
    fi
  done
}
echo "源码范围: $SCOPE"
BACKEND_FLAGS=()
if [ "$SCOPE" = "full" ]; then BACKEND_FLAGS=(-D GW_UNIVERSAL_SCENE_BACKEND); fi

# 源文件收集：使用数组逐个传递路径，包含空格/Unicode 的项目目录也能正确编译（R11）。
SOURCES=()
while IFS= read -r source_file; do
  [ -n "$source_file" ] && SOURCES+=("$source_file")
done < <(collect_sources | sort)

if [ "${#SOURCES[@]}" -eq 0 ]; then
  echo "未找到 Swift 源文件: $SRC" >&2
  exit 1
fi
echo "源文件数: ${#SOURCES[@]}"

echo "== 构建 $APP_NAME $VERSION ($CONFIG) =="
echo "SDK: $SDK"
xcrun --show-sdk-version --sdk macosx | sed 's/^/SDK 版本: /'
swift --version | head -1 | sed 's/^/工具链: /'

# 收集全部源文件一次性编译，避免逐文件中间产物不匹配
OPT_FLAGS=(-O -whole-module-optimization)
DEBUG_FLAGS=(-Onone -g -DDEBUG)
if [ "$CONFIG" = "debug" ]; then
  OPT_FLAGS=("${DEBUG_FLAGS[@]}")
fi

# 类型检查分支不做任何输出变更（R11）：--typecheck 不得删除/创建 build/ 中的既有产物。
if [ "$DO_TYPECHECK" = "1" ]; then
  echo "== 仅类型检查（不修改任何构建产物） =="
  swiftc \
    -swift-version 6 \
    -strict-concurrency=complete \
    "${BACKEND_FLAGS[@]}" \
    -typecheck \
    -target "$DEPLOY_TARGET" \
    -sdk "$SDK" \
    "${SOURCES[@]}"
  echo "类型检查通过"
  exit 0
fi

# 以下步骤会写入输出目录（--clean 的删除也放在类型检查之后）。
if [ "$DO_CLEAN" = "1" ]; then
  rm -rf "$OUT"
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
rm -f "$APP/Contents/MacOS/$APP_NAME"

swiftc \
  -swift-version 6 \
  -strict-concurrency=complete \
  "${BACKEND_FLAGS[@]}" \
  "${OPT_FLAGS[@]}" \
  -target "$DEPLOY_TARGET" \
  -sdk "$SDK" \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  "${SOURCES[@]}"

echo "== 生成 Info.plist =="
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><false/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Glimmer contributors. 第三方组件许可见 NOTICE.md。</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleLocalizations</key><array><string>zh_CN</string><string>en</string></array>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
</dict>
</plist>
PLIST

echo "== 生成图标 =="
if [ ! -f "$ROOT/Resources/AppIcon.icns" ] \
  || [ "$ROOT/Resources/Glimmer.svg" -nt "$ROOT/Resources/AppIcon.icns" ] \
  || [ "$ROOT/scripts/render-icon.swift" -nt "$ROOT/Resources/AppIcon.icns" ] \
  || [ "$ROOT/scripts/make-icon.sh" -nt "$ROOT/Resources/AppIcon.icns" ]; then
  "$ROOT/scripts/make-icon.sh"
fi
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  cp "$ROOT/Resources/Glimmer.svg" "$APP/Contents/Resources/Glimmer.svg"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist" >/dev/null
else
  echo "（跳过：未找到 Resources/AppIcon.icns，可运行 scripts/make-icon.sh 生成）"
fi

echo "== 复制许可与说明 =="
for f in "$ROOT/NOTICE.md" "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md"; do
  [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/"
done
SCENE_NOTICE="$ROOT/Sources/Glimmer/SceneWallpaper/ThirdParty/RePKG-LICENSE.txt"
if [ -f "$SCENE_NOTICE" ]; then
  cp "$SCENE_NOTICE" "$APP/Contents/Resources/RePKG-LICENSE.txt"
fi

echo "== 生成 PkgInfo =="
printf 'APPL????' > "$APP/Contents/PkgInfo"

"$ROOT/scripts/build-rosetta-helper.sh" "$APP/Contents/Helpers/RosettaLauncher.app"
GW_SCENE_WORKER_OUT="$OUT/SceneScriptWorker" bash "$ROOT/scripts/build-scene-script-worker.sh"
cp "$OUT/SceneScriptWorker/GlimmerSceneScriptWorker" "$APP/Contents/Helpers/GlimmerSceneScriptWorker"
cp "$ROOT/Workers/SceneScript/ThirdParty/Acorn/LICENSE" "$APP/Contents/Resources/Acorn-LICENSE.txt"
for module_notice in eslint-scope esrecurse estraverse; do
  cp "$ROOT/Workers/SceneScript/ThirdParty/ModuleScope/$module_notice/LICENSE" "$APP/Contents/Resources/ModuleScope-$module_notice-LICENSE.txt"
done
GW_VERSION="$VERSION" GW_BUILD_NUMBER="$BUILD_NUMBER" "$ROOT/scripts/build-wallpaper-extension.sh" \
  --output "$APP/Contents/PlugIns/GlimmerWallpaperExtension.appex"

bash "$ROOT/scripts/build-steam-content-helper.sh"
bash "$ROOT/scripts/embed-steam-content-helper.sh" "$APP"
if [ "$SCOPE" = "full" ]; then
  bash "$ROOT/scripts/embed-scene-backend.sh" "$APP"
  bash "$ROOT/scripts/embed-lock-screen-scene-backend.sh" "$APP"
fi

echo "== 代码签名（$(gw_signing_description "$SIGN_IDENTITY")）=="
# Helpers/extensions have their own signatures and required entitlements.
# Sign the outer container without recursively stripping nested metadata.
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP" 2>&1 | sed 's/^/  /'
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'

echo "== 构建完成 =="
echo "App: $APP"
/usr/libexec/PlistBuddy -c "Print" "$APP/Contents/Info.plist" | sed 's/^/  /'

if [ "$DO_DMG" = "1" ]; then
  "$ROOT/scripts/make-dmg.sh"
fi
