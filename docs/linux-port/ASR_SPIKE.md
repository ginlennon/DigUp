# Speech-to-text spike: which engine for transcripts (2026-10-14)

A measurement spike for [PLANS/TRANSCRIPTS_PLAN.md](../../PLANS/TRANSCRIPTS_PLAN.md), not a product change. Machine:
Ryzen AI 7 PRO 350 (16 threads), 54 GB RAM, Radeon 860M (RADV GFX1152, Mesa 25.2.8, Vulkan 1.4), Ubuntu 24.04,
kernel 6.17. About 45 min of compute in all.

## What was run
- **whisper.cpp v1.9.5** (d1be6fd, 2026-10-06, ggml 0.26.0), built for CPU and Vulkan; models `large-v3-turbo`
  q5_0 (574 MB) and q8_0 (874 MB), `small` (488 MB), `base` (148 MB); Silero VAD v6.2.0 (0.9 MB). `whisper-cli -l auto
  -t 8 -oj`, one process per file.
- **Parakeet TDT 0.6B v3** int8 (670 MB) on the CPU with sherpa-onnx 1.13.8.
- **FastFlowLM** 0.9.46 `whisper-v3:turbo` on the NPU.
- **Test set**, 69 clips, ~20 min, 16 kHz mono:
  - Piper TTS: 2 clips each in German, English, French, Spanish, Italian and Portuguese with 160 planted names,
    numbers, amounts and codes ("RE-2041", "LX 1074"), and one German 162 s clip;
  - FLEURS test-split read speech: 8 utterances per language (CC-BY-4.0);
  - silence, noise and music without speech, to provoke hallucinations;
  - DigUp's four English testbed recordings.

## Results (WER %, de / en / fr / es / it / pt)

| Engine, model, backend | Speed (× real time) | Memory | WER, FLEURS (pooled) | WER, synthetic | Planted terms found | Silence / music, no VAD |
|---|---|---|---|---|---|---|
| **whisper turbo q5_0, Vulkan** | **5.1** (load 0.14 s) | 0.2 GB RAM + 0.9 GB GPU | 3 / 4 / 11 / 2 / 3 / 5 (**5.0**) | 10 / 5 / 12 / 3 / 8 / 11 | **82 %** | "Thank you." |
| whisper turbo q8_0, Vulkan | 4.4 | + 1.2 GB GPU | 4.9 | 9 / 6 / 10 / 3 / 9 / 12 | 81 % | "I'll see you next time." |
| whisper turbo q5_0, CPU (8 threads) | 1.0 | 0.9 GB | same text as Vulkan | | 82 % | same |
| whisper small, Vulkan / CPU | 10.4 / 3.7 | 0.2 / 0.9 GB | 8.7 | 16 / 9 / 15 / 4 / 23 / 23 | 69 % | "[Subscribe]", a Sinhala loop |
| whisper base, Vulkan / CPU | 17.9 / 12.4 | 0.2 / 0.4 GB | 16.6 | 21 / 13 / 24 / 13 / 37 / 30 | 53 % | "(upbeat music)" |
| Parakeet v3 int8, CPU | 24.0 | 2.4 GB (grows with length) | 2 / 7 / 12 / 5 / 4 / 5 (6.0) | 10 / 9 / 16 / 8 / 16 / 9 | 73 % | nothing |
| FastFlowLM turbo, NPU | 4.9 | 7.2 GB | 25.6 | 38 / 20 / 63 / 44 / 49 / 14 | 56 % | subtitle credits |

- **VAD** (`--vad`, Silero): every whisper model gives no text at all for silence, noise and music; on the 162 s clip
  it loses no words and costs no measurable time. Language confidence is ≥ 0.997 on speech and 0.38–0.78 on the
  probes, so "drop below 0.9" is a cheap second guard.
- **Whole file vs 30 s windows** (162 s clip, turbo Vulkan): one call 21.2 s vs ~29 s as six window calls; windows also
  lose context, cut words at the edges and detect the language six times. Greedy decoding (`-bs 1 -bo 1`): 13.9 s, WER
  9 → 11. `-l auto` costs one extra encoder pass (~1.3 s on Vulkan).
- **Vulkan was stable**: ~330 calls, whole files up to 162 s, no DeviceLost, out-of-memory or hang.
- **Parakeet**: fastest on the CPU and never hallucinated, but weaker on names and codes ("Rapperswil-Jona" →
  "Rappers Villona"), glues words at boundaries, reports no language, and fails on one input longer than ~400 s
  (onnxruntime broadcast error) — it needs VAD chunks of ≤ 2 min.
- **FastFlowLM** drops whole spans of speech and repeats words; not usable for this.
- Many planted-term misses are the TTS voice's fault (espeak reads "LX" as "Elix", phone numbers come out garbled in
  every engine), so the term rate compares engines; FLEURS is the clean accuracy number.
- Keyword search will have to fold how whisper writes things: "BEW 5.512" for a code, "INV 3,381", "19.30 Uhr", "ß".

## Compared with what indexing a recording costs now
Embedding audio on Vulkan runs at ~37× real time (12 min of speech in 19.2 s, VULKAN_RESULTS.md). Transcribing with
turbo on Vulkan at ~5× real time is therefore **~7× the cost of the audio's embedding** — an hour of recordings takes
~12 min to transcribe, against ~1.6 min to embed. This is the main design constraint: transcripts are a background
second pass, never in the way of a file becoming searchable.

## Verdict
Default: whisper.cpp large-v3-turbo q5_0 on Vulkan, `-l auto --vad`, beam search, one call per file (long files in
chunks of a few minutes), language-confidence guard. Without a GPU: whisper `small` on the CPU (3.7×, same program),
or Parakeet v3 later if CPU-only transcripts matter. Not tested yet: noisy and conversational speech, Swiss German
dialect, songs with vocals.
