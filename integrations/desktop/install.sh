#!/usr/bin/env bash
# Adds DigUp's scripts to GNOME Files (Nautilus): right-click → Scripts → "DigUp: Find similar",
# "DigUp: Search in this folder" and "DigUp: Add this folder". See README.md.
#
#   install.sh              link the scripts in this checkout into ~/.local/share/nautilus/scripts
#   install.sh --copy       copy them to ~/.local/share/digup/desktop-integration first (with the helper and the app
#                           found now written beside them), so the checkout can move or go
#   install.sh --uninstall  remove ours (only links to these scripts, and the copy)
#   --dry-run               say what would be done, do nothing
#   --force                 replace a script of the same name that isn't ours
set -uo pipefail

here=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
data_home=${XDG_DATA_HOME:-$HOME/.local/share}
scripts_dir="$data_home/nautilus/scripts"
copy_dir="$data_home/digup/desktop-integration"
programs=(digup-find-similar digup-search-folder digup-add-folder)
titles=("DigUp: Find similar" "DigUp: Search in this folder" "DigUp: Add this folder")
files=(digup-find-similar digup-search-folder digup-add-folder digup-desktop-lib.sh)

mode=install copy=0 dry=0 force=0
for arg in "$@"; do
    case "$arg" in
        --uninstall) mode=uninstall ;;
        --copy) copy=1 ;;
        --dry-run) dry=1 ;;
        --force) force=1 ;;
        -h | --help)
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            printf 'install.sh: unknown option %s (see --help)\n' "$arg" >&2
            exit 2
            ;;
    esac
done

# Runs a command, or only shows it with --dry-run.
run() {
    if ((dry)); then
        printf 'would run:'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# Whether $1 is a link to one of our scripts (in this checkout, a copy, or a checkout that has moved since).
ours() {
    local target
    [[ -L "$1" ]] || return 1
    target=$(readlink -- "$1")
    case "$(basename -- "$target")" in
        digup-find-similar | digup-search-folder | digup-add-folder) return 0 ;;
        *) return 1 ;;
    esac
}

do_uninstall() {
    local i entry removed=0
    for i in "${!titles[@]}"; do
        entry="$scripts_dir/${titles[i]}"
        if ours "$entry"; then
            run rm -f -- "$entry"
            removed=1
        elif [[ -e "$entry" || -L "$entry" ]]; then
            printf 'Left %s: it isn'\''t a link to DigUp'\''s script.\n' "$entry"
        fi
    done
    if [[ -f "$copy_dir/digup-desktop-lib.sh" ]]; then
        for i in "${files[@]}" digup-desktop.conf; do
            [[ -e "$copy_dir/$i" ]] && run rm -f -- "$copy_dir/$i"
        done
        run rmdir --ignore-fail-on-non-empty -- "$copy_dir"
        removed=1
    fi
    if ((dry)); then
        echo "(dry run: nothing was changed)"
    elif ((removed)); then
        echo "DigUp's scripts are removed from Files (nautilus -q, then open Files again, to refresh its menu)."
    else
        echo "DigUp's scripts weren't installed."
    fi
}

do_install() {
    local source_dir=$here i entry found helper backends app
    for i in "${!titles[@]}"; do
        entry="$scripts_dir/${titles[i]}"
        if [[ -e "$entry" || -L "$entry" ]] && ! ours "$entry" && ((!force)); then
            printf 'install.sh: %s exists and isn'\''t DigUp'\''s; leaving it (--force replaces it).\n' "$entry" >&2
            exit 1
        fi
    done

    # The helper the scripts will find, as they look for it (with no dialogs).
    found=$(DIGUP_SCRIPT_NONINTERACTIVE=1 bash -c \
        'source "$1/digup-desktop-lib.sh" && digup_find_helper && printf "%s\n%s\n" "$DIGUP_BIN" "${DIGUP_BACKENDS:-}"' \
        _ "$here" 2>/dev/null)
    helper=$(sed -n 1p <<<"$found")
    backends=$(sed -n 2p <<<"$found")
    if [[ -n "$helper" ]]; then
        printf 'The scripts will use the helper %s\n' "$helper"
    else
        echo "Note: no DigUp helper (digup) was found yet; the scripts will say so until one is installed."
    fi
    # And the app "Add this folder" hands folders to.
    app=$(DIGUP_SCRIPT_NONINTERACTIVE=1 bash -c \
        'source "$1/digup-desktop-lib.sh" && digup_find_app && printf "%s\n" "$DIGUP_APP_BIN"' _ "$here" 2>/dev/null)
    if [[ -n "$app" ]]; then
        printf '"Add this folder" will hand folders to %s\n' "$app"
    else
        echo "Note: the DigUp app (digup-shell) wasn't found yet; \"Add this folder\" will say so until it's installed."
    fi

    if ((copy)); then
        source_dir=$copy_dir
        run mkdir -p -- "$copy_dir"
        for i in "${files[@]}"; do
            run cp -f -- "$here/$i" "$copy_dir/$i"
        done
        if [[ -n "$helper" || -n "$app" ]]; then
            if ((dry)); then
                printf 'would write %s: helper=%s backends=%s app=%s\n' "$copy_dir/digup-desktop.conf" "$helper" \
                    "$backends" "$app"
            else
                {
                    echo "# Written by install.sh: the helper and the app the DigUp scripts fall back to."
                    printf '%s\n' "helper=$helper" "backends=$backends" "app=$app"
                } >"$copy_dir/digup-desktop.conf"
            fi
        fi
    fi

    run mkdir -p -- "$scripts_dir"
    for i in "${!titles[@]}"; do
        run chmod +x -- "$source_dir/${programs[i]}"
        run ln -sfn -- "$source_dir/${programs[i]}" "$scripts_dir/${titles[i]}"
    done

    for i in zenity python3 xdg-open; do
        command -v "$i" >/dev/null 2>&1 || printf 'Note: the scripts need %s, which isn'\''t installed.\n' "$i"
    done
    if ((dry)); then
        echo "(dry run: nothing was changed)"
        return
    fi
    cat <<EOF
Installed into $scripts_dir:
  ${titles[0]}           on a file: the files most like it
  ${titles[1]}  on a folder (or inside one): search it by meaning
  ${titles[2]}        on a folder (or inside one): add it to DigUp and search in it
In Files, right-click a file or folder (or the empty space of a folder) → Scripts.
They show up when Files starts again: nautilus -q, then open Files.
EOF
}

"do_$mode"
