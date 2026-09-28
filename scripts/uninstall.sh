#!/bin/bash
# Quita VibeNotch por completo: la app, sus hooks en Claude Code / Cursor y sus datos.
#
#   curl -fsSL https://raw.githubusercontent.com/uriel123-coder/vibenotch/main/scripts/uninstall.sh | bash
set -uo pipefail

echo "→ Cerrando VibeNotch"
pkill -x VibeNotch 2>/dev/null && sleep 1

# Removes only the entries that point at ~/.vibenotch/hook.sh; the rest of each file stays untouched.
strip_hooks() {
  local file="$1"
  [ -f "$file" ] && grep -q ".vibenotch/hook.sh" "$file" || return 0
  cp "$file" "$file.before-uninstall"
  osascript -l JavaScript - "$file" <<'JS' >/dev/null
function run(argv) {
  const path = argv[0], mark = ".vibenotch/hook.sh";
  const root = JSON.parse($.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null).js);
  const hooks = root.hooks || {};
  for (const evt of Object.keys(hooks)) {
    if (!Array.isArray(hooks[evt])) continue;
    hooks[evt] = hooks[evt].filter(h => !JSON.stringify(h).includes(mark));
    if (!hooks[evt].length) delete hooks[evt];
  }
  if (JSON.stringify(root.statusLine || "").includes(mark)) delete root.statusLine;
  $(JSON.stringify(root, null, 2)).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
}
JS
  echo "→ Hooks quitados de $file (copia en $file.before-uninstall)"
}
strip_hooks "$HOME/.claude/settings.json"
strip_hooks "$HOME/.cursor/hooks.json"

echo "→ Quitando la app y sus datos"
rm -rf /Applications/VibeNotch.app "$HOME/.vibenotch" "$HOME/Library/Application Support/VibeNotch"
defaults delete com.urielnak.vibenotch >/dev/null 2>&1

echo "✓ VibeNotch se desinstaló."
