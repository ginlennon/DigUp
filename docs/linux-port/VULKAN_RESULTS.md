# Vulkan embedder on the Radeon 860M — results

Machine: Ryzen AI 7 PRO 350 (16 threads), Radeon 860M iGPU (RADV gfx1152, Mesa 25.2.8), 54 GB RAM, Ubuntu 24.04.5.
Build: llama.cpp **b11461** + `llama.cpp-no-logits.patch`, `GGML_VULKAN=ON GGML_BACKEND_DL=ON GGML_CPU_ALL_VARIANTS=ON`;
Swift 6.4.1 release build of `digup`; model `embeddinggemma-2-Q8_0` + `mmproj-…-Q8_0` (ggml-org @ bfcd2987).

## Correctness (2026-10-14)
- `ReferenceVectorTests.vectorsMatchTheReference` (cosine ≥ 0.999 vs the macOS/Metal reference; 5 texts incl. bn/ar
  and a ~1,800-token document, screenshot@280, photo@140/@70, speech): **PASS on CPU (7.4 s) and PASS on Vulkan (3.7 s)**.
- CPU vs Vulkan, same files, stored (float16) vectors: image 0.99994, md 0.99986, txt 0.99973, audio 0.99991.

## Throughput (2026-10-14 00:38, `scripts/linux/bench-embed.sh` on `scripts/linux/make-bench-corpus.sh`)
One `digup index` per folder into a fresh index, model load included (0.6–1.3 s per run). CPU = only the CPU backend
modules, default 8 threads; Vulkan = Vulkan + CPU modules. GPU memory = peak (VRAM + GTT) over the desktop baseline.

| Folder | Files | CPU s | Vulkan s | Speed-up | GPU mem |
|---|---|---|---|---|---|
| audio (2 min speech+noise, 5 windows each) | 6 | 42.2 | 19.2 | 2.20× | 1.45 GB |
| docs (~2,500-word notes) | 30 | 113.2 | 40.8 | 2.77× | 1.42 GB |
| pdfs (19-page text PDFs, 114 pages) | 6 | 85.1 | 27.5 | 3.09× | 1.35 GB |
| photos (1600×1200 JPEG, budget 140) | 40 | 52.5 | 22.8 | 2.30× | 1.31 GB |
| screenshots (1920×1080 PNG, budget 280) | 30 | 94.8 | 33.4 | 2.84× | 1.34 GB |
| video (60 s, cut every 10 s, with sound) | 4 | 60.9 | 21.1 | 2.89× | 1.33 GB |
| **total** | **116** | **448.7** | **164.8** | **2.72×** | |

No DeviceLost, no `ErrorOutOfDeviceMemory`, no errors in any worker log; no desktop stall noticed. Peak GPU memory
~1.45 GB, far below RADV's 4 GB single-allocation cap. Contexts stay ≤ 2048 (the 16k crash wall is not in play).

## Decision (PLANS §A3 rule)
Gate passes ✓, ≥ 1.5× ✓ (2.72×), no failures ✓ in ~3 min of GPU work → **Vulkan is the intended default on this
machine**; the 1 h soak run is still owed before it's final. CPU stays the automatic fallback.

## Not measured yet
1 h soak; CPU at 16 threads; behaviour while the desktop is busy (video playback, browser) and across suspend/resume;
query-encoder latency in search-service (text-only, 512 ctx) on Vulkan vs CPU; power draw/thermals.
