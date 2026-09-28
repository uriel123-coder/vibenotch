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
bold "✓ Listo. Busca ✨ en la barra de menús o pasa el mouse arriba al centro de la pantalla."
echo "  Atajo: ⌃⌥N abre VibeNotch · ⌃⌥V abre el portapapeles"
