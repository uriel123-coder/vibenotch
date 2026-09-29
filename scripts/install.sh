#!/bin/bash
# Instala o actualiza VibeNotch desde la última versión publicada en GitHub.
#
#   curl -fsSL https://raw.githubusercontent.com/uriel123-coder/vibenotch/main/scripts/install.sh | bash
set -euo pipefail

REPO="uriel123-coder/vibenotch"
URL="https://github.com/$REPO/releases/latest/download/VibeNotch.zip"
DEST="/Applications"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "VibeNotch solo funciona en macOS."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || fail "Necesitas macOS 14 (Sonoma) o más nuevo. Tienes $(sw_vers -productVersion)."

bold "✨ Instalando VibeNotch…"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "→ Descargando la última versión"
curl -fL --progress-bar "$URL" -o "$tmp/VibeNotch.zip" || fail "No pude descargar $URL"
ditto -x -k "$tmp/VibeNotch.zip" "$tmp"
[ -d "$tmp/VibeNotch.app" ] || fail "El zip no contiene VibeNotch.app"

if pgrep -x VibeNotch >/dev/null; then
  echo "→ Cerrando la versión anterior"
  pkill -x VibeNotch || true
  sleep 1
fi

SUDO=""
[ -w "$DEST" ] || SUDO="sudo"
$SUDO rm -rf "$DEST/VibeNotch.app"
$SUDO ditto "$tmp/VibeNotch.app" "$DEST/VibeNotch.app"
$SUDO xattr -dr com.apple.quarantine "$DEST/VibeNotch.app" 2>/dev/null || true

open "$DEST/VibeNotch.app"
version=$(defaults read "$DEST/VibeNotch.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
bold "✓ Listo: VibeNotch $version instalada en $DEST."
echo "  Pasa el mouse por el notch (o arriba al centro si tu Mac no tiene) y haz clic para abrirlo."
echo "  También: ✨ en la barra de menús · ⌃⌥N abre · ⌃⌥V portapapeles · ⌃⌥F buscar archivos"
echo "  Desde la 1.3 se actualiza sola: te avisa en el notch cuando hay versión nueva."
