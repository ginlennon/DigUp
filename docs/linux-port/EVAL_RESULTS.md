# Search quality on Linux — `digup eval`

Testbed: `scripts/linux/make-testbed.sh` (synthetic/, traps/, code/; no real/), i.e. Wikimedia photos and piper voices
instead of Apple's sample pictures and `say` voices, so numbers are comparable to macOS but not identical.
Index: `digup index ~/DigUpTestbed/{synthetic,traps}` + `digup index --code ~/DigUpTestbed/code`, Vulkan backend
(860M), llama.cpp b11461, vectors 1. Indexing took 44 s (+10 s rest of long files, +4 s code).

## Baseline 2026-10-14 ~01:20 — before Stage 3 (no OCR; testbed shot_*.png indexed as plain images)

| Eval | n | R@1 | R@5 | R@10 | MRR |
|---|---|---|---|---|---|
| synthetic | 37 | 0.97 | 0.97 | 0.97 | 0.97 |
| multilingual | 48 | 0.92 | 0.98 | 0.98 | 0.95 |
| code | 41 | 1.00 | 1.00 | 1.00 | 1.00 |

Per tag, below 1.00 only: synthetic `exact` 0.80 (1 of 5 missing — exact strings in screenshots need OCR);
multilingual `bn-word` R@1 0.67 (“ধানমন্ডি” at #2), `bn→en` 0.50 (1 of 2), `en→ar` R@1 0.83 (“rainy weather in
Riyadh” at #2), `en→bn` R@1 0.86 (“mobile wallet transfer failed…” at #2). Everything else — image, audio, video
moments, PDF pages, long files, screenshots by meaning, Bengali/Arabic docs/PDFs/speech — is 1.00.
