#!/bin/bash
# Embedding benchmark on Linux: indexes each folder of the bench corpus (scripts/linux/make-bench-corpus.sh) into a
# fresh index, once per backend, and prints wall seconds per folder plus the GPU memory the run peaked at.
#   scripts/linux/bench-embed.sh [corpus] [configs]     configs default: "cpu vulkan"
# cpu = only the CPU backend modules (Vendor/llama/cpu-only); vulkan = all of Vendor/llama/lib (Vulkan + CPU).
# Model load (~1-2 s) is included in each folder's time: the first line of each run is a 1-file warm-up to show it.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CORPUS="${1:-$REPO/.dev/bench-corpus}"
CONFIGS="${2:-cpu vulkan}"
DIGUP="$REPO/.build/release/digup"
OUT="$REPO/.dev/bench-$(date +%y%m%d-%H%M)"
mkdir -p "$OUT"
GPU=$(ls -d /sys/class/drm/card*/device 2>/dev/null | head -1)

# Peak of VRAM + GTT (an iGPU takes most of its memory as GTT) while $1 runs, in MiB.
peak_gpu() {
  local pid=$1 peak=0 now
  while kill -0 "$pid" 2>/dev/null; do
    now=$(( ( $(cat "$GPU/mem_info_vram_used") + $(cat "$GPU/mem_info_gtt_used") ) / 1048576 ))
    (( now > peak )) && peak=$now
    sleep 0.2
  done
  echo $peak
}

printf '%-8s %-12s %6s %8s %9s\n' config folder files seconds gpu_peak
for config in $CONFIGS; do
  case $config in
    cpu) backends="$REPO/Vendor/llama/cpu-only" ;;
    vulkan) backends="$REPO/Vendor/llama/lib" ;;
    *) echo "unknown config $config"; exit 1 ;;
  esac
  base=$(( ( $(cat "$GPU/mem_info_vram_used") + $(cat "$GPU/mem_info_gtt_used") ) / 1048576 ))
  for folder in "$CORPUS"/*/; do
    name=$(basename "$folder")
    index="$OUT/$config-$name"
    start=$(date +%s.%N)
    DIGUP_BACKENDS="$backends" "$DIGUP" index "$folder" --index "$index" > "$OUT/$config-$name.log" 2>&1 &
    peak=$(peak_gpu $!)
    wait $! || { echo "$config $name failed: see $OUT/$config-$name.log"; continue; }
    seconds=$(echo "$(date +%s.%N) - $start" | bc)
    files=$(grep -c '^\[' "$OUT/$config-$name.log" || true)
    printf '%-8s %-12s %6s %8.1f %8sM\n' "$config" "$name" "$files" "$seconds" "$(( peak - base ))"
  done
  grep -h 'backends:\|ready in' "$OUT/$config"-*/worker.log | sort | uniq -c | sed 's/^/    /'
done | tee "$OUT/summary.txt"
echo "logs: $OUT"
