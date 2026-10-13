#!/bin/bash
# Adds (or updates) a GNOME custom keyboard shortcut that opens DigUp's search panel: it runs digup-shell, and a second
# digup-shell hands over to the running one (single instance), which shows the panel. Apps can't grab keys globally on
# Wayland, and GNOME 46 has no GlobalShortcuts portal yet, so this is the way there. Other custom shortcuts are kept.
#   scripts/linux/gnome-shortcut.sh [binding] [command]     default: <Control><Alt>space, this checkout's dev launcher
#   scripts/linux/gnome-shortcut.sh --remove
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCHEMA=org.gnome.settings-daemon.plugins.media-keys
KEY=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/digup/
list=$(gsettings get $SCHEMA custom-keybindings)
if [[ "${1:-}" == --remove ]]; then
  new=$(python3 -I -c 'import ast,sys; l=[x for x in ast.literal_eval(sys.argv[1].replace("@as ","")) if x!=sys.argv[2]]; print(l)' "$list" "$KEY")
  gsettings set $SCHEMA custom-keybindings "$new"
  gsettings reset-recursively "$SCHEMA.custom-keybinding:$KEY"
  echo "removed"; exit 0
fi
BINDING="${1:-<Control><Alt>space}"
COMMAND="${2:-$REPO/scripts/linux/dev-run-shell.sh}"
new=$(python3 -I -c 'import ast,sys; l=ast.literal_eval(sys.argv[1].replace("@as ","")); l+=[sys.argv[2]] if sys.argv[2] not in l else []; print(l)' "$list" "$KEY")
gsettings set $SCHEMA custom-keybindings "$new"
gsettings set "$SCHEMA.custom-keybinding:$KEY" name "DigUp search"
gsettings set "$SCHEMA.custom-keybinding:$KEY" command "$COMMAND"
gsettings set "$SCHEMA.custom-keybinding:$KEY" binding "$BINDING"
echo "$BINDING → $COMMAND"
