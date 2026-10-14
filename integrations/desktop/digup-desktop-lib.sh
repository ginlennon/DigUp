# shellcheck shell=bash
# Shared by DigUp's GNOME Files (Nautilus) scripts: finding the helper, running it, the results list, opening a
# result at its page or moment. Sourced, not run.
#
# Environment:
#   DIGUP_HELPER                  the digup helper to run (else ~/.local/opt/digup/helper/digup, digup on PATH,
#                                 this checkout's .build/release/digup, the helper named in digup-desktop.conf)
#   DIGUP_INDEX                   index folder, passed on as --index (default: digup's own, the user's index)
#   DIGUP_SCRIPT_NONINTERACTIVE=1 no dialogs: print the rows (tab-separated) and the command that would open the
#                                 first one, and errors on stderr (for tests and terminals)
#   DIGUP_SCRIPT_QUERY            the search words when there is no dialog to ask for them

DIGUP_DESKTOP_DIR=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")

digup_interactive() {
    [[ "${DIGUP_SCRIPT_NONINTERACTIVE:-0}" != 1 ]]
}

# An error, shown where the person will see it: a dialog, a notification, else stderr.
digup_fail() {
    local message=$1
    if digup_interactive && command -v zenity >/dev/null 2>&1; then
        zenity --error --title=DigUp --no-markup --text="$message" 2>/dev/null
    elif digup_interactive && command -v notify-send >/dev/null 2>&1; then
        notify-send --app-name=DigUp DigUp "$message"
    else
        printf 'DigUp: %s\n' "$message" >&2
    fi
    exit 1
}

digup_info() {
    local message=$1
    if digup_interactive && command -v zenity >/dev/null 2>&1; then
        zenity --info --title=DigUp --no-markup --text="$message" 2>/dev/null
    else
        printf 'DigUp: %s\n' "$message" >&2
    fi
}

# A value from the config file the installer writes beside a copied install (key=value lines; never sourced).
digup_config() {
    local key=$1 file="$DIGUP_DESKTOP_DIR/digup-desktop.conf" line
    [[ -r "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$key="* ]]; then
            printf '%s\n' "${line#"$key="}"
            return 0
        fi
    done <"$file"
    return 1
}

# Sets DIGUP_BIN to the helper to run (and DIGUP_BACKENDS for a developer build), or fails with a message.
digup_find_helper() {
    local candidate repo backends
    if [[ -n "${DIGUP_HELPER:-}" ]]; then
        [[ -x "$DIGUP_HELPER" ]] || digup_fail "DIGUP_HELPER is set to $DIGUP_HELPER, which isn't a program."
        DIGUP_BIN=$DIGUP_HELPER
        return
    fi
    candidate="$HOME/.local/opt/digup/helper/digup"
    if [[ -x "$candidate" ]]; then
        DIGUP_BIN=$candidate
        return
    fi
    if candidate=$(command -v digup 2>/dev/null) && [[ -x "$candidate" ]]; then
        DIGUP_BIN=$candidate
        return
    fi
    # A developer build in the checkout these scripts live in (integrations/desktop → the repo's root).
    repo=$(cd -- "$DIGUP_DESKTOP_DIR/../.." 2>/dev/null && pwd)
    if [[ -n "$repo" && -x "$repo/.build/release/digup" ]]; then
        DIGUP_BIN="$repo/.build/release/digup"
        if [[ -z "${DIGUP_BACKENDS:-}" && -d "$repo/Vendor/llama/lib" ]]; then
            export DIGUP_BACKENDS="$repo/Vendor/llama/lib"
        fi
        return
    fi
    # The helper the installer found, for a copy that no longer sits in the checkout.
    if candidate=$(digup_config helper) && [[ -x "$candidate" ]]; then
        DIGUP_BIN=$candidate
        if [[ -z "${DIGUP_BACKENDS:-}" ]] && backends=$(digup_config backends) && [[ -d "$backends" ]]; then
            export DIGUP_BACKENDS="$backends"
        fi
        return
    fi
    digup_fail "DigUp's helper (digup) wasn't found. Install DigUp, put digup on your PATH, or set DIGUP_HELPER."
}

