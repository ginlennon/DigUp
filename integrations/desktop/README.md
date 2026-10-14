# DigUp in GNOME Files (right-click scripts)

Two entries for the right-click menu of GNOME Files (Nautilus, tested with Files 46), under **Scripts**:

- **DigUp: Find similar**: on a file, the files most like it by meaning (`digup similar <file> -n 15`). Works on
  anything DigUp reads: a photo finds photos and video frames of the same thing, a PDF finds related documents.
  A file that isn't indexed yet is read on the spot (a moment longer).
- **DigUp: Search in this folder**: on a folder, or on the empty space inside one, asks what to look for and
  searches that folder and its subfolders by meaning and words (`digup search "<words>" --in <folder> -n 20`).

The results come up in a list: kind, where (the page of a PDF, `p. 3`, or the moment in a recording, `1:05`),
name and folder, best first. Double-click one (or select it and press OK) to open it:

- a PDF at its page, when Evince (or GNOME Papers) is the default PDF app (`evince -i <page>`);
- a video or recording at its moment, when VLC is installed (`vlc --start-time=<seconds>`);
- anything else, or when those apps aren't there, in its default app (`xdg-open`).

If DigUp can't do it (no helper found, a file type DigUp doesn't read, a folder outside the index) a dialog says why.

## Install

You need DigUp's helper (`digup`, built or installed: see the repo's [README](../../README.md)) with an index of
the folders you want to search, plus `zenity`, `python3` and `xdg-open` (all part of a standard GNOME desktop).

```sh
integrations/desktop/install.sh             # links the scripts into ~/.local/share/nautilus/scripts
integrations/desktop/install.sh --copy      # or: copies them, so this checkout can move or be deleted
integrations/desktop/install.sh --dry-run   # shows what it would do
integrations/desktop/install.sh --uninstall # removes DigUp's entries (and the copy), nothing else
nautilus -q                                 # Files picks up new scripts when it starts again
```

Then right-click a file or folder in Files → **Scripts** → **DigUp: …**. The installer doesn't overwrite a script
of the same name that isn't DigUp's (unless `--force`).

The scripts look for the helper in this order: `$DIGUP_HELPER`; `~/.local/opt/digup/helper/digup` (an installed
DigUp); `digup` on your `PATH`; the developer build `.build/release/digup` of the checkout the scripts are in (with
`DIGUP_BACKENDS` set to its `Vendor/llama/lib`); and for a `--copy` install, the helper the installer found, written
to `digup-desktop.conf` beside the copy (`~/.local/share/digup/desktop-integration`).

## Settings and testing

- `DIGUP_INDEX=<folder>`: search that index instead of your default one (passed on as `--index`).
- `DIGUP_GPU=0`: run the model on the CPU (as for every `digup` command).
- `DIGUP_SCRIPT_NONINTERACTIVE=1`: no dialogs. The scripts print the rows (tab-separated) and the command that would
  open the first one, and errors go to stderr. `DIGUP_SCRIPT_QUERY` gives the search words. For example:

```sh
DIGUP_SCRIPT_NONINTERACTIVE=1 integrations/desktop/digup-find-similar ~/Pictures/beach.jpg
DIGUP_SCRIPT_NONINTERACTIVE=1 DIGUP_SCRIPT_QUERY="lease pets clause" integrations/desktop/digup-search-folder ~/Documents
```

Files hands a script the selected files in `NAUTILUS_SCRIPT_SELECTED_FILE_PATHS` and the folder it shows in
`NAUTILUS_SCRIPT_CURRENT_URI`; run by hand, the scripts take the files as arguments instead. *Find similar* uses the
first selected file.

## Privacy

Everything happens on your computer. The scripts run your local `digup` helper, which only reads the index on your
disk (`~/.local/share/digup/index` unless you chose another) and the model files; nothing is sent anywhere, and the
scripts don't change the index or your files.
