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

# macOS ties permissions (Accessibility, Microphone…) to the signature. An ad-hoc signature changes with every build,
# so each update would ask again; the same certificate every time keeps them. It lives in a throwaway keychain.
SIGN_DIR="$HOME/.config/vibenotch-signing"
SIGN_P12="${SIGN_P12:-$SIGN_DIR/signing.p12}"
SIGN_PASSWORD="${SIGN_PASSWORD:-$(cat "$SIGN_DIR/password.txt" 2>/dev/null || true)}"
if [ -f "$SIGN_P12" ] && [ -n "$SIGN_PASSWORD" ]; then
  KC="$(mktemp -d)/vibenotch-sign.keychain-db"
  OLD_KCS=()
  while IFS= read -r k; do k="${k//\"/}"; k="${k#"${k%%[![:space:]]*}"}"; [ -n "$k" ] && OLD_KCS+=("$k"); done < <(security list-keychains -d user)
  security create-keychain -p vibenotch "$KC"
  security unlock-keychain -p vibenotch "$KC"
  security import "$SIGN_P12" -k "$KC" -P "$SIGN_PASSWORD" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k vibenotch "$KC" >/dev/null
  security list-keychains -d user -s "$KC" ${OLD_KCS[@]+"${OLD_KCS[@]}"}
  SIGN_ID="$(security find-identity -p codesigning "$KC" | awk '/VibeNotch Signing/ {print $2; exit}')"
  SIGNED=0
  codesign --force --keychain "$KC" --sign "$SIGN_ID" "$APP" && SIGNED=1
  security list-keychains -d user -s ${OLD_KCS[@]+"${OLD_KCS[@]}"}
  security delete-keychain "$KC"
  [ "$SIGNED" = 1 ] || { echo "✗ No se pudo firmar la app"; exit 1; }
else
  [ -n "${REQUIRE_SIGNING:-}" ] && { echo "✗ Falta el certificado de firma"; exit 1; }
  codesign --force --sign - "$APP" >/dev/null 2>&1
fi
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
