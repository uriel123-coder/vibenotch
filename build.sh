#!/bin/bash
# Builds VibeNotch.app with swiftc directly: only the Command Line Tools are needed (no Xcode project, no SwiftPM).
#
#   ./build.sh            release build, universal (Apple Silicon + Intel)
#   ./build.sh debug      fast native debug build
#   ./build.sh install    release build, copied to /Applications and launched
#   ./build.sh zip        release build + build/VibeNotch.zip ready to share
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-release}"
APP="build/VibeNotch.app"
BIN="$APP/Contents/MacOS/VibeNotch"
MIN_MACOS=14.0

if ! command -v swiftc >/dev/null 2>&1; then
  echo "✗ Falta el compilador de Swift. Instálalo con:  xcode-select --install"
  exit 1
fi

FLAGS=(-swift-version 5)
if [ "$MODE" = debug ]; then
  FLAGS+=(-Onone -g)
  ARCHS=("$(uname -m)")
else
  FLAGS+=(-O)
  ARCHS=(${ARCHS:-arm64 x86_64})
fi

# Some Command Line Tools installs ship a stale duplicate SwiftBridging modulemap that breaks AppKit/SwiftUI.
STALE=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [ -f "$STALE" ] && [ -f "${STALE%/*}/bridging.modulemap" ]; then
  FIX="$(pwd)/build/toolchain-fix"
  mkdir -p "$FIX"
  echo "// shadows $STALE" > "$FIX/empty.modulemap"
  cat > "$FIX/overlay.yaml" <<EOF
{"version": 0, "case-sensitive": "false", "roots": [{"type": "directory", "name": "${STALE%/*}",
  "contents": [{"type": "file", "name": "module.modulemap", "external-contents": "$FIX/empty.modulemap"}]}]}
EOF
  FLAGS+=(-vfsoverlay "$FIX/overlay.yaml" -Xcc -ivfsoverlay -Xcc "$FIX/overlay.yaml")
fi

SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find Sources -name '*.swift' ! -name main.swift | sort)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

SLICES=()
for arch in "${ARCHS[@]}"; do
  echo "→ Compilando para ${arch}…"
  out="build/obj/VibeNotch-$arch"
  swiftc "${FLAGS[@]}" -target "$arch-apple-macosx$MIN_MACOS" Sources/VibeNotch/main.swift "${SOURCES[@]}" -o "$out" 2>&1 \
    | grep -A4 "error:" || true
  [ -x "$out" ] || { echo "✗ La compilación para ${arch} falló"; exit 1; }
  SLICES+=("$out")
done
if [ "${#SLICES[@]}" -gt 1 ]; then lipo -create "${SLICES[@]}" -output "$BIN"; else cp "${SLICES[0]}" "$BIN"; fi
rm -rf build/obj

cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "✓ Listo: $(pwd)/$APP ($(lipo -archs "$BIN"))"

case "$MODE" in
  install)
    pkill -x VibeNotch 2>/dev/null && sleep 1 || true
    rm -rf /Applications/VibeNotch.app
    cp -R "$APP" /Applications/
    xattr -dr com.apple.quarantine /Applications/VibeNotch.app 2>/dev/null || true
    open /Applications/VibeNotch.app
    echo "✓ Instalado en /Applications y abierto. Busca ✨ en la barra de menús."
    ;;
  zip)
    rm -f build/VibeNotch.zip
    ditto -c -k --keepParent "$APP" build/VibeNotch.zip
    echo "✓ build/VibeNotch.zip"
    ;;
esac
