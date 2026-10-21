#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/signing-identity.sh"
SIGN_IDENTITY="$(gw_resolve_signing_identity)"
SRC="$ROOT/Extensions/GlimmerWallpaperExtension"
OUT="$ROOT/build-wallpaper-extension/GlimmerWallpaperExtension.appex"
TYPECHECK=0
DIAGNOSTIC=0
CUSTOM_OUT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --output) OUT="$2"; CUSTOM_OUT=1; shift 2 ;;
    --typecheck) TYPECHECK=1; shift ;;
    --diagnostic-entry) DIAGNOSTIC=1; shift ;;
    *) echo "Unsupported argument: $1" >&2; exit 2 ;;
  esac
done
if [ "$DIAGNOSTIC" = 1 ] && [ "$CUSTOM_OUT" = 0 ]; then
  OUT="$ROOT/build-wallpaper-extension/GlimmerWallpaperDiagnostics.bundle"
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET=arm64-apple-macos26.0
WORK="$(mktemp -d /tmp/glimmer-extension-build.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find "$SRC" -maxdepth 1 -name '*.swift' | sort)
SHARED_SOURCES="${GW_SWIFT_SOURCES_ROOT:-$ROOT/Sources}"
SOURCES+=("$SHARED_SOURCES/SceneBackendShared/SceneBackendTypes.swift"
  "$SHARED_SOURCES/Glimmer/SceneBackend/SceneBackendXPCClient.swift"
  "$SHARED_SOURCES/Glimmer/LockScreen/LiveWallpaperBundle.swift"
  "$SHARED_SOURCES/Glimmer/AuthorPropertyAssets/AuthorPropertyAssetTypes.swift"
  "$SHARED_SOURCES/Glimmer/AuthorProperties/AuthorPropertyProject.swift"
  "$SHARED_SOURCES/Glimmer/AuthorProperties/AuthorPropertyCondition.swift"
  "$SHARED_SOURCES/Glimmer/AuthorProperties/GWJSONValue.swift")
while IFS= read -r file; do SOURCES+=("$file"); done < <(find "$SHARED_SOURCES/Glimmer/WebWallpaper" -name '*.swift' | sort)
FLAGS=(-swift-version 6 -strict-concurrency=complete -target "$TARGET" -sdk "$SDK" -import-objc-header "$SRC/PrivateWallpaper.h" -parse-as-library)
if [ "$DIAGNOSTIC" = 1 ]; then
  FLAGS+=(-D GW_DIAGNOSTIC_ENTRY)
else
  FLAGS+=(-application-extension)
fi
if [ "$TYPECHECK" = 1 ]; then
  swiftc "${FLAGS[@]}" -typecheck "${SOURCES[@]}"
  exit 0
fi
if [ "$DIAGNOSTIC" = 0 ]; then FLAGS+=(-Xlinker -e -Xlinker _NSExtensionMain); fi
clang -fobjc-arc -target "$TARGET" -isysroot "$SDK" -c "$SRC/PrivateWallpaper.m" -o "$WORK/private.o"
swiftc "${FLAGS[@]}" -O -module-name GlimmerWallpaperExtension "${SOURCES[@]}" "$WORK/private.o" \
  -framework AppKit -framework AVFoundation -framework CoreMedia -framework CoreImage -framework QuartzCore \
  -framework ExtensionFoundation -framework IOSurface -framework Security -o "$WORK/GlimmerWallpaperExtension"
# Match Xcode's extension product bootstrap. A valid codec/XPC diagnostic executable
# is insufficient: the actual LC_MAIN must enter Foundation before Swift $main.
if [ "$DIAGNOSTIC" = 0 ]; then
  python3 - "$WORK/GlimmerWallpaperExtension" <<'PYENTRY'
import struct,subprocess,sys,re
binary=sys.argv[1];data=open(binary,'rb').read()
assert struct.unpack_from('<I',data)[0]==0xfeedfacf
ncmds=struct.unpack_from('<I',data,16)[0];cursor=32;entry=None;text_base=None;swift_entry=False
for _ in range(ncmds):
 cmd,size=struct.unpack_from('<II',data,cursor)
 if cmd==0x80000028:entry=struct.unpack_from('<Q',data,cursor+8)[0]
 if cmd==0x19:
  name=data[cursor+8:cursor+24].split(b'\0')[0]
  if name==b'__TEXT':text_base=struct.unpack_from('<Q',data,cursor+24)[0]
  sections=struct.unpack_from('<I',data,cursor+64)[0]
  for i in range(sections):
   section=cursor+72+i*80
   if data[section:section+16].split(b'\0')[0]==b'__swift5_entry':swift_entry=True
 cursor+=size
assert entry is not None and text_base is not None and swift_entry
indirect=subprocess.check_output(['otool','-Iv',binary],text=True)
addresses={int(m.group(1),16) for m in re.finditer(r'(0x[0-9a-fA-F]+)\s+\d+\s+_NSExtensionMain(?:\s|$)',indirect)}
assert text_base+entry in addresses, 'LC_MAIN does not target Foundation _NSExtensionMain stub'
symbols=subprocess.check_output(['nm','-n',binary],text=True)
assert re.search(r'\bT _main$',symbols,re.M), 'Swift main for ExtensionFoundation reentry was discarded'
print('Verified production LC_MAIN -> _NSExtensionMain, retained Swift _main and __swift5_entry')
PYENTRY
fi
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources/ThirdParty"
cp "$WORK/GlimmerWallpaperExtension" "$OUT/Contents/MacOS/GlimmerWallpaperExtension"
cp "$SRC/Info.plist" "$OUT/Contents/Info.plist"
if [ "$DIAGNOSTIC" = 1 ]; then
  /usr/libexec/PlistBuddy -c "Delete :EXAppExtensionAttributes" "$OUT/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundlePackageType BNDL" "$OUT/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName GlimmerWallpaperDiagnostics" "$OUT/Contents/Info.plist"
fi
if [ -n "${GW_VERSION:-}" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $GW_VERSION" "$OUT/Contents/Info.plist"; fi
if [ -n "${GW_BUILD_NUMBER:-}" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GW_BUILD_NUMBER" "$OUT/Contents/Info.plist"; fi
cp "$SRC/ThirdParty/Phosphene-LICENSE.txt" "$OUT/Contents/Resources/ThirdParty/"
python3 - "$OUT/Contents/Resources/thumbnail.png" <<'PY'
import struct,zlib,sys
w,h=480,270
raw=b''.join(b'\x00'+bytes([28+int(y*25/h),44+int(y*25/h),78+int(y*35/h)])*w for y in range(h))
def chunk(t,d):return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>2I5B',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b'')
open(sys.argv[1],'wb').write(png)
PY
codesign --force --sign "$SIGN_IDENTITY" --entitlements "$SRC/Extension.entitlements" "$OUT"
codesign --verify --strict --verbose=2 "$OUT"
printf 'Built experimental native wallpaper extension: %s\n' "$OUT"
