#!/usr/bin/env python3
"""Generates the pre-recorded voice prompts of RoadVis with Microsoft Edge neural voices (macOS).

    pip3 install edge-tts
    python3 RoadVis/tools/generate_voice_clips.py                       # all languages, default voices
    python3 RoadVis/tools/generate_voice_clips.py --uz-voice uz-UZ-SardorNeural --rate +20% --force

Reads tools/voice_phrases.json (exported from VoiceClipCatalog.swift), synthesizes every clip with edge-tts and writes
RoadVis/RoadVis/VoiceClips/<lang>_<id>.m4a (AAC, mono, 24 kHz, converted with macOS `afconvert`; without afconvert
`ffmpeg` is tried, otherwise the .mp3 from edge-tts is kept — AVFoundation plays it too). Xcode bundles the folder
automatically (synchronized group); the app composes phrases from the clips and falls back to the system voice for
anything missing.

Default speaking rate is +15 % (the app additionally plays clips at the "Voice speed" setting, 1.1× by default).
When `ffmpeg` is available the leading / trailing silence of every clip (edge-tts adds several hundred ms) is removed
with `silenceremove` (−40 dB, 30 ms kept); the app trims silence on its own too, so clips without ffmpeg still join
without pauses.

Existing clips are skipped unless --force; when the voice or rate of a language changed since the last run, that
language is regenerated automatically (state in RoadVis/build/voice_clips_state.json).

Licensing: edge-tts uses the unofficial free endpoint of Microsoft Edge "Read aloud". Microsoft's terms most likely do
not allow redistributing the generated audio — fine for personal testing, replace the clips before publishing the app.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
PROJECT_DIR = TOOLS_DIR.parent
DEFAULT_MANIFEST = TOOLS_DIR / "voice_phrases.json"
DEFAULT_OUT = PROJECT_DIR / "RoadVis" / "VoiceClips"
STATE_FILE = PROJECT_DIR / "build" / "voice_clips_state.json"
AUDIO_EXTS = (".m4a", ".mp3")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Generate RoadVis voice clips with Microsoft Edge neural voices.")
    p.add_argument("--uz-voice", default="uz-UZ-MadinaNeural", help="uz-UZ-MadinaNeural (female) | uz-UZ-SardorNeural (male)")
    p.add_argument("--ru-voice", default="ru-RU-SvetlanaNeural", help="ru-RU-SvetlanaNeural | ru-RU-DmitryNeural")
    p.add_argument("--en-voice", default="en-US-JennyNeural", help="en-US-JennyNeural | en-US-GuyNeural")
    p.add_argument("--rate", default="+15%", help="speaking rate, e.g. +5%% or --rate=-10%% (use = for negative values)")
    p.add_argument("--languages", default="uz,ru,en", help="comma-separated subset of uz,ru,en")
    p.add_argument("--only", default="", help="comma-separated clip ids to (re)generate")
    p.add_argument("--force", action="store_true", help="regenerate clips that already exist")
    p.add_argument("--no-trim", action="store_true", help="keep the leading / trailing silence (no ffmpeg trimming)")
    p.add_argument("--keep-mp3", action="store_true", help="do not convert to .m4a")
    p.add_argument("--jobs", type=int, default=4, help="parallel requests (default 4)")
    p.add_argument("--retries", type=int, default=4, help="attempts per clip (default 4)")
    p.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    p.add_argument("--out", type=Path, default=DEFAULT_OUT)
    p.add_argument("--dry-run", action="store_true", help="only list what would be generated")
    args = p.parse_args()
    if not args.rate.endswith("%") or args.rate[0] not in "+-":
        p.error("--rate must look like +5% or -10%")
    return args


def load_state() -> dict:
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save_state(state: dict) -> None:
    try:
        STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
        STATE_FILE.write_text(json.dumps(state, indent=2, ensure_ascii=False), encoding="utf-8")
    except OSError:
        pass


def existing_clip(out_dir: Path, name: str) -> Path | None:
    for ext in AUDIO_EXTS:
        path = out_dir / f"{name}{ext}"
        if path.exists() and path.stat().st_size > 0:
            return path
    return None


def convert_to_m4a(src: Path, dst: Path) -> bool:
    """AAC mono 24 kHz .m4a. True on success."""
    if shutil.which("afconvert"):
        cmd = ["afconvert", "-f", "m4af", "-d", "aac@24000", "-c", "1", "-b", "48000", str(src), str(dst)]
    elif shutil.which("ffmpeg"):
        cmd = ["ffmpeg", "-loglevel", "error", "-y", "-i", str(src), "-ac", "1", "-ar", "24000",
               "-c:a", "aac", "-b:a", "48k", str(dst)]
    else:
        return False
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.returncode == 0 and dst.exists() and dst.stat().st_size > 0


SILENCE_FILTER = ("silenceremove=start_periods=1:start_threshold=-40dB:start_silence=0.03,areverse,"
                  "silenceremove=start_periods=1:start_threshold=-40dB:start_silence=0.03,areverse")


def trim_silence(src: Path, dst: Path) -> bool:
    """Removes leading / trailing silence with ffmpeg (mono 24 kHz WAV). True on success."""
    if not shutil.which("ffmpeg"):
        return False
    cmd = ["ffmpeg", "-loglevel", "error", "-y", "-i", str(src), "-af", SILENCE_FILTER, "-ac", "1", "-ar", "24000",
           str(dst)]
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.returncode == 0 and dst.exists() and dst.stat().st_size > 1000


async def synthesize(edge_tts, text: str, voice: str, rate: str, mp3_path: Path, retries: int) -> None:
    delay = 1.5
    for attempt in range(1, retries + 1):
        try:
            communicate = edge_tts.Communicate(text, voice, rate=rate)
            await communicate.save(str(mp3_path))
            if mp3_path.exists() and mp3_path.stat().st_size > 0:
                return
            raise RuntimeError("empty audio")
        except Exception as error:  # network hiccups, throttling (HTTP 429 / 403), empty responses
            if attempt == retries:
                raise
            print(f"    retry {attempt}/{retries - 1} after error: {error}", file=sys.stderr)
            await asyncio.sleep(delay)
            delay *= 2


async def main() -> int:
    args = parse_args()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    voices = {"uz": args.uz_voice, "ru": args.ru_voice, "en": args.en_voice}
    languages = [code.strip() for code in args.languages.split(",") if code.strip()]
    unknown = [code for code in languages if code not in voices]
    if unknown:
        print(f"Unknown language(s): {', '.join(unknown)}", file=sys.stderr)
        return 2
    only = {item.strip() for item in args.only.split(",") if item.strip()}

    out_dir: Path = args.out
    out_dir.mkdir(parents=True, exist_ok=True)
    state = load_state()
    can_convert = not args.keep_mp3 and (shutil.which("afconvert") or shutil.which("ffmpeg"))
    if not args.keep_mp3 and not can_convert:
        print("Neither afconvert nor ffmpeg found: keeping .mp3 files (AVFoundation plays them).")

    # Voice / rate changed since the last run → regenerate that language.
    force_language = {}
    for lang in languages:
        previous = state.get(lang)
        changed = previous is not None and (previous.get("voice") != voices[lang] or previous.get("rate") != args.rate)
        force_language[lang] = args.force or changed
        if changed and not args.force:
            print(f"[{lang}] voice/rate changed ({previous.get('voice')} {previous.get('rate')} → "
                  f"{voices[lang]} {args.rate}): regenerating all {lang} clips")

    jobs = []
    skipped = 0
    for clip in manifest["clips"]:
        if only and clip["id"] not in only:
            continue
        for lang in languages:
            text = clip.get(lang)
            if not text:
                continue
            name = f"{lang}_{clip['id']}"
            if existing_clip(out_dir, name) and not (force_language[lang] or only):
                skipped += 1
                continue
            jobs.append((lang, clip["id"], name, text))

    total_expected = sum(1 for clip in manifest["clips"] for lang in languages if clip.get(lang))
    print(f"Clips: {total_expected} for {', '.join(languages)}; to generate: {len(jobs)}; already present: {skipped}")
    print("Voices: " + ", ".join(f"{lang}={voices[lang]}" for lang in languages) + f"; rate {args.rate}")
    print(f"Output: {out_dir}")
    if args.dry_run:
        for lang, _, name, text in jobs:
            print(f"  {name}: {text}")
        return 0
    if not jobs:
        print("Nothing to do (use --force to regenerate).")
    try:
        import edge_tts
    except ImportError:
        print("edge-tts is not installed. Run:  python3 -m pip install --user edge-tts", file=sys.stderr)
        return 2

    semaphore = asyncio.Semaphore(max(1, args.jobs))
    failures: list[tuple[str, str]] = []
    done = 0
    started = time.time()
    tmp_dir = Path(tempfile.mkdtemp(prefix="roadvis-voice-"))

    async def run(lang: str, clip_id: str, name: str, text: str) -> None:
        nonlocal done
        async with semaphore:
            mp3 = tmp_dir / f"{name}.mp3"
            try:
                await synthesize(edge_tts, text, voices[lang], args.rate, mp3, args.retries)
                for ext in AUDIO_EXTS:  # drop an older file in the other format
                    old = out_dir / f"{name}{ext}"
                    if old.exists():
                        old.unlink()
                source = mp3
                wav = tmp_dir / f"{name}.wav"
                if can_convert and not args.no_trim and await asyncio.to_thread(trim_silence, mp3, wav):
                    source = wav
                if can_convert and await asyncio.to_thread(convert_to_m4a, source, out_dir / f"{name}.m4a"):
                    mp3.unlink(missing_ok=True)
                    wav.unlink(missing_ok=True)
                else:
                    shutil.move(str(mp3), out_dir / f"{name}.mp3")
            except Exception as error:
                failures.append((name, str(error)))
            done += 1
            if done % 10 == 0 or done == len(jobs):
                print(f"  {done}/{len(jobs)} ({time.time() - started:.0f} s)")

    await asyncio.gather(*(run(*job) for job in jobs))
    shutil.rmtree(tmp_dir, ignore_errors=True)

    for lang in languages:
        if not any(name.startswith(f"{lang}_") for name, _ in failures):
            state[lang] = {"voice": voices[lang], "rate": args.rate}
    save_state(state)

    print("\nSummary")
    for lang in languages:
        ids = [clip["id"] for clip in manifest["clips"] if clip.get(lang)]
        present = sum(1 for clip_id in ids if existing_clip(out_dir, f"{lang}_{clip_id}"))
        print(f"  {lang}: {present}/{len(ids)} clips ({voices[lang]})")
    size = sum(p.stat().st_size for p in out_dir.iterdir() if p.suffix in AUDIO_EXTS)
    print(f"  total size: {size / 1024 / 1024:.1f} MB in {out_dir}")
    if failures:
        print(f"\n{len(failures)} clip(s) failed (run the script again to retry):", file=sys.stderr)
        for name, error in failures[:20]:
            print(f"  {name}: {error}", file=sys.stderr)
        return 1
    print("\nDone. Rebuild the app (e.g. bash RoadVis/tools/install_on_iphone.sh) to bundle the clips.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except KeyboardInterrupt:
        sys.exit(130)
