#!/bin/bash
# Bengali and Arabic files with known content (evals/multilingual.json): notes, PDFs, screenshots and speech. A port of
# scripts/testbed/make_lang.sh. Linux has no screenshot attribute, so the two screenshots are plain pictures to DigUp
# here (see scripts/linux/README.md).
#   scripts/linux/testbed/make_lang.sh <dir>       e.g. ~/DigUpTestbed/synthetic/lang
set -euo pipefail
L="${1:?usage: make_lang.sh <dir>}"; HERE="$(cd "$(dirname "$0")" && pwd)"
py() { uv run --locked --project "$HERE" python -I "$@"; }
py "$HERE/make_lang.py" "$L" >/dev/null
# macOS's voices are Piya (Bengali) and Majed (Arabic); here Piper's bn_BD google and ar_JO kareem voices.
py "$HERE/speak.py" bn "$L/bn/speech_weather_bn.wav" "আগামীকাল ঢাকায় ভারী বৃষ্টি হবে, তাই বাইরে যাওয়ার সময় ছাতা নিয়ে বের হবেন। বিকেলে বজ্রসহ ঝড়ের সম্ভাবনা আছে।"
py "$HERE/speak.py" ar "$L/ar/speech_weather_ar.wav" "غدا سيكون الطقس ممطرا في الرياض مع رياح قوية، فلا تنس المظلة عند خروجك من البيت."
