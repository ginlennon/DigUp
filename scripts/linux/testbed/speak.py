"""Text to speech for the testbed with Piper (CPU), standing in for macOS's `say` voices: Samantha (en), Piya (bn),
Majed (ar); and the voices of the European recordings (make_eu.py: de, fr, es, it, pt). Writes 16 kHz mono WAVs, as
make_media.sh writes them.

    uv run --project scripts/linux/testbed python -I scripts/linux/testbed/speak.py <language> <out.wav> <text> [<out.wav> <text> ...]

The voices come from rhasspy/piper-voices at a pinned revision, checked by sha256, and are kept in
${DIGUP_TESTBED_CACHE:-${XDG_CACHE_HOME:-~/.cache}/digup-testbed}/voices.
"""
import hashlib
import os
import subprocess
import sys
import tempfile
import urllib.request
import wave

REVISION = "c10ece1aade47bb51c153c893d14e5bf8e5b7117"  # rhasspy/piper-voices, 2026-09-17
BASE = f"https://huggingface.co/rhasspy/piper-voices/resolve/{REVISION}/"
VOICES = {  # language: (path in the repo, sha256 of .onnx, sha256 of .onnx.json); licenses in each voice's MODEL_CARD
    "en": ("en/en_US/lessac/medium/en_US-lessac-medium",
           "5efe09e69902187827af646e1a6e9d269dee769f9877d17b16b1b46eeaaf019f",
           "efe19c417bed055f2d69908248c6ba650fa135bc868b0e6abb3da181dab690a0"),
    "bn": ("bn/bn_BD/google/medium/bn_BD-google-medium",
           "f2e7518ed5534a755024a48c71b80bf617efaf12570bbdf3ce255a9526a8afd3",
           "bc7e5e39e2a874bdad186620576ce18089b5a06c5645e258bcea3d56fdb11c0a"),
    "ar": ("ar/ar_JO/kareem/medium/ar_JO-kareem-medium",
           "9e95cab07b679da603bba17c4dec7ab3111320571964ee95c0379603c086491e",
           "ea6d9b9d9076dbdb6bf5c98c6a141ef154959d2359709b37855727964e7d6c4d"),
    # The ASR spike's voices (docs/linux-port/ASR_SPIKE.md). Each .onnx sha256 is the file's Git LFS oid at REVISION, and
    # each .onnx.json's Git blob id matched the repo tree there (2026-10-14).
    "de": ("de/de_DE/thorsten/medium/de_DE-thorsten-medium",
           "7e64762d8e5118bb578f2eea6207e1a35a8e0c30595010b666f983fc87bb7819",
           "974adee790533adb273a1ac88f49027d2a1b8f0f2cf4905954a4791e79264e85"),
    "fr": ("fr/fr_FR/siwis/medium/fr_FR-siwis-medium",
           "641d1ab097da2b81128c076810edb052b385decc8be3381814802a64a73baf99",
           "39479916c2db192b5ac9764daddd0c744d83e023ad890c6976c0633ae4df8959"),
    "es": ("es/es_ES/davefx/medium/es_ES-davefx-medium",
           "6658b03b1a6c316ee4c265a9896abc1393353c2d9e1bca7d66c2c442e222a917",
           "0e0dda87c732f6f38771ff274a6380d9252f327dca77aa2963d5fbdf9ec54842"),
    "it": ("it/it_IT/paola/medium/it_IT-paola-medium",
           "6fc918b5a0ea6137382833dddfa567bffbe6a5060c02043c87192ee59c04210c",
           "aea19c0a7fce29fbc359b93f10e7902854401e4c95ae2ea328ae516b15d296cf"),
    "pt": ("pt/pt_BR/faber/medium/pt_BR-faber-medium",
           "858555e3a064209c57088fe6bd70c4c3dc54d03eaa00c45d5ecaf43a33f95aa7",
           "7e694de195ae3fc36dd732c445eb04fb49b649854893cb5506b978f0d50a1d6f"),
}
UA = "DigUpTestbed/0.1 (https://github.com/ginlennon/DigUp; testbed generator)"


def cache_dir(kind):
    root = os.environ.get("DIGUP_TESTBED_CACHE") or os.path.join(
        os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "digup-testbed")
    path = os.path.join(root, kind)
    os.makedirs(path, exist_ok=True)
    return path


def fetch(url, path, sha256):
    if os.path.exists(path) and hashlib.sha256(open(path, "rb").read()).hexdigest() == sha256:
        return path
    print(f"  downloading {os.path.basename(path)}", file=sys.stderr)
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(request, timeout=300) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != sha256:
        sys.exit(f"{url}: sha256 mismatch (the pinned file changed?)")
    with open(path + ".part", "wb") as f:
        f.write(data)
    os.replace(path + ".part", path)
    return path


def voice(language):
    from piper import PiperVoice

    repo_path, onnx_sha, json_sha = VOICES[language]
    folder = cache_dir("voices")
    name = os.path.basename(repo_path)
    model = fetch(BASE + repo_path + ".onnx", os.path.join(folder, name + ".onnx"), onnx_sha)
    config = fetch(BASE + repo_path + ".onnx.json", os.path.join(folder, name + ".onnx.json"), json_sha)
    return PiperVoice.load(model, config_path=config, use_cuda=False)


def main():
    args = sys.argv[1:]
    if len(args) < 3 or len(args) % 2 == 0 or args[0] not in VOICES:
        sys.exit(__doc__)
    speaker = voice(args[0])
    with tempfile.TemporaryDirectory() as tmp:
        for out, text in zip(args[1::2], args[2::2]):
            raw = os.path.join(tmp, "raw.wav")
            with wave.open(raw, "wb") as f:
                speaker.synthesize_wav(text, f)
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", raw, "-ac", "1", "-ar", "16000", out],
                           check=True)


if __name__ == "__main__":
    main()
