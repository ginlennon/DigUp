#!/bin/bash
# German, English, French, Spanish, Italian and Portuguese files with known content (evals/european.json): notes, a
# two-page PDF, a screenshot and recordings per language, silence and music probes, and transcripts.json (what each
# recording says). See make_eu.py. Run it on its own to add the folder to an existing testbed.
#   scripts/linux/testbed/make_eu.sh <dir>       e.g. ~/DigUpTestbed/synthetic/lang/eu
set -euo pipefail
E="${1:?usage: make_eu.sh <dir>}"; HERE="$(cd "$(dirname "$0")" && pwd)"
[[ -e "$E" ]] && { echo "$E already exists; delete it first (rm -rf \"$E\")"; exit 1; }
uv run --locked --project "$HERE" python -I "$HERE/make_eu.py" "$E" >/dev/null
