#!/usr/bin/env python3
"""Builds the sample sermon that ships inside AutoClip: a short video and its word timings.

The voice is a placeholder made with macOS text to speech. Replace it with a real recording
you have the rights to before selling AutoClip.

Run:  python3 make-sample.py   (writes sample-sermon.mp4 and sample-sermon.json beside it)
"""
import json, os, subprocess, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
VOICE = "Evan (Enhanced)"
GAP = 0.32
FF = "/opt/homebrew/bin/ffmpeg"

REELS = [
    {"title": "You only argue with a God you're still talking to",
     "hook": "Your anger isn't the end",
     "keywords": ["anger", "faith", "breathing"],
     "ranges": [[19, 23]]},
    {"title": "The hospital parking lot",
     "hook": "I couldn't walk inside",
     "keywords": ["trust", "parking", "lot"],
     "ranges": [[0, 3], [4, 10]]},
    {"title": "The opposite of faith isn't doubt",
     "hook": "Stop cleaning up your prayers",
     "keywords": ["doubt", "faith", "questions"],
     "ranges": [[32, 38]]},
]

lines = [l.strip() for l in open(os.path.join(HERE, "script.txt")) if l.strip()]
words, t, parts = [], 0.0, []
with tempfile.TemporaryDirectory() as tmp:
    silence = os.path.join(tmp, "gap.wav")
    subprocess.run([FF, "-y", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-t", str(GAP), silence], check=True)
    for n, line in enumerate(lines):
        aiff, wav = os.path.join(tmp, f"{n}.aiff"), os.path.join(tmp, f"{n}.wav")
        subprocess.run(["say", "-v", VOICE, "-r", "165", "-o", aiff, line], check=True)
        subprocess.run([FF, "-y", "-v", "error", "-i", aiff, "-ar", "44100", "-ac", "1", wav], check=True)
        dur = float(subprocess.check_output(["/opt/homebrew/bin/ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", wav]))
        tokens = line.split()
        total = sum(len(w) + 2 for w in tokens)
        at = t + 0.03
        span = max(0.1, dur - 0.08)
        for w in tokens:
            d = span * (len(w) + 2) / total
            words.append({"w": w, "s": round(at, 3), "e": round(at + d - 0.02, 3)})
            at += d
        t += dur + GAP
        parts += [wav, silence]
    listing = os.path.join(tmp, "list.txt")
    with open(listing, "w") as f:
        f.writelines(f"file '{p}'\n" for p in parts)
    audio = os.path.join(tmp, "all.wav")
    subprocess.run([FF, "-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", listing, "-c", "copy", audio], check=True)
    out = os.path.join(HERE, "sample-sermon.mp4")
    subprocess.run([FF, "-y", "-v", "error",
                    "-f", "lavfi", "-i", f"gradients=s=1920x1080:c0=0x1d2b3a:c1=0x6e4a34:x0=0:y0=0:x1=1920:y1=1080:speed=0.004:d={t:.2f}:r=30",
                    "-i", audio, "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "30",
                    "-preset", "medium", "-g", "30", "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", "-shortest", out], check=True)

with open(os.path.join(HERE, "sample-sermon.json"), "w") as f:
    json.dump({"title": "Sample sermon: Stay in the room", "words": words, "reels": REELS}, f, ensure_ascii=False)
print(f"{len(lines)} sentences, {t:.1f}s, {os.path.getsize(out)/1e6:.1f} MB")
for r in REELS:
    print(r["title"], [" … ".join((lines[a][:30], lines[b][:30])) for a, b in r["ranges"]])
