#!/usr/bin/env python3
"""make_video.py — Assemble a narrated video from generated stills + TTS voiceover.

Input: a JSON spec file:
{
  "out": "videos/launch.mp4",
  "resolution": [1920, 1080],
  "voiceover": "videos/launch-vo.mp3",          # optional; else --duration-per-slide
  "music": "videos/music.mp3",                  # optional, ducked under VO
  "music_volume": 0.12,
  "slide_min_seconds": 3.0,
  "slides": [
    {"image": "videos/frames/01.png", "caption": "Subtitle text for this beat."},
    ...
  ]
}

Slide durations are computed by distributing the voiceover length across slides
weighted by caption word count (min slide_min_seconds each). If no voiceover,
each slide gets slide_min_seconds.

Output: H.264 mp4 with ken-burns motion, crossfades, burned-in captions, VO (+music).
"""
import json, subprocess, sys, os, math, tempfile

W, H_DEFAULT = 1920, 1080
FPS = 30
XFADE = 0.6  # crossfade seconds


def sh(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if r.returncode != 0:
        print("FFMPEG FAIL:", r.stderr[-3000:], file=sys.stderr)
        sys.exit(1)
    return r.stdout


def probe_duration(path):
    out = sh(f'ffprobe -v error -show_entries format=duration -of csv=p=0 "{path}"')
    return float(out.strip())


def srt_time(t):
    h = int(t // 3600); m = int((t % 3600) // 60); s = t % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}".replace(".", ",")


def main(spec_path):
    spec = json.load(open(spec_path))
    Wd, Hd = spec.get("resolution", [W, H_DEFAULT])
    slides = spec["slides"]
    n = len(slides)
    assert n >= 2, "need >=2 slides"

    vo = spec.get("voiceover")
    vo_dur = probe_duration(vo) if vo else None

    # Distribute durations weighted by caption length
    weights = [max(3, len(s.get("caption", "").split())) for s in slides]
    total_w = sum(weights)
    total = vo_dur if vo_dur else spec.get("slide_min_seconds", 3.0) * n
    durs = [max(spec.get("slide_min_seconds", 3.0), total * w / total_w) for w in weights]
    # rescale to exactly match VO if present
    if vo_dur:
        scale = vo_dur / sum(durs)
        durs = [d * scale for d in durs]
    total = sum(durs)

    workdir = tempfile.mkdtemp(prefix="mkv_")
    # 1. Per-slide ken-burns clips
    clip_paths = []
    for i, (s, d) in enumerate(zip(slides, durs)):
        frames = int(d * FPS) + int(XFADE * FPS)
        zoom_dir = "in" if i % 2 == 0 else "out"
        zexpr = ("min(zoom+0.0009,1.12)" if zoom_dir == "in" else "max(1.12-0.0009*on,1.0)")
        cp = os.path.join(workdir, f"clip{i:02d}.mp4")
        sh(
            f'ffmpeg -y -loop 1 -i "{s["image"]}" -filter_complex '
            f'"[0:v]scale={Wd*2}:{Hd*2}:force_original_aspect_ratio=increase,'
            f'crop={Wd*2}:{Hd*2},zoompan=z=\'{zexpr}\':x=\'iw/2-(iw/zoom/2)\':y=\'ih/2-(ih/zoom/2)\':'
            f'd={frames}:s={Wd}x{Hd}:fps={FPS},format=yuv420p[v]" -map "[v]" '
            f'-t {d + XFADE} -c:v libx264 -preset medium -crf 20 "{cp}"'
        )
        clip_paths.append(cp)

    # 2. xfade chain
    inputs = " ".join(f'-i "{c}"' for c in clip_paths)
    filters, prev, offset = [], "0:v", 0.0
    for i in range(1, n):
        offset += durs[i - 1] - (XFADE if i > 1 else 0)
        out = f"x{i}"
        filters.append(f'[{prev}][{i}:v]xfade=transition=fade:duration={XFADE}:offset={max(0.1, offset):.2f}[{out}]')
        prev = out
    sh(f'ffmpeg -y {inputs} -filter_complex "{";".join(filters)}" -map "[{prev}]" '
       f'-c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p "{workdir}/video.mp4"')

    # 3. Captions -> SRT, burn in
    srt = os.path.join(workdir, "caps.srt")
    t = 0.0
    with open(srt, "w") as f:
        for i, (s, d) in enumerate(zip(slides, durs)):
            cap = s.get("caption", "").strip()
            if not cap:
                t += d; continue
            f.write(f"{i+1}\n{srt_time(t)} --> {srt_time(t + d - 0.15)}\n{cap}\n\n")
            t += d
    style = ("FontName=DejaVu Sans,FontSize=22,PrimaryColour=&H00FFFFFF,"
             "OutlineColour=&H7A000000,BorderStyle=1,Outline=2,Shadow=1,"
             "MarginV=48,Alignment=2")
    sh(f'ffmpeg -y -i "{workdir}/video.mp4" -vf "subtitles=\'{srt}\':force_style=\'{style}\'" '
       f'-c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p "{workdir}/video_sub.mp4"')

    # 4. Audio: VO (+ ducked music)
    music = spec.get("music")
    out = spec["out"]
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    if vo and music:
        mv = spec.get("music_volume", 0.12)
        sh(f'ffmpeg -y -i "{workdir}/video_sub.mp4" -i "{vo}" -i "{music}" -filter_complex '
           f'"[2:a]volume={mv},afade=t=in:st=0:d=2,afade=t=out:st={total-3:.1f}:d=3[m];'
           f'[1:a][m]amix=inputs=2:duration=first:dropout_transition=2[a]" '
           f'-map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k -shortest "{out}"')
    elif vo:
        sh(f'ffmpeg -y -i "{workdir}/video_sub.mp4" -i "{vo}" -map 0:v -map 1:a '
           f'-c:v copy -c:a aac -b:a 192k -shortest "{out}"')
    else:
        sh(f'ffmpeg -y -i "{workdir}/video_sub.mp4" -c:v copy -an "{out}"')

    dur = probe_duration(out)
    print(f"DONE {out}  ({dur:.1f}s, {n} slides)")


if __name__ == "__main__":
    main(sys.argv[1])
