#!/usr/bin/env python3
"""Makes the built-in sample from a stretch of a real sermon you have the rights to.

AutoClip must have transcribed the video already (make reels from it once). Then:

    python3 make-sample-from-sermon.py "/path/to/sermon.mp4" 12:30 15:10 "Sample sermon: Title"

It writes sample-sermon.mp4 and sample-sermon.json next to this script and prints the three
reels it picked. Change the "ranges" in the JSON if you'd like different ones (sentence numbers
are printed), then rebuild AutoClip.
"""
import json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
FF = "/opt/homebrew/bin/ffmpeg"
LEADS = ("and ", "so ", "but ", "because ", "that ", "this ", "it ", "he ", "she ", "they ", "then ", "or ", "these ", "those ", "which ")
STRONG = ("never", "stop", "secret", "why", "how", "truth", "mistake", "nobody", "everyone", "always", "wrong", "what if", "the reason")

def seconds(t):
    parts = [float(p) for p in t.split(":")]
    v = 0.0
    for p in parts: v = v * 60 + p
    return v

def transcript_path(video):
    # Same name AutoClip uses (TranscriptCache.file): FNV-1a of the path
    h = 0xcbf29ce484222325
    for b in video.encode("utf-8"):
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    base = os.path.splitext(os.path.basename(video))[0][:60]
    home = os.environ.get("AUTOCLIP_HOME", os.path.expanduser("~"))
    return os.path.join(home, "Documents/AutoClip/Transcripts", f"{base}-v2-{h % 1000000007}.json")

def sentences(words):
    out, cur = [], []
    for w in words:
        cur.append(w)
        if w["w"] and w["w"][-1] in '.!?"”':
            out.append(cur); cur = []
    if cur: out.append(cur)
    return out

def score(text):
    t = text.lower(); n = len(t.split()); v = 0
    if 4 <= n <= 16: v += 2
    if n > 24: v -= 2
    if "?" in t: v += 3
    if " you" in " " + t: v += 1
    v += sum(2 for s in STRONG if s in t)
    if t.startswith(LEADS): v -= 6
    return v

def main():
    if len(sys.argv) < 4: sys.exit(__doc__)
    video, start, end = os.path.abspath(sys.argv[1]), seconds(sys.argv[2]), seconds(sys.argv[3])
    title = sys.argv[4] if len(sys.argv) > 4 else "Sample sermon"
    out_dir = os.environ.get("SAMPLE_OUT", HERE)
    tp = transcript_path(video)
    if not os.path.exists(tp): sys.exit(f"No transcript at {tp}. Make reels from this video in AutoClip first.")
    words = [{"w": w["word"], "s": round(w["startTime"] - start, 3), "e": round(w["endTime"] - start, 3)}
             for w in json.load(open(tp)) if start <= w["startTime"] and w["endTime"] <= end]
    if len(words) < 50: sys.exit("That stretch has very few words. Check the start and end times.")
    sents = sentences(words)
    # Windows of whole sentences, 15 to 45 seconds, that stand on their own
    windows = []
    for a in range(len(sents)):
        for b in range(a, len(sents)):
            dur = sents[b][-1]["e"] - sents[a][0]["s"]
            if dur > 45: break
            if dur >= 15:
                text = " ".join(w["w"] for w in sents[a])
                windows.append((score(text) - abs(dur - 28) / 10, a, b))
    picked = []
    for sc, a, b in sorted(windows, reverse=True):
        if all(b < pa or a > pb for _, pa, pb in picked): picked.append((sc, a, b))
        if len(picked) == 3: break
    if not picked: sys.exit("Couldn't find clip-sized moments in that stretch. Try a longer one.")
    reels = []
    for _, a, b in sorted(picked, key=lambda p: p[1]):
        first = " ".join(w["w"] for w in sents[a]).strip()
        reels.append({"title": " ".join(first.split()[:8]).rstrip(",.;:"), "ranges": [[a, b]]})
    mp4 = os.path.join(out_dir, "sample-sermon.mp4")
    subprocess.run([FF, "-y", "-v", "error", "-ss", f"{start:.2f}", "-to", f"{end:.2f}", "-i", video,
                    "-vf", "scale=-2:'min(720,ih)'", "-c:v", "libx264", "-crf", "27", "-preset", "medium", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", mp4], check=True)
    json.dump({"title": title, "words": words, "reels": reels}, open(os.path.join(out_dir, "sample-sermon.json"), "w"), ensure_ascii=False)
    print(f"{len(sents)} sentences, {end - start:.0f}s, {os.path.getsize(mp4) / 1e6:.1f} MB")
    for r in reels:
        a, b = r["ranges"][0]
        print(f'[{a}-{b}] {r["title"]}')
    print("\nSentences:")
    for i, s in enumerate(sents):
        print(f"{i:3d} {' '.join(w['w'] for w in s)[:100]}")

if __name__ == "__main__":
    main()