# The selected files, one per line in NAUTILUS_SCRIPT_SELECTED_FILE_PATHS, else the script's arguments
# (relative to the folder Files runs the script in). Sets the array DIGUP_SELECTED to absolute paths.
digup_selection() {
    local line
    DIGUP_SELECTED=()
    if [[ -n "${NAUTILUS_SCRIPT_SELECTED_FILE_PATHS:-}" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && DIGUP_SELECTED+=("$line")
        done <<<"$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS"
    else
        for line in "$@"; do
            [[ "$line" == /* ]] || line="$PWD/$line"
            DIGUP_SELECTED+=("$line")
        done
    fi
}

# The folder Files is showing, from NAUTILUS_SCRIPT_CURRENT_URI (file:///home/me/My%20Docs → /home/me/My Docs).
digup_current_folder() {
    local uri=${NAUTILUS_SCRIPT_CURRENT_URI:-}
    if [[ -z "$uri" ]]; then
        printf '%s\n' "$PWD"
        return
    fi
    [[ "$uri" == file://* ]] || return 1
    uri=${uri#file://}
    uri=${uri#localhost}
    uri=${uri//\\/\\\\}
    printf '%b\n' "${uri//%/\\x}"
}

# Runs the helper with these arguments (and --index when DIGUP_INDEX is set), with a pulsing progress dialog when
# interactive. Sets DIGUP_JSON (its output) and DIGUP_STDERR; returns its exit status.
digup_run() {
    local text=$1 out err rc
    shift
    local args=("$@")
    # After the command: digup reads its options there.
    [[ -n "${DIGUP_INDEX:-}" ]] && args=("${args[0]}" --index "$DIGUP_INDEX" "${args[@]:1}")
    out=$(mktemp) err=$(mktemp)
    if digup_interactive && command -v zenity >/dev/null 2>&1; then
        # The group's own stdout feeds the dialog: when it ends, the dialog closes (--auto-close on end of input).
        { "$DIGUP_BIN" "${args[@]}" >"$out" 2>"$err" </dev/null; echo "$?" >"$out.rc"; } |
            zenity --progress --pulsate --auto-close --no-cancel --title=DigUp --text="$text" 2>/dev/null
        rc=$(cat "$out.rc" 2>/dev/null || echo 1)
    else
        "$DIGUP_BIN" "${args[@]}" >"$out" 2>"$err" </dev/null
        rc=$?
    fi
    DIGUP_JSON=$(cat "$out")
    DIGUP_STDERR=$(cat "$err")
    rm -f -- "$out" "$out.rc" "$err"
    return "$rc"
}

# The helper's error line, without its "error: " prefix.
digup_error_text() {
    local text=${DIGUP_STDERR:-}
    text=$(printf '%s\n' "$text" | grep -v '^[[:space:]]*$' | tail -n 3)
    text=${text#error: }
    text=${text#Error: }
    printf '%s\n' "${text:-digup stopped (status $1).}"
}

# Reads the hits (JSON on stdin) into arrays, row by row: DIGUP_KIND, DIGUP_WHERE ("p. 3", "1:05"), DIGUP_NAME,
# DIGUP_FOLDER (~ for home), DIGUP_PATH, DIGUP_PLACE ("page" | "moment" | "") and DIGUP_AT (the page or whole seconds).
digup_parse_hits() {
    local fields=() i
    command -v python3 >/dev/null 2>&1 || digup_fail "These scripts need python3 to read DigUp's results."
    mapfile -d '' fields < <(python3 -I -c '
import json, os, sys

def clock(seconds):
    total = int(max(seconds, 0))
    if total >= 3600:
        return "%d:%02d:%02d" % (total // 3600, total // 60 % 60, total % 60)
    return "%d:%02d" % (total // 60, total % 60)

home = os.path.expanduser("~")
for hit in json.load(sys.stdin):
    path, kind = hit.get("path", ""), hit.get("kind", "")
    segment, loc = hit.get("segment", ""), hit.get("loc")
    where = place = at = ""
    if isinstance(loc, (int, float)):
        if kind == "pdf" and segment in ("page", "page_image"):
            where = "p. %d" % int(loc)
            if loc >= 2:  # page 1 opens there anyway
                place, at = "page", str(int(loc))
        elif kind in ("video", "audio") and segment in ("frame", "audio"):
            where = clock(loc)
            if loc >= 1:  # under a second is the start
                place, at = "moment", str(int(loc))
    folder = os.path.dirname(path)
    if folder == home or folder.startswith(home + "/"):
        folder = "~" + folder[len(home):]
    for field in (kind, where, os.path.basename(path), folder, path, place, at):
        sys.stdout.write(field.replace("\0", "") + "\0")
' <<<"$DIGUP_JSON")
    DIGUP_KIND=() DIGUP_WHERE=() DIGUP_NAME=() DIGUP_FOLDER=() DIGUP_PATH=() DIGUP_PLACE=() DIGUP_AT=()
    for ((i = 0; i + 6 < ${#fields[@]}; i += 7)); do
        DIGUP_KIND+=("${fields[i]}")
        DIGUP_WHERE+=("${fields[i + 1]}")
        DIGUP_NAME+=("${fields[i + 2]}")
        DIGUP_FOLDER+=("${fields[i + 3]}")
        DIGUP_PATH+=("${fields[i + 4]}")
        DIGUP_PLACE+=("${fields[i + 5]}")
        DIGUP_AT+=("${fields[i + 6]}")
    done
}

# The program a PDF opens in when it's Evince (or GNOME Papers, its successor, which takes the same -i).
digup_pdf_viewer() {
    local app
    app=$(xdg-mime query default application/pdf 2>/dev/null) || return 1
    case "${app,,}" in
        *evince*) command -v evince ;;
        *papers*) command -v papers ;;
        *) return 1 ;;
    esac
}

# Sets the array DIGUP_OPEN to the command that opens row $1: at its page in Evince, at its moment in VLC (a new
# instance, which honours --start-time), else the default app.
digup_open_command() {
    local i=$1 viewer
    local path=${DIGUP_PATH[i]} place=${DIGUP_PLACE[i]} at=${DIGUP_AT[i]}
    DIGUP_OPEN=(xdg-open "$path")
    case "$place" in
        page)
            if viewer=$(digup_pdf_viewer); then
                DIGUP_OPEN=("$viewer" -i "$at" "$path")
            fi
            ;;
        moment)
            if viewer=$(command -v vlc 2>/dev/null); then
                DIGUP_OPEN=("$viewer" "--start-time=$at" "$path")
            fi
            ;;
    esac
}

# Shows the rows in a list titled $1 (with $2 above it) and opens the one picked; non-interactive, prints them.
digup_show_hits() {
    local title=$1 text=$2 i picked rows=()
    if ! digup_interactive; then
        printf '# %s\n' "$title"
        for i in "${!DIGUP_PATH[@]}"; do
            printf '%s\t%s\t%s\t%s\n' "${DIGUP_KIND[i]}" "${DIGUP_WHERE[i]}" "${DIGUP_NAME[i]}" "${DIGUP_FOLDER[i]}"
        done
        if ((${#DIGUP_PATH[@]})); then
            digup_open_command 0
            printf '# first row opens with:'
            printf ' %q' "${DIGUP_OPEN[@]}"
            printf '\n'
        fi
        return 0
    fi
    # The cells go in on stdin, one per line (as arguments, a name starting with "-" would read as an option), so
    # none may hold a line break or be empty.
    for i in "${!DIGUP_PATH[@]}"; do
        rows+=("${DIGUP_KIND[i]}" "${DIGUP_WHERE[i]:-—}" "${DIGUP_NAME[i]//$'\n'/ }" "${DIGUP_FOLDER[i]//$'\n'/ }" "$i")
    done
    picked=$(printf '%s\n' "${rows[@]}" | zenity --list --title="$title" --text="$text" --width=920 --height=520 \
        --column=Kind --column=Where --column=Name --column=Folder --column=Row \
        --hide-column=5 --print-column=5 2>/dev/null) || return 0
    picked=${picked%%|*}
    [[ "$picked" =~ ^[0-9]+$ ]] && ((picked < ${#DIGUP_PATH[@]})) || return 0
    digup_open_command "$picked"
    if command -v setsid >/dev/null 2>&1; then
        setsid -f "${DIGUP_OPEN[@]}" >/dev/null 2>&1 </dev/null
    else
        nohup "${DIGUP_OPEN[@]}" >/dev/null 2>&1 </dev/null &
    fi
}

# Text for zenity's --text, which reads Pango markup.
digup_markup() {
    local text=$1
    text=${text//&/&amp;}
    text=${text//</&lt;}
    text=${text//>/&gt;}
    printf '%s' "$text"
}
