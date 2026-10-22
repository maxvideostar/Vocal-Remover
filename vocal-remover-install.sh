#!/bin/bash
# ============================================================
#  Vocal Remover (Demucs AI) + YouTube Downloader + Web UI
#  Ubuntu 22.04 / 24.04
#
#  Rulare:      sudo bash vocal-remover-install.sh
#  Acces:       http://IP-SERVER:8095
#  Subtitrări:  http://IP-SERVER:8095/subtitrari/   (pagină separată, cu parolă)
#  Extern:      https://DOMENIU/vocal/  și  https://DOMENIU/subtitrari/
#  Parolă nouă pentru Subtitrări:  sudo subtitrari-parola
#
#  Variabile opționale (pentru rulare neinteractivă):
#    DOMAIN=testcam.go.ro  SETUP_NGINX=yes|no  VR_USER=admin  VR_PASS=parola
#    SUB_USER=admin  SUB_PASS=parola
# ============================================================
set -e
[ "$EUID" -ne 0 ] && { echo "Rulează cu sudo!"; exit 1; }

APPUSER="${SUDO_USER:-netstreaming}"
BASE="/opt/vocal-remover"
PORT=8095
DOMAIN="${DOMAIN:-testcam.go.ro}"
SETUP_NGINX="${SETUP_NGINX:-ask}"

# ---------- întrebări la început, ca restul să ruleze nesupravegheat ----------
if [ "$SETUP_NGINX" = "ask" ]; then
  SETUP_NGINX=no
  if [ -t 0 ]; then
    read -rp "Configurez acces extern pe $DOMAIN/vocal/ prin nginx cu parolă? [d/N] " a
    [[ "$a" =~ ^[dDyY] ]] && SETUP_NGINX=yes
  fi
fi
if [ "$SETUP_NGINX" = "yes" ]; then
  if [ -z "$VR_USER" ]; then read -rp "Utilizator [admin]: " VR_USER; VR_USER="${VR_USER:-admin}"; fi
  while [ -z "$VR_PASS" ]; do
    read -rsp "Parolă: " VR_PASS; echo
    read -rsp "Confirmă parola: " p2; echo
    [ "$VR_PASS" != "$p2" ] && { echo "Parolele nu coincid."; VR_PASS=""; }
  done
fi

# parola paginii Subtitrări (doar la prima instalare sau dacă e dată SUB_PASS)
SUB_GEN=""
if [ ! -f "$BASE/subauth.json" ] || [ -n "$SUB_PASS" ]; then
  if [ -z "$SUB_PASS" ] && [ -t 0 ]; then
    echo "Pagina 📝 Subtitrări are login separat."
    read -rp "Utilizator Subtitrări [admin]: " SUB_USER; SUB_USER="${SUB_USER:-admin}"
    while [ -z "$SUB_PASS" ]; do
      read -rsp "Parolă Subtitrări: " SUB_PASS; echo
      read -rsp "Confirmă parola: " p2; echo
      [ "$SUB_PASS" != "$p2" ] && { echo "Parolele nu coincid."; SUB_PASS=""; }
    done
  elif [ -z "$SUB_PASS" ]; then
    SUB_PASS=$(openssl rand -base64 12 2>/dev/null || date +%s%N | sha256sum | head -c 16); SUB_GEN=1
  fi
  SUB_USER="${SUB_USER:-admin}"
fi

echo "==> Pachete sistem..."
apt-get update -qq || echo "   ⚠ Unele repo-uri apt au erori (ignorat, continui)..."
apt-get install -y -qq python3-venv python3-pip ffmpeg curl unzip openssl >/dev/null

echo "==> Deno (necesar pentru yt-dlp pe YouTube)..."
if ! command -v deno >/dev/null 2>&1; then
  TMPD=$(mktemp -d)
  if curl -fsSL -o "$TMPD/deno.zip" \
      "https://github.com/denoland/deno/releases/latest/download/deno-$(uname -m)-unknown-linux-gnu.zip" \
     && unzip -qo "$TMPD/deno.zip" -d /usr/local/bin; then
    chmod +x /usr/local/bin/deno; echo "   OK $(deno --version | head -1)"
  else
    echo "   ⚠ Deno nu s-a putut instala (unele clipuri YouTube pot eșua)"
  fi
  rm -rf "$TMPD"
fi

echo "==> Mediu Python..."
mkdir -p "$BASE"/{uploads,output,youtube}
[ -x "$BASE/venv/bin/python" ] || python3 -m venv "$BASE/venv"
"$BASE/venv/bin/pip" install -q --upgrade pip wheel
# torch CPU (fixat pe 2.5.1 – compatibil sigur cu demucs)
"$BASE/venv/bin/pip" install -q torch==2.5.1 torchaudio==2.5.1 --index-url https://download.pytorch.org/whl/cpu
"$BASE/venv/bin/pip" install -q demucs==4.0.1 flask waitress soundfile "librosa>=0.10.2"
"$BASE/venv/bin/pip" install -q -U "yt-dlp[default]"
"$BASE/venv/bin/pip" install -q "faster-whisper>=1.1.0" "transformers>=4.44,<4.50" sentencepiece sacremoses
"$BASE/venv/bin/pip" install -q -U "av>=14"

echo "==> Modul subtitrări (Whisper)..."
mkdir -p "$BASE/whisper-models"
cat > "$BASE/transcribe.py" <<'PYEOF'
# Transcriere / traducere cu faster-whisper (+ traducere EN->RO cu Opus-MT) -> SRT, VTT, TXT
# task: transcribe | translate (-> engleză) | ro (-> română)
# Sursa poate fi audio/video sau direct un fișier .srt/.vtt (doar traducere)
# Ieșire pe stdout: "STAGE x", "LANG xx", "P nn", "DONE {...}"
import sys, os, re, json, textwrap
src, out, model, lang, task = sys.argv[1:6]
use_emb = (sys.argv[6] if len(sys.argv) > 6 else "1") == "1"
B = "/opt/vocal-remover"
os.environ.setdefault("HF_HOME", f"{B}/hf")
P = lambda n: print(f"P {max(0, min(99, int(n)))}", flush=True)

def read_subs(path):
    raw = open(path, "rb").read()
    for enc in ("utf-8-sig", "cp1250", "latin-1"):
        try: txt = raw.decode(enc); break
        except UnicodeDecodeError: pass
    txt = txt.replace("\r\n", "\n").replace("\r", "\n")
    def sec(t):
        t = t.replace(",", ".").strip().split()[0]
        parts = t.split(":")
        if len(parts) == 2: parts = ["0"] + parts
        h, m_, s_ = parts
        return int(h) * 3600 + int(m_) * 60 + float(s_)
    items = []
    for blk in re.split(r"\n\s*\n", txt):
        lines = [l for l in blk.strip().split("\n") if l.strip()]
        for n, l in enumerate(lines):
            if "-->" in l:
                a, b = l.split("-->")
                t = " ".join(re.sub(r"<[^>]+>|\{[^}]+\}", "", x).strip() for x in lines[n + 1:]).strip()
                if t: items.append((sec(a), sec(b), t))
                break
    return items

EN_W = re.compile(r"\b(the|you|and|is|to|it|that|what|this|i|i'm|don't|are|of|in|we|have)\b", re.I)

def find_emb(path):
    """Caută în fișierul video o subtitrare text (RO sau EN). Întoarce (index, limbă) sau None."""
    import subprocess
    r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "s", "-show_entries",
                        "stream=index,codec_name:stream_tags=language,title:stream_disposition=forced,hearing_impaired",
                        "-of", "json", path], capture_output=True, text=True)
    try: streams = json.loads(r.stdout).get("streams", [])
    except Exception: return []
    TEXT = {"subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text"}
    cands = []
    for st in streams:
        if st.get("codec_name") not in TEXT: continue          # PGS / VobSub sunt imagini -> nu se pot citi
        tg = {k.lower(): v for k, v in (st.get("tags") or {}).items()}
        lg, title = (tg.get("language") or "und").lower(), (tg.get("title") or "").lower()
        if lg in ("rum", "ron", "ro") or "rom" in title: code, sc = "ro", 30
        elif lg in ("eng", "en") or "english" in title: code, sc = "en", 20
        elif lg in ("und", ""): code, sc = "en?", 10                 # fără etichetă: verificăm textul
        else: continue
        d = st.get("disposition") or {}
        if d.get("forced") or "forced" in title: sc -= 25           # doar câteva replici
        if d.get("hearing_impaired") or "sdh" in title: sc -= 1
        cands.append((sc, st["index"], code))
    return sorted(cands, reverse=True)

def extract_emb(path, idx):
    import subprocess
    tmp = f"{out}/_emb.srt"
    r = subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", path,
                        "-map", f"0:{idx}", "-f", "srt", tmp], capture_output=True)
    if r.returncode != 0 or not os.path.exists(tmp): return []
    its = read_subs(tmp); os.remove(tmp)
    clean = []
    for a, b, t in its:
        t = re.sub(r"\[[^\]]*\]|♪+", "", t)                       # [MUZICĂ], [râde] etc.
        t = re.sub(r"^[A-Z][A-Z .']+:\s*", "", t.strip()).strip()   # NUME: replică (SDH)
        if t: clean.append((a, b, t))
    return clean

is_sub = os.path.splitext(src)[1].lower() in (".srt", ".vtt")
w_end = 99 if task != "ro" else 70     # cât din bara de progres ia Whisper
from_text = is_sub
items = None

if not is_sub and use_emb and task == "ro":
    print("STAGE emb", flush=True)
    for sc, idx, code in find_emb(src):
        its = extract_emb(src, idx)
        if len(its) < 20: continue                                   # prea puține replici (forced / gol)
        if code == "en?":
            words = " ".join(t for _, _, t in its[:300]).split()
            if not words or len(EN_W.findall(" ".join(words))) / len(words) < 0.06: continue
            code = "en"
        items, src_lang, from_text = its, code, True
        print(f"SRC emb:{code}", flush=True)
        break

if is_sub:
    print("STAGE run", flush=True)
    items = read_subs(src)
    src_lang = "en"
    print("SRC file", flush=True)
elif items is None:
    print("SRC audio", flush=True)
    import subprocess, numpy as np
    from faster_whisper import WhisperModel
    print("STAGE model", flush=True)
    m = WhisperModel(model, device="cpu", compute_type="int8", cpu_threads=os.cpu_count() or 4,
                     download_root=f"{B}/whisper-models")
    wl = None if lang == "auto" else lang
    wt = "translate" if task == "translate" else "transcribe"
    # audio extras cu ffmpeg (16 kHz mono) – funcționează cu orice format, fără PyAV
    print("STAGE audio", flush=True)
    r = subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-i", src, "-map", "0:a:0",
                        "-ac", "1", "-ar", "16000", "-f", "s16le", "-"], capture_output=True)
    if r.returncode != 0 or not r.stdout:
        raise SystemExit("Error: nu pot extrage sunetul: " + r.stderr.decode(errors="replace")[-300:])
    audio = np.frombuffer(r.stdout, np.int16).astype(np.float32) / 32768.0
    del r
    print("STAGE run", flush=True)
    segs, info = m.transcribe(audio, language=wl, task=wt, vad_filter=True, beam_size=5)
    src_lang = info.language
    if task == "ro" and src_lang not in ("en", "ro"):
        # altă limbă -> întâi în engleză cu Whisper, apoi în română
        segs, info = m.transcribe(audio, language=wl, task="translate", vad_filter=True, beam_size=5)
        src_lang = "en"
    dur = info.duration or 1
    items = []
    for sg in segs:
        t = sg.text.strip()
        if t: items.append((sg.start, sg.end, t))
        P(sg.end / dur * w_end)
    if task == "translate": src_lang = "en"

out_lang = src_lang
if task == "ro" and src_lang != "ro" and items:
    print("STAGE tr", flush=True)
    import torch
    from transformers import MarianMTModel, MarianTokenizer
    torch.set_num_threads(os.cpu_count() or 4)
    last = None
    for name in ("Helsinki-NLP/opus-mt-tc-big-en-ro", "Helsinki-NLP/opus-mt-en-ro"):
        try:
            tok = MarianTokenizer.from_pretrained(name); mt = MarianMTModel.from_pretrained(name).eval(); break
        except Exception as e:
            last = e; tok = None
    if tok is None: raise SystemExit(f"Error: nu pot încărca modelul de traducere: {last}")
    texts = [t for _, _, t in items]; res = []; bs = 16
    start = 0 if from_text else w_end
    for n in range(0, len(texts), bs):
        batch = texts[n:n + bs]
        enc = tok(batch, return_tensors="pt", padding=True, truncation=True, max_length=256)
        with torch.inference_mode():
            gen = mt.generate(**enc, num_beams=3, max_new_tokens=256)
        res += [x.strip() for x in tok.batch_decode(gen, skip_special_tokens=True)]
        P(start + (n + len(batch)) / len(texts) * (99 - start))
    # diacritice corecte (ș, ț cu virgulă)
    fix = str.maketrans({"ş": "ș", "Ş": "Ș", "ţ": "ț", "Ţ": "Ț"})
    items = [(a, b, r.translate(fix) or t) for (a, b, t), r in zip(items, res)]
    out_lang = "ro"
print("LANG " + out_lang, flush=True)

def ts(x, sep):
    ms = int(round(x * 1000)); h, ms = divmod(ms, 3600000); m_, ms = divmod(ms, 60000); s_, ms = divmod(ms, 1000)
    return f"{h:02}:{m_:02}:{s_:02}{sep}{ms:03}"
wrap = lambda t: "\n".join(textwrap.wrap(t, max(42, len(t) // 2 + 6))) if len(t) > 42 else t
with open(f"{out}/sub.srt", "w", encoding="utf-8") as f:
    for i, (a, b, t) in enumerate(items, 1): f.write(f"{i}\n{ts(a, ',')} --> {ts(b, ',')}\n{wrap(t)}\n\n")
with open(f"{out}/sub.vtt", "w", encoding="utf-8") as f:
    f.write("WEBVTT\n\n")
    for a, b, t in items: f.write(f"{ts(a, '.')} --> {ts(b, '.')}\n{wrap(t)}\n\n")
with open(f"{out}/sub.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(t for _, _, t in items) + "\n")
print("DONE " + json.dumps({"segs": len(items)}), flush=True)
PYEOF

echo "==> Modul analiză tonalitate / tempo..."
cat > "$BASE/analyze.py" <<'PYEOF'
# Detectează BPM și tonalitatea unui fișier WAV (mono). Afișează JSON.
import sys, json, warnings
warnings.filterwarnings("ignore")
import numpy as np, librosa
y, sr = librosa.load(sys.argv[1], sr=22050, mono=True)
yh, yp = librosa.effects.hpss(y)
tempo, _ = librosa.beat.beat_track(y=yp, sr=sr)
bpm = float(np.atleast_1d(tempo)[0])
chroma = librosa.feature.chroma_cqt(y=yh, sr=sr).mean(axis=1)
# profile Krumhansl-Schmuckler
MAJ = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
MIN = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
best = (-2.0, 0, "major")
for i in range(12):
    for prof, mode in ((MAJ, "major"), (MIN, "minor")):
        c = float(np.corrcoef(chroma, np.roll(prof, i))[0, 1])
        if c > best[0]: best = (c, i, mode)
print(json.dumps({"bpm": round(bpm, 1), "key": best[1], "kmode": best[2], "conf": round(best[0], 2)}))
PYEOF

echo "==> Aplicație web..."
cat > "$BASE/app.py" <<'PYEOF'
import os, re, uuid, glob, json, shutil, threading, queue, subprocess, time, functools, html, signal
from flask import Flask, request, jsonify, send_file, abort, Response, session, redirect
from werkzeug.security import check_password_hash

BASE = "/opt/vocal-remover"
UP, OUT, YTD = f"{BASE}/uploads", f"{BASE}/output", f"{BASE}/youtube"
DB = f"{BASE}/jobs.json"
PY = f"{BASE}/venv/bin/python"
YTDLP = f"{BASE}/venv/bin/yt-dlp"
for d in (UP, OUT, YTD): os.makedirs(d, exist_ok=True)

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 2 * 1024 ** 3
MODELS = {"htdemucs": "Rapid (htdemucs)",
          "htdemucs_ft": "Calitate maximă (htdemucs_ft, ~4x mai lent)",
          "mdx_extra": "MDX Extra (alternativ)"}
FMTS = {"mp3": ["--mp3", "--mp3-bitrate", "320"], "wav": [], "flac": ["--flac"]}
YT_FMTS = {"mp3": "🎵 MP3 320k", "best": "🎬 Video – calitate maximă (până la 4K)",
           "1080": "🎬 Video MP4 1080p", "720": "🎬 Video MP4 720p", "480": "🎬 Video MP4 480p"}
JUNK = (".part", ".ytdl", ".webp", ".jpg", ".jpeg", ".png", ".temp")
ENC = {"mp3": ["-c:a", "libmp3lame", "-b:a", "320k"], "wav": ["-c:a", "pcm_s16le"], "flac": ["-c:a", "flac"]}
TRACK_LABEL = {"vocals": "Voce", "instrumental": "Instrumental", "original": "Original",
               "drums": "Tobe", "bass": "Bas", "other": "Altele"}
STEMS4 = ("drums", "bass", "other")
def job_tracks(j):
    m = j.get("mode", "sep")
    return ["original"] if m == "ana" else ["vocals", "instrumental", *STEMS4] if m == "sep4" else ["vocals", "instrumental"]
try:
    HAS_RB = "rubberband" in subprocess.run(["ffmpeg", "-hide_banner", "-filters"],
                                            capture_output=True, text=True).stdout
except Exception:
    HAS_RB = False

WMODELS = {"medium": "Mediu (recomandat)",
           "large-v3-turbo": "Large v3 Turbo (cel mai precis)",
           "small": "Mic (rapid)"}
WLANGS = {"auto": "Detectare automată", "ro": "Română", "en": "English", "it": "Italiano", "es": "Español",
          "fr": "Français", "de": "Deutsch", "hu": "Magyar", "ru": "Русский", "tr": "Türkçe"}

lock = threading.RLock()
heavy = threading.Lock()  # Demucs și Whisper nu rulează simultan (CPU)
sq, yq, fxq, wq = queue.Queue(), queue.Queue(), queue.Queue(), queue.Queue()
jobs = {}

def save():
    with lock:
        tmp = DB + ".tmp"
        with open(tmp, "w") as f: json.dump(jobs, f)
        os.replace(tmp, DB)

def new_job(**kw):
    jid = uuid.uuid4().hex[:12]
    kw.update(id=jid, status="queued", progress=0, created=time.time())
    with lock: jobs[jid] = kw
    return jid

def load():
    global jobs
    if os.path.exists(DB):
        try: jobs = json.load(open(DB))
        except Exception: jobs = {}
    for jid, j in sorted(jobs.items(), key=lambda x: x[1].get("created", 0)):
        j.setdefault("type", "sep")
        if j["type"] == "sep": j.setdefault("mode", "sep")
        if j["status"] in ("queued", "processing"):
            j["progress"] = 0
            if j["type"] == "yt":
                j["status"] = "queued"; yq.put(jid)
            elif j["type"] == "sub" and os.path.exists(j.get("path", "")) and (not j.get("cvsrc") or cv_inside(j["path"])):
                j["status"] = "queued"; wq.put(jid)
            elif j["type"] == "sub":
                j["status"], j["error"] = "error", "Întrerupt la restart"
            elif os.path.exists(j.get("path", "")):
                j["status"] = "queued"
                if j["mode"] == "ana": fxq.put(("conv", jid))
                else: sq.put(jid)
            else:
                j["status"], j["error"] = "error", "Întrerupt la restart"
        if j["type"] == "sep" and j["status"] == "done":
            if j.get("ana") in (None, "queued", "processing"):
                j["ana"] = "queued"; fxq.put(("ana", jid))
            for s in j.get("shifts", []):
                if s["status"] in ("queued", "processing"):
                    s["status"] = "queued"; fxq.put(("shift", jid, s["id"]))

# ---------- oprire joburi ----------
procs = {}          # jid -> proces în lucru (grup propriu, ca să oprim și ffmpeg-ul pornit de el)
STOPPED = "⏹ Oprit de utilizator"

class Stopped(Exception): pass

def start_proc(jid, cmd):
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
                         errors="replace", start_new_session=True)
    procs[jid] = p
    return p

def stop_job(jid):
    j = jobs.get(jid)
    if j and j.get("status") in ("queued", "processing"):
        j["cancel"] = True
        if j["status"] == "queued": j.update(status="stopped", error=STOPPED)
    p = procs.get(jid)
    if p and p.poll() is None:
        try: os.killpg(p.pid, signal.SIGTERM)
        except Exception: pass
        try: p.wait(timeout=5)
        except Exception:
            try: os.killpg(p.pid, signal.SIGKILL)
            except Exception: pass
    save()

def check_stop(j):
    if j.get("cancel"): raise Stopped()

def run(cmd, j, pattern):
    p = start_proc(j["id"], cmd)
    log = []
    for line in p.stdout:
        log.append(line); log = log[-40:]
        m = re.search(pattern, line)
        if m: j["progress"] = int(float(m.group(1)))
        if j.get("type") == "yt" and j["name"] == j.get("url"):
            d = re.search(r"Destination: (.+)$", line.strip())
            if d: j["name"] = os.path.splitext(os.path.basename(d.group(1)))[0]
    p.wait()
    procs.pop(j["id"], None)
    check_stop(j)
    return p.returncode, log

def sep_worker():
    while True:
        jid = sq.get(); j = jobs.get(jid)
        if not j: continue
        if j.get("cancel"):
            try: os.remove(j["path"])
            except Exception: pass
            continue
        j["status"], j["progress"] = "processing", 0; save()
        od = os.path.join(OUT, jid)
        four = j.get("mode") == "sep4"
        cmd = [PY, "-m", "demucs", *([] if four else ["--two-stems=vocals"]), "-n", j["model"],
               "-o", od, *FMTS[j["fmt"]], j["path"]]
        try:
            with heavy: rc, log = run(cmd, j, r"(\d+)%\|")
            v = glob.glob(f"{od}/*/*/vocals.*")
            n = glob.glob(f"{od}/*/*/other.*" if four else f"{od}/*/*/no_vocals.*")
            if rc != 0 or not v or not n:
                raise RuntimeError("".join(log[-5:]) or "Demucs a eșuat")
            ext = v[0].rsplit(".", 1)[1]
            shutil.move(v[0], f"{od}/vocals.{ext}")
            if four:
                for st in STEMS4:
                    shutil.move(glob.glob(f"{od}/*/*/{st}.*")[0], f"{od}/{st}.{ext}")
                # instrumental = tobe + bas + altele
                ff(["-i", f"{od}/drums.{ext}", "-i", f"{od}/bass.{ext}", "-i", f"{od}/other.{ext}",
                    "-filter_complex", "amix=inputs=3:normalize=0", *ENC[ext], f"{od}/instrumental.{ext}"])
            else:
                shutil.move(n[0], f"{od}/instrumental.{ext}")
            for d in glob.glob(f"{od}/*/"): shutil.rmtree(d, ignore_errors=True)
            j.update(status="done", progress=100, ext=ext, finished=time.time(), ana="queued")
            fxq.put(("ana", jid))
            auto_shift(j)
        except Stopped:
            j.update(status="stopped", error=STOPPED); shutil.rmtree(od, ignore_errors=True)
        except Exception as e:
            j.update(status="error", error=str(e)[-400:])
        finally:
            try: os.remove(j["path"])
            except Exception: pass
            save()

def sub_worker():
    while True:
        jid = wq.get(); j = jobs.get(jid)
        if not j: continue
        if j.get("cancel"):
            if not j.get("cvsrc"):
                try: os.remove(j["path"])
                except Exception: pass
            continue
        j.update(status="processing", progress=0, stage="queued"); save()
        od = os.path.join(OUT, jid); os.makedirs(od, exist_ok=True)
        try:
            with heavy:
                check_stop(j)
                p = start_proc(jid, [PY, f"{BASE}/transcribe.py", j["path"], od, j["wmodel"], j["lang"], j["task"],
                                     "1" if j.get("emb", True) else "0"])
                log = []
                for line in p.stdout:
                    line = line.strip(); log.append(line); log = log[-40:]
                    if line.startswith("STAGE "): j["stage"] = line[6:]
                    elif line.startswith("LANG "): j["dlang"] = line[5:]
                    elif line.startswith("P "): j["progress"] = int(line[2:])
                    elif line.startswith("DONE "): j["segs"] = json.loads(line[5:])["segs"]
                    elif line.startswith("SRC "): j["srcinfo"] = line[4:]
                p.wait(); procs.pop(jid, None)
            check_stop(j)
            if p.returncode != 0 or not os.path.exists(f"{od}/sub.srt"):
                err = [l for l in log if "Error" in l or "error" in l]
                raise RuntimeError("\n".join(err[-3:] or log[-6:]) or "Whisper a eșuat")
            j.update(status="done", progress=100, finished=time.time())
            if j.get("cvsrc"):
                try: cv_put_sub(j, j["path"])
                except Exception as e: j["cverr"] = str(e)[-200:]
        except Stopped:
            j.update(status="stopped", error=STOPPED, stage=""); shutil.rmtree(od, ignore_errors=True)
        except Exception as e:
            j.update(status="error", error=str(e)[-400:])
        finally:
            if not j.get("cvsrc"):
                try: os.remove(j["path"])
                except Exception: pass
            save()

def yt_worker():
    while True:
        jid = yq.get(); j = jobs.get(jid)
        if not j or j.get("cancel"): continue
        j["status"], j["progress"] = "processing", 0; save()
        od = os.path.join(YTD, jid)
        shutil.rmtree(od, ignore_errors=True); os.makedirs(od)
        f = j["fmt"]
        cmd = [YTDLP, "--no-playlist", "--newline", "--no-mtime", "--no-colors",
               "-P", od, "-o", "%(title).150B.%(ext)s", "--embed-metadata"]
        if f == "mp3":
            cmd += ["-x", "--audio-format", "mp3", "--audio-quality", "0", "--embed-thumbnail"]
        elif f == "best":
            cmd += ["-f", "bv*+ba/b", "--merge-output-format", "mp4"]
        else:
            h = f"[height<={f}]"
            cmd += ["-f", f"bv*{h}[vcodec^=avc1]+ba[ext=m4a]/bv*{h}+ba/b{h}/b",
                    "--merge-output-format", "mp4"]
        cmd += ["--", j["url"]]
        try:
            rc, log = run(cmd, j, r"\[download\]\s+([\d.]+)%")
            files = [x for x in glob.glob(f"{od}/*")
                     if os.path.isfile(x) and not x.lower().endswith(JUNK)]
            if rc != 0 or not files:
                err = [l for l in log if "ERROR" in l]
                raise RuntimeError("".join(err[-3:] or log[-5:]) or "Descărcare eșuată")
            fp = max(files, key=os.path.getsize)
            j.update(status="done", progress=100, file=fp, ext=fp.rsplit(".", 1)[1].lower(),
                     name=os.path.splitext(os.path.basename(fp))[0], finished=time.time())
            if j.get("sep") and f == "mp3":
                sid = new_job(type="sep", mode="sep", name=j["name"], path="", model=j.get("model", "htdemucs"), fmt="mp3")
                path = os.path.join(UP, sid + ".mp3")
                shutil.copy(fp, path)
                jobs[sid]["path"] = path
                sq.put(sid)
        except Stopped:
            j.update(status="stopped", error=STOPPED); shutil.rmtree(od, ignore_errors=True)
        except Exception as e:
            j.update(status="error", error=str(e)[-400:])
            shutil.rmtree(od, ignore_errors=True)
        finally:
            save()

# ---------- tonalitate / tempo ----------
def ff(args, timeout=3600):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args],
                       capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0: raise RuntimeError(r.stderr[-400:] or "ffmpeg a eșuat")

def track_file(j, track):
    return f"{OUT}/{j['id']}/{track}.{j['ext']}"

def do_conv(jid):
    """Mod „doar tonalitate/tempo”: convertește originalul, fără separare."""
    j = jobs.get(jid)
    if not j: return
    j["status"], j["progress"] = "processing", 50; save()
    od = os.path.join(OUT, jid); os.makedirs(od, exist_ok=True)
    try:
        ff(["-i", j["path"], "-vn", "-map", "0:a:0", *ENC[j["fmt"]], f"{od}/original.{j['fmt']}"])
        j.update(status="done", progress=100, ext=j["fmt"], finished=time.time(), ana="queued")
        auto_shift(j)
    except Exception as e:
        j.update(status="error", error=str(e)[-400:])
    finally:
        try: os.remove(j["path"])
        except Exception: pass
        save()
    if j["status"] == "done": do_ana(jid)

def do_ana(jid):
    j = jobs.get(jid)
    if not j or j.get("status") != "done": return
    j["ana"] = "processing"; save()
    src = track_file(j, "original" if j.get("mode") == "ana" else "instrumental")
    tmp = f"{OUT}/{jid}/_ana.wav"
    try:
        ff(["-i", src, "-ac", "1", "-ar", "22050", "-t", "900", tmp])
        r = subprocess.run([PY, f"{BASE}/analyze.py", tmp], capture_output=True, text=True, timeout=900)
        res = json.loads(r.stdout.strip().splitlines()[-1])
        j.update(key=res["key"], kmode=res["kmode"], bpm=res["bpm"], ana="done")
    except Exception as e:
        j["ana"] = "error"; print("analiză eșuată:", jid, e, flush=True)
    finally:
        try: os.remove(tmp)
        except Exception: pass
        save()

def atempo_chain(x):
    parts = []
    while x > 2.0: parts.append("atempo=2.0"); x /= 2.0
    while x < 0.5: parts.append("atempo=0.5"); x /= 0.5
    parts.append(f"atempo={x:.6f}")
    return ",".join(parts)

def do_shift(jid, sid):
    j = jobs.get(jid)
    if not j: return
    s = next((x for x in j.get("shifts", []) if x["id"] == sid), None)
    if not s: return
    s["status"] = "processing"; save()
    P, T = 2 ** (s["semi"] / 12), s["tempo"] / 100
    try:
        if HAS_RB:
            af = f"rubberband=pitch={P:.6f}:tempo={T:.4f}:pitchq=quality"
            if s["track"] == "vocals": af += ":formant=preserved"
        else:
            sr = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
                                 "stream=sample_rate", "-of", "csv=p=0", track_file(j, s["track"])],
                                capture_output=True, text=True).stdout.strip() or "44100"
            sr = int(sr)
            af = f"asetrate={sr * P:.0f},aresample={sr},{atempo_chain(T / P)}"
        out = f"{OUT}/{jid}/shift_{sid}.{j['ext']}"
        ff(["-i", track_file(j, s["track"]), "-vn", "-af", af, *ENC[j["ext"]], out])
        s["status"] = "done"
    except Exception as e:
        s.update(status="error", error=str(e)[-300:])
    finally:
        save()

def add_shifts(j, semi, tempo, track):
    tracks = ["instrumental", "vocals"] if track == "both" else [track]
    for t in tracks:
        sid = uuid.uuid4().hex[:8]
        j.setdefault("shifts", []).append(dict(id=sid, track=t, semi=semi, tempo=tempo, status="queued"))
        fxq.put(("shift", j["id"], sid))

def auto_shift(j):
    a = j.pop("auto", None)
    if a: add_shifts(j, a["semi"], a["tempo"], "original" if j.get("mode") == "ana" else a["track"])

# ---------- CineVerse ----------
CVCONF = f"{BASE}/cineverse.json"
_cvcache = {"t": 0, "files": []}
def cv_dirs():
    try: return [d for d in json.load(open(CVCONF)).get("dirs", []) if os.path.isdir(d)]
    except Exception: return []

def cv_inside(path):
    # verificăm calea așa cum apare în bibliotecă (fără a urmări symlink-urile:
    # biblioteca poate conține link-uri către fișiere aflate în alt folder)
    if not path or not os.path.isabs(path): return False
    np = os.path.normpath(path)
    for d in cv_dirs():
        for root in {os.path.normpath(d), os.path.realpath(d)}:
            if np == root or np.startswith(root.rstrip(os.sep) + os.sep): return True
    return False

def cv_files():
    if time.time() - _cvcache["t"] < 120: return _cvcache["files"]
    out = []
    for root in cv_dirs():
        for dp, dn, fn in os.walk(root, followlinks=True):
            dn[:] = [d for d in dn if not d.startswith(".") and d.lower() not in ("sample", "samples", "extras")]
            for f in fn:
                if os.path.splitext(f)[1].lower() in CV_VIDEO and not f.startswith(".") and "sample" not in f.lower():
                    out.append(os.path.join(dp, f))
    out.sort(key=lambda x: x.lower())
    _cvcache.update(t=time.time(), files=out)
    return out
CV_VIDEO = {".mkv", ".mp4", ".m4v", ".avi", ".mov", ".wmv", ".ts", ".m2ts", ".webm", ".mpg", ".mpeg"}

def cv_copy(src, dst):
    """Copiază atomic (fișier ascuns .part -> redenumire), ca CineVerse să-l vadă doar complet."""
    tmp = os.path.join(os.path.dirname(dst), "." + os.path.basename(dst) + ".part")
    shutil.copyfile(src, tmp)
    os.chmod(tmp, 0o664)
    os.replace(tmp, dst)
    _cvcache["t"] = 0

def safe_name(n):
    return re.sub(r'[\\/:*?"<>|]+', " ", n).strip()[:150] or "video"

def cv_put_sub(j, video):
    lg = j.get("dlang") or "und"
    stem = os.path.splitext(video)[0]
    dst = f"{stem}.{lg}.srt"
    if os.path.exists(dst): dst = f"{stem}.{lg}.whisper.srt"
    cv_copy(f"{OUT}/{j['id']}/sub.srt", dst)
    j["cv"] = dst
    return dst

def fx_worker():
    while True:
        t = fxq.get()
        try:
            {"conv": do_conv, "ana": do_ana, "shift": do_shift}[t[0]](*t[1:])
        except Exception as e:
            print("fx eroare:", t, e, flush=True)

@app.route("/")
def index():
    o = lambda d: "".join(f'<option value="{k}">{v}</option>' for k, v in d.items())
    return Response(HTML.replace("%MODELS%", o(MODELS)).replace("%YTFMTS%", o(YT_FMTS))
                    .replace("%WMODELS%", o(WMODELS)).replace("%WLANGS%", o(WLANGS)),
                    mimetype="text/html")

@app.route("/upload", methods=["POST"])
def upload():
    model = request.form.get("model", "htdemucs")
    fmt = request.form.get("fmt", "mp3")
    mode = request.form.get("mode", "sep")
    if model not in MODELS or fmt not in FMTS or mode not in ("sep", "sep4", "ana"): abort(400)
    try:
        semi = max(-12, min(12, int(request.form.get("semi", 0))))
        tempo = max(50, min(150, int(request.form.get("tempo", 100))))
    except ValueError: abort(400)
    track = request.form.get("track", "instrumental")
    if track not in ("instrumental", "vocals", "both"): track = "instrumental"
    auto = dict(semi=semi, tempo=tempo, track=track) if (semi or tempo != 100) else None
    ids = []
    for f in request.files.getlist("files"):
        if not f.filename: continue
        ext = os.path.splitext(f.filename)[1].lower() or ".bin"
        jid = new_job(type="sep", mode=mode, name=os.path.splitext(f.filename)[0], path="",
                      model=model if mode != "ana" else "—", fmt=fmt)
        path = os.path.join(UP, jid + ext); f.save(path)
        jobs[jid]["path"] = path
        if auto: jobs[jid]["auto"] = dict(auto)
        if mode == "ana": fxq.put(("conv", jid))
        else: sq.put(jid)
        ids.append(jid)
    save()
    return jsonify(ids)

# ======================= Subtitrări (pagină separată, cu parolă) =======================
AUTHF, SECRETF = f"{BASE}/subauth.json", f"{BASE}/.secret"
if not os.path.exists(SECRETF):
    with open(SECRETF, "w") as f: f.write(uuid.uuid4().hex + uuid.uuid4().hex)
    os.chmod(SECRETF, 0o600)
app.secret_key = open(SECRETF).read().strip()
app.config.update(SESSION_COOKIE_NAME="vr_subs", SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE="Lax",
                  PERMANENT_SESSION_LIFETIME=30 * 86400)
_fails = {}

def sub_auth():
    try: return json.load(open(AUTHF))
    except Exception: return None

def authed():
    a = sub_auth()
    return bool(a) and session.get("u") == a["user"] and session.get("v") == a["hash"][-12:]

def client_ip():
    ip = request.remote_addr or ""
    return request.headers.get("X-Real-IP", ip) if ip in ("127.0.0.1", "::1") else ip

def need_auth(f):
    @functools.wraps(f)
    def w(*a, **k):
        if authed(): return f(*a, **k)
        if request.path.startswith("/subtitrari/api/"): return jsonify(error="Neautentificat"), 401
        return redirect("/subtitrari/login")
    return w

@app.route("/subtitrari")
def subs_noslash(): return redirect("/subtitrari/")

@app.route("/subtitrari/login", methods=["GET", "POST"])
def subs_login():
    a, msg = sub_auth(), ""
    if not a:
        msg = "Parola nu e setată. Pe server rulează: <code>sudo subtitrari-parola</code>"
    elif request.method == "POST":
        ip, now = client_ip(), time.time()
        _fails[ip] = [t for t in _fails.get(ip, []) if now - t < 600]
        if len(_fails[ip]) >= 5:
            msg = "Prea multe încercări greșite. Încearcă din nou peste 10 minute."
        elif request.form.get("u", "") == a["user"] and check_password_hash(a["hash"], request.form.get("p", "")):
            session.clear(); session.permanent = request.form.get("r") == "1"
            session.update(u=a["user"], v=a["hash"][-12:])
            _fails.pop(ip, None)
            return redirect("/subtitrari/")
        else:
            _fails[ip].append(now); time.sleep(1)
            msg = "Utilizator sau parolă greșită."
    return Response(LOGIN.replace("%CSS%", CSS).replace("%MSG%", f'<div class="err">{msg}</div>' if msg else ""),
                    mimetype="text/html")

@app.route("/subtitrari/logout")
def subs_logout():
    session.clear(); return redirect("/subtitrari/login")

@app.route("/subtitrari/")
@need_auth
def subs_page():
    o = lambda d: "".join(f'<option value="{k}">{v}</option>' for k, v in d.items())
    return Response(SUBHTML.replace("%CSS%", CSS).replace("%WMODELS%", o(WMODELS)).replace("%WLANGS%", o(WLANGS))
                    .replace("%USER%", html.escape(session.get("u", ""))), mimetype="text/html")

@app.route("/subtitrari/api/upload", methods=["POST"])
@need_auth
def subupload():
    wm, lang = request.form.get("wmodel", "medium"), request.form.get("lang", "auto")
    task = request.form.get("task", "transcribe")
    if wm not in WMODELS or lang not in WLANGS or task not in ("transcribe", "translate", "ro"): abort(400)
    ids = []
    for f in request.files.getlist("files"):
        if not f.filename: continue
        ext = os.path.splitext(f.filename)[1].lower() or ".bin"
        is_sub = ext in (".srt", ".vtt")
        nm = os.path.splitext(f.filename)[0]
        if is_sub: nm = re.sub(r"[._-](en|eng|english)$", "", nm, flags=re.I)
        jid = new_job(type="sub", name=nm, path="", wmodel="—" if is_sub else wm, lang=lang,
                      task="ro" if is_sub else task, emb=request.form.get("emb", "1") == "1")
        path = os.path.join(UP, jid + ext); f.save(path)
        jobs[jid]["path"] = path
        wq.put(jid); ids.append(jid)
    save()
    return jsonify(ids)

@app.route("/cv")
def cv_info():
    ds = cv_dirs()
    return jsonify(enabled=bool(ds), dirs=[{"i": i, "name": os.path.basename(d.rstrip("/")) or d, "path": d} for i, d in enumerate(ds)])

@app.route("/subtitrari/api/cv")
@need_auth
def subs_cv_info(): return cv_info()

@app.route("/subtitrari/api/videos")
@need_auth
def cv_videos():
    words = request.args.get("q", "").lower().split()
    roots = cv_dirs(); res = []
    for f in cv_files():
        rel = f
        for r in roots:
            if f.startswith(r.rstrip("/") + "/"): rel = f[len(r.rstrip("/")) + 1:]; break
        if all(w in rel.lower() for w in words):
            res.append({"path": f, "rel": rel})
            if len(res) >= 60: break
    return jsonify(res)

@app.route("/subtitrari/api/fromcv", methods=["POST"])
@need_auth
def subcv():
    wm, lang = request.form.get("wmodel", "medium"), request.form.get("lang", "auto")
    task = request.form.get("task", "transcribe")
    if wm not in WMODELS or lang not in WLANGS or task not in ("transcribe", "translate", "ro"): abort(400)
    ids, errs = [], []
    paths = request.form.getlist("paths")
    for pth in paths:
        nm = os.path.basename(pth)
        if not cv_inside(pth):
            errs.append(f"{nm}: nu e într-un folder CineVerse")
        elif not os.path.isfile(pth):
            errs.append(f"{nm}: fișierul nu există")
        elif not os.access(pth, os.R_OK):
            errs.append(f"{nm}: fără drept de citire (rulează din nou installer-ul)")
        else:
            jid = new_job(type="sub", name=os.path.splitext(nm)[0], path=pth, cvsrc=True,
                          wmodel=wm, lang=lang, task=task, emb=request.form.get("emb", "1") == "1")
            wq.put(jid); ids.append(jid)
    for e in errs: print("subtitrare CineVerse:", e, flush=True)
    if not paths: errs.append("Niciun film selectat")
    save()
    return jsonify(ids=ids, errors=errs)

@app.route("/subtitrari/api/send/<jid>", methods=["POST"])
@need_auth
def subs_send(jid):
    j = jobs.get(jid)
    if not j or j.get("type") != "sub": abort(404)
    return cv_send_job(j)

@app.route("/cv/send/<jid>", methods=["POST"])
def cv_send(jid):
    j = jobs.get(jid)
    if not j or j.get("type") != "yt": abort(404)
    return cv_send_job(j)

def cv_send_job(j):
    if j["status"] != "done": abort(404)
    ds = cv_dirs()
    if not ds: return jsonify(ok=False, error="CineVerse nu e configurat"), 400
    try:
        if j["type"] == "sub":
            v = request.form.get("video", "")
            if not (os.path.isfile(v) and cv_inside(v)): return jsonify(ok=False, error="Alege un film din CineVerse"), 400
            dst = cv_put_sub(j, v)
        elif j["type"] == "yt" and j.get("ext") in ("mp4", "mkv", "webm"):
            i = int(request.form.get("dir", 0))
            if not 0 <= i < len(ds): abort(400)
            sub = safe_name(request.form.get("sub", "").strip()) if request.form.get("sub", "").strip() else ""
            d = os.path.join(ds[i], sub) if sub else ds[i]
            os.makedirs(d, exist_ok=True)
            dst = os.path.join(d, safe_name(j["name"]) + "." + j["ext"])
            cv_copy(j["file"], dst); j["cv"] = dst
        else:
            abort(400)
    except PermissionError:
        return jsonify(ok=False, error="Fără drept de scriere în folderul CineVerse (rulează din nou installer-ul)"), 400
    save()
    return jsonify(ok=True, path=dst)

@app.route("/yt", methods=["POST"])
def yt():
    fmt = request.form.get("fmt", "mp3")
    model = request.form.get("model", "htdemucs")
    if fmt not in YT_FMTS or model not in MODELS: abort(400)
    sep = request.form.get("sep") == "1"
    urls = [u for u in re.split(r"\s+", request.form.get("urls", "")) if re.match(r"https?://\S+$", u)]
    ids = []
    for u in urls[:50]:
        jid = new_job(type="yt", url=u, name=u, fmt=fmt, sep=sep, model=model)
        yq.put(jid); ids.append(jid)
    save()
    return jsonify(ids)

def jobs_json(kind):
    pos = {jid: i + 1 for qq in (sq, yq, wq) for i, jid in enumerate(list(qq.queue))}
    for i, t in enumerate([t for t in list(fxq.queue) if t[0] == "conv"]): pos[t[1]] = i + 1
    keys = ("id", "type", "mode", "name", "model", "fmt", "status", "progress", "error", "ext",
            "ana", "key", "kmode", "bpm", "shifts", "wmodel", "lang", "task", "dlang", "segs", "stage", "cv", "cvsrc", "cverr", "srcinfo")
    with lock: js = sorted(jobs.values(), key=lambda x: -x["created"])
    js = [j for j in js if (j.get("type") == "sub") == (kind == "sub")]
    return jsonify([{**{k: j.get(k) for k in keys}, "queue_pos": pos.get(j["id"], 0)} for j in js])

@app.route("/subtitrari/api/jobs")
@need_auth
def subs_jobs(): return jobs_json("sub")

@app.route("/subtitrari/api/dl/<jid>/<kind>")
@need_auth
def subs_dl(jid, kind):
    j = jobs.get(jid)
    if not j or j.get("type") != "sub" or j["status"] != "done" or kind not in ("srt", "vtt", "txt"): abort(404)
    f = f"{OUT}/{jid}/sub.{kind}"
    if not os.path.exists(f): abort(404)
    lg = j.get("dlang") or "und"
    return send_file(f, as_attachment=request.args.get("play") is None, mimetype="text/plain; charset=utf-8",
                     download_name=f"{j['name']}.{lg}.{kind}")

@app.route("/subtitrari/api/delete/<jid>", methods=["POST"])
@need_auth
def subs_delete(jid):
    if (jobs.get(jid) or {}).get("type") != "sub": abort(404)
    return delete_job(jid)

@app.route("/jobs")
def list_jobs(): return jobs_json("main")

@app.route("/dl/<jid>/<kind>")
def dl(jid, kind):
    j = jobs.get(jid)
    if not j or j["status"] != "done": abort(404)
    play = request.args.get("play") is not None
    if j.get("type") == "yt":
        if kind != "file" or not os.path.exists(j.get("file", "")): abort(404)
        return send_file(j["file"], as_attachment=not play,
                         download_name=f"{j['name']}.{j['ext']}", conditional=True)
    if j.get("type") == "sub": abort(404)
    if kind.startswith("s_"):
        s = next((x for x in j.get("shifts", []) if x["id"] == kind[2:]), None)
        if not s or s["status"] != "done": abort(404)
        f = f"{OUT}/{jid}/shift_{s['id']}.{j['ext']}"
        label = f"{TRACK_LABEL[s['track']]} ({s['semi']:+d} st, {s['tempo']}%)"
    elif kind in TRACK_LABEL:
        f, label = track_file(j, kind), TRACK_LABEL[kind]
    else: abort(404)
    if not os.path.exists(f): abort(404)
    return send_file(f, as_attachment=not play,
                     download_name=f"{j['name']} - {label}.{j['ext']}", conditional=True)

@app.route("/shift/<jid>", methods=["POST"])
def shift(jid):
    j = jobs.get(jid)
    if not j or j.get("type") != "sep" or j["status"] != "done": abort(404)
    try:
        semi = max(-12, min(12, int(request.form.get("semi", 0))))
        tempo = max(50, min(150, int(request.form.get("tempo", 100))))
    except ValueError: abort(400)
    track = request.form.get("track", "instrumental")
    allowed = ("original",) if j.get("mode") == "ana" else (*job_tracks(j), "both")
    if track not in allowed or (semi == 0 and tempo == 100): abort(400)
    add_shifts(j, semi, tempo, track)
    save()
    return jsonify(ok=True)

@app.route("/delshift/<jid>/<sid>", methods=["POST"])
def delshift(jid, sid):
    j = jobs.get(jid)
    if j:
        j["shifts"] = [s for s in j.get("shifts", []) if s["id"] != sid]
        for f in glob.glob(f"{OUT}/{jid}/shift_{sid}.*"): os.remove(f)
        save()
    return jsonify(ok=True)

@app.route("/stop/<jid>", methods=["POST"])
def stop(jid):
    if (jobs.get(jid) or {}).get("type") == "sub": abort(404)
    stop_job(jid); return jsonify(ok=True)

@app.route("/subtitrari/api/stop/<jid>", methods=["POST"])
@need_auth
def subs_stop(jid):
    if (jobs.get(jid) or {}).get("type") != "sub": abort(404)
    stop_job(jid); return jsonify(ok=True)

@app.route("/delete/<jid>", methods=["POST"])
def delete(jid):
    if (jobs.get(jid) or {}).get("type") == "sub": abort(404)
    return delete_job(jid)

def delete_job(jid):
    stop_job(jid)            # ✕ pe un job în lucru îl oprește întâi
    with lock: j = jobs.pop(jid, None)
    if j:
        shutil.rmtree(f"{OUT}/{jid}", ignore_errors=True)
        shutil.rmtree(f"{YTD}/{jid}", ignore_errors=True)
        if not j.get("cvsrc"):
            try: os.remove(j.get("path", ""))
            except Exception: pass
        save()
    return jsonify(ok=True)

HTML = r"""<!doctype html><html lang="ro"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Vocal Remover</title><style>
:root{--bg:#0f1115;--card:#181b22;--bd:#2a2f3a;--tx:#e8eaf0;--mu:#8b93a7;--ac:#e50914;--ok:#2ecc71}
*{box-sizing:border-box}[hidden]{display:none!important}
body{margin:0;background:var(--bg);color:var(--tx);font-family:system-ui,sans-serif}
.w{max-width:820px;margin:0 auto;padding:24px 16px}h1{margin:0 0 4px;font-size:26px}
.sub{color:var(--mu);margin-bottom:16px}
.tabs{display:flex;gap:8px;margin-bottom:16px}
.t{flex:1;cursor:pointer;font-weight:600}.t.on{border-color:var(--ac);background:#2a0d10}
.drop{border:2px dashed var(--bd);border-radius:14px;padding:34px 16px;text-align:center;cursor:pointer;transition:.2s;background:var(--card)}
.drop.on,.drop:hover{border-color:var(--ac)}
textarea{width:100%;min-height:96px;background:var(--card);color:var(--tx);border:1px solid var(--bd);border-radius:12px;padding:12px;font:14px system-ui,sans-serif;resize:vertical}
textarea:focus{outline:none;border-color:var(--ac)}
.row{display:flex;gap:10px;margin:14px 0;flex-wrap:wrap;align-items:center}
select,button{background:var(--card);color:var(--tx);border:1px solid var(--bd);border-radius:10px;padding:10px 12px;font-size:14px}
select{flex:1;min-width:160px}button.p{background:var(--ac);border-color:var(--ac);font-weight:600;cursor:pointer}
label.chk{display:flex;align-items:center;gap:6px;color:var(--mu);font-size:14px;cursor:pointer}
.job{background:var(--card);border:1px solid var(--bd);border-radius:12px;padding:14px;margin-top:12px}
.top{display:flex;justify-content:space-between;gap:10px;align-items:center}
.nm{font-weight:600;word-break:break-word}.st{color:var(--mu);font-size:13px}
.bar{height:6px;background:var(--bd);border-radius:4px;margin-top:10px;overflow:hidden}
.bar i{display:block;height:100%;background:var(--ac);transition:width .5s}
.res{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:12px}.res.one{grid-template-columns:1fr}
@media(max-width:600px){.res{grid-template-columns:1fr}.top{flex-direction:column;align-items:flex-start}}
.res div{background:var(--bg);border-radius:10px;padding:10px}.res b{font-size:13px}
audio{width:100%;margin:6px 0}video{width:100%;max-height:380px;border-radius:8px;background:#000;margin:6px 0}
a.d{color:var(--ok);font-size:13px;text-decoration:none}
.x{background:none;border:none;color:var(--mu);cursor:pointer;font-size:18px;padding:0 4px}
.stp{background:#3a1417;border:1px solid #6b1d24;color:#ff8a8a;border-radius:8px;padding:3px 9px;font-size:12px;cursor:pointer;margin-left:8px}
.stp:hover{background:#5a1a20}
.err{color:#ff6b6b;font-size:12px;margin-top:8px;white-space:pre-wrap;word-break:break-word}
.ana{display:flex;gap:16px;flex-wrap:wrap;margin-top:12px;font-size:14px}.ana span{background:var(--bg);border-radius:8px;padding:6px 10px}
.fx{background:var(--bg);border-radius:10px;padding:12px;margin-top:10px;display:grid;grid-template-columns:auto 1fr auto;gap:10px 12px;align-items:center;font-size:13px}
.fx select{min-width:0}.fx input[type=range]{width:100%;accent-color:var(--ac)}.fx .v{color:var(--mu);white-space:nowrap;min-width:120px;text-align:right}
.fx .acts{grid-column:1/-1;display:flex;gap:8px;justify-content:flex-end}.fx button{padding:8px 12px}
@media(max-width:600px){.fx{grid-template-columns:1fr}.fx .v{text-align:left}}
.fx.up{background:var(--card);border:1px solid var(--bd);margin:0 0 14px}
#cvq{width:100%;background:var(--card);color:var(--tx);border:1px solid var(--bd);border-radius:10px;padding:10px 12px;font-size:14px}
#cvres{max-height:260px;overflow:auto;margin-top:6px}
.cvi{display:flex;align-items:center;gap:8px;padding:7px 10px;border-radius:8px;cursor:pointer;font-size:13px;word-break:break-all}
.cvi:hover{background:var(--card)}.cvi input{flex:none}
.cvbox{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-top:10px}
.cvbox select,.cvbox input{flex:1;min-width:140px;background:var(--card);color:var(--tx);border:1px solid var(--bd);border-radius:10px;padding:8px 10px;font-size:13px}
.ok{color:var(--ok);font-size:13px;margin-top:8px;word-break:break-all}
.sh{display:flex;flex-direction:column;gap:4px;margin-top:8px;background:var(--bg);border-radius:10px;padding:10px}
.sh .top{flex-direction:row!important;align-items:center}.sh .top b{font-size:13px}
</style></head><body><div class="w">
<h1>🎤 Vocal Remover</h1><div class="sub">Separare voce · Tonalitate & tempo · YouTube · <a href="subtitrari/" style="color:var(--ok);text-decoration:none">📝 Subtitrări →</a></div>
<div class="tabs"><button class="t on" data-t="sep">🎤 Separare voce</button><button class="t" data-t="yt">▶️ YouTube</button></div>

<section id="sep">
<div class="drop" id="drop">📂 Trage fișiere aici sau apasă pentru a alege<br>
<small style="color:var(--mu)">MP3, WAV, FLAC, M4A, OGG, chiar și MP4/MKV</small>
<input type="file" id="f" multiple accept="audio/*,video/*" hidden></div>
<div class="row"><select id="mode"><option value="sep">🎤 Separare voce + tonalitate/tempo</option><option value="sep4">🥁 Separare 4 piste: voce, tobe, bas, altele</option><option value="ana">🎼 Doar tonalitate/tempo (fără separare)</option></select></div>
<div class="row" style="margin-top:0"><select id="m">%MODELS%</select>
<select id="fmt"><option value="mp3">MP3 320k</option><option value="wav">WAV</option><option value="flac">FLAC</option></select>
<button class="p" id="go">Încarcă</button></div>
<div class="fx up">
  <b style="grid-column:1/-1;font-size:14px">🎼 Tonalitate și tempo <span class="st">(se aplică automat după procesare · 0 st și 100% = neschimbat)</span></b>
  <span>Pistă</span><select id="utrack"><option value="instrumental">Instrumental</option><option value="vocals">Voce</option><option value="both">Ambele</option></select><span></span>
  <span>Ton</span><input type="range" id="usemi" min="-12" max="12" step="1" value="0"><span class="v" id="vsemi">0 st</span>
  <span>Tempo</span><input type="range" id="utempo" min="50" max="150" step="1" value="100"><span class="v" id="vtempo">100%</span>
  <div class="acts"><button onclick="uReset()">Resetează</button></div>
</div>
<div id="sel" class="sub"></div>
</section>

<section id="yt" hidden>
<textarea id="urls" placeholder="Lipește link-uri YouTube (unul pe linie)&#10;https://www.youtube.com/watch?v=..."></textarea>
<div class="row"><select id="yfmt">%YTFMTS%</select>
<label class="chk"><input type="checkbox" id="ysep"> + separă vocea</label>
<button class="p" id="ygo">Descarcă</button></div>
</section>

<div id="list"></div></div>
<script>
const $=s=>document.querySelector(s);let files=[];
function tab(t){document.querySelectorAll('.t').forEach(b=>b.classList.toggle('on',b.dataset.t===t));
 $('#sep').hidden=t!=='sep';$('#yt').hidden=t!=='yt';try{localStorage.setItem('tab',t)}catch(e){}}
document.querySelectorAll('.t').forEach(b=>b.onclick=()=>tab(b.dataset.t));
let t0='sep';try{t0=localStorage.getItem('tab')||'sep'}catch(e){};if(t0!=='yt')t0='sep';tab(t0);

const drop=$('#drop'),inp=$('#f');
drop.onclick=()=>inp.click();
inp.onchange=()=>{files=[...inp.files];showSel()};
['dragover','dragenter'].forEach(e=>drop.addEventListener(e,ev=>{ev.preventDefault();drop.classList.add('on')}));
['dragleave','drop'].forEach(e=>drop.addEventListener(e,ev=>{ev.preventDefault();drop.classList.remove('on')}));
drop.addEventListener('drop',ev=>{files=[...ev.dataTransfer.files];showSel()});
function showSel(){$('#sel').textContent=files.length?files.length+' fișier(e): '+files.map(f=>f.name).join(', '):''}
$('#go').onclick=()=>{if(!files.length)return alert('Alege fișiere!');
 const fd=new FormData();files.forEach(f=>fd.append('files',f));fd.append('model',$('#m').value);fd.append('fmt',$('#fmt').value);
 fd.append('mode',$('#mode').value);
 fd.append('semi',$('#usemi').value);fd.append('tempo',$('#utempo').value);fd.append('track',$('#utrack').value);
 const x=new XMLHttpRequest();x.open('POST','upload');
 x.upload.onprogress=e=>$('#sel').textContent='Încărcare: '+Math.round(e.loaded/e.total*100)+'%';
 x.onload=()=>{files=[];inp.value='';$('#sel').textContent='';load()};x.send(fd)};

// ---- CineVerse (clipuri YouTube) ----
let CV={enabled:false,dirs:[]};
fetch('cv').then(r=>r.json()).then(d=>{CV=d;last='';load()}).catch(()=>{});
async function cvSend(id){const fd=new FormData();
 fd.append('dir',document.getElementById('cvd_'+id).value);fd.append('sub',document.getElementById('cvs_'+id).value);
 const r=await fetch('cv/send/'+id,{method:'POST',body:fd});const d=await r.json().catch(()=>({}));
 if(!r.ok||!d.ok)return alert(d.error||'Eroare');last='';load()}
const cvDone=j=>j.cv?`<div class="ok">✅ În CineVerse: ${esc(j.cv)}</div>`:'';

const syncSep=()=>{const mp3=$('#yfmt').value==='mp3';$('#ysep').disabled=!mp3;if(!mp3)$('#ysep').checked=false;
 $('#ysep').parentElement.style.opacity=mp3?1:.4};
$('#yfmt').onchange=syncSep;syncSep();
$('#ygo').onclick=async()=>{const u=$('#urls').value.trim();if(!u)return alert('Lipește un link!');
 const fd=new FormData();fd.append('urls',u);fd.append('fmt',$('#yfmt').value);
 fd.append('sep',$('#ysep').checked?'1':'0');fd.append('model',$('#m').value);
 const r=await fetch('yt',{method:'POST',body:fd});if(!r.ok)return alert('Eroare server');
 const ids=await r.json();if(!ids.length)return alert('Niciun link valid');$('#urls').value='';load()};

const uLab=()=>{const s=+$('#usemi').value;$('#vsemi').textContent=(s>0?'+':'')+s+' st';$('#vtempo').textContent=$('#utempo').value+'%'};
$('#usemi').oninput=uLab;$('#utempo').oninput=uLab;
function uReset(){$('#usemi').value=0;$('#utempo').value=100;uLab()}
const syncMode=()=>{const a=$('#mode').value==='ana';$('#m').disabled=a;$('#m').style.opacity=a?.4:1;
 $('#utrack').disabled=a;$('#utrack').style.opacity=a?.4:1;
 try{localStorage.setItem('mode',$('#mode').value)}catch(e){}};
try{const mm=localStorage.getItem('mode');if(mm)$('#mode').value=mm}catch(e){}
$('#mode').onchange=syncMode;syncMode();

const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
// ---------- tonalitate / tempo ----------
const NT=['C','C#','D','Eb','E','F','F#','G','Ab','A','Bb','B'],RO=['Do','Do#','Re','Mi♭','Mi','Fa','Fa#','Sol','La♭','La','Si♭','Si'];
const TL={vocals:'🎤 Voce',instrumental:'🎵 Instrumental',original:'🎧 Original',drums:'🥁 Tobe',bass:'🎸 Bas',other:'🎹 Altele (pian, chitară, synth…)'};
const TRK=j=>j.mode==='ana'?['original']:j.mode==='sep4'?['vocals','instrumental','drums','bass','other']:['vocals','instrumental'];
const TN={vocals:'Voce',instrumental:'Instrumental',original:'Original',drums:'Tobe',bass:'Bas',other:'Altele'};
const kn=(k,m,s=0)=>{const i=((k+s)%12+12)%12;return NT[i]+(m==='minor'?'m':'')+' · '+RO[i]+' '+m};
const ks=(k,m,s=0)=>{const i=((k+s)%12+12)%12;return NT[i]+(m==='minor'?'m':'')};
const ctl={},byId={};
const C=j=>ctl[j.id]||(ctl[j.id]={semi:0,tempo:100,track:j.mode==='ana'?'original':'instrumental'});
const sgn=n=>(n>0?'+':'')+n;
function vSemi(j){const c=C(j);return sgn(c.semi)+' st'+(j.key!=null?' → '+ks(j.key,j.kmode,c.semi):'')}
function vTempo(j){const c=C(j);return c.tempo+'%'+(j.bpm?' → '+Math.round(j.bpm*c.tempo/100)+' BPM':'')}
function fx(j){const c=C(j);
 const tr=j.mode==='ana'?[['original','Original']]:[['instrumental','Instrumental'],['vocals','Voce'],['both','Voce + Instrumental'],...TRK(j).slice(2).map(k=>[k,TN[k]])];
 let ana='';
 if(j.ana==='done')ana=`<div class="ana"><span>🎼 Tonalitate: <b>${kn(j.key,j.kmode)}</b></span><span>🥁 Tempo: <b>${j.bpm} BPM</b></span></div>`;
 else if(j.ana==='error')ana=`<div class="ana"><span>⚠ Analiza tonalității a eșuat (poți transpune oricum)</span></div>`;
 else ana=`<div class="ana"><span>🔎 Analizez tonalitatea și tempo-ul…</span></div>`;
 const sh=(j.shifts||[]).map(s=>{const lab=`${TL[s.track]} · ${sgn(s.semi)} st${j.key!=null?' ('+ks(j.key,j.kmode,s.semi)+')':''} · ${s.tempo}%${j.bpm?' ('+Math.round(j.bpm*s.tempo/100)+' BPM)':''}`;
  let b='';if(s.status==='done')b=`<audio controls preload="none" src="dl/${j.id}/s_${s.id}?play=1"></audio><a class="d" href="dl/${j.id}/s_${s.id}">⬇ Descarcă</a>`;
  else if(s.status==='error')b=`<div class="err">${esc(s.error)}</div>`;else b=`<span class="st">⚙️ Procesare…</span>`;
  return `<div class="sh"><div class="top"><b>${lab}</b><button class="x" title="Șterge" onclick="delShift('${j.id}','${s.id}')">✕</button></div>${b}</div>`}).join('');
 return ana+`<div class="fx" data-id="${j.id}">
  <span>Pistă</span><select data-k="track">${tr.map(([v,l])=>`<option value="${v}"${c.track===v?' selected':''}>${l}</option>`).join('')}</select><span></span>
  <span>Ton</span><input type="range" min="-12" max="12" step="1" value="${c.semi}" data-k="semi"><span class="v" data-v="semi">${vSemi(j)}</span>
  <span>Tempo</span><input type="range" min="50" max="150" step="1" value="${c.tempo}" data-k="tempo"><span class="v" data-v="tempo">${vTempo(j)}</span>
  <div class="acts"><button onclick="resetFx('${j.id}')">Resetează</button><button class="p" onclick="applyFx('${j.id}')">Aplică</button></div></div>`+sh}
const L=$('#list');let dragging=false;
L.addEventListener('pointerdown',e=>{if(e.target.type==='range')dragging=true});
addEventListener('pointerup',()=>{dragging=false});
L.addEventListener('input',e=>{const b=e.target.closest('.fx');if(!b||!e.target.dataset.k)return;const j=byId[b.dataset.id],c=C(j),k=e.target.dataset.k;
 c[k]=k==='track'?e.target.value:+e.target.value;
 b.querySelector('[data-v=semi]').textContent=vSemi(j);b.querySelector('[data-v=tempo]').textContent=vTempo(j)});
function resetFx(id){Object.assign(C(byId[id]),{semi:0,tempo:100});last='';load()}
async function applyFx(id){const c=C(byId[id]);if(!c.semi&&c.tempo===100)return alert('Alege un ton sau un tempo diferit.');
 const fd=new FormData();fd.append('semi',c.semi);fd.append('tempo',c.tempo);fd.append('track',c.track);
 const r=await fetch('shift/'+id,{method:'POST',body:fd});if(!r.ok)return alert('Eroare server');last='';load()}
async function delShift(id,sid){await fetch('delshift/'+id+'/'+sid,{method:'POST'});last='';load()}

function card(j){const yt=j.type==='yt';
 const st={queued:'⏳ În așteptare'+(j.queue_pos?' (#'+j.queue_pos+')':''),processing:'⚙️ '+(yt?'Descărcare ':'Procesare ')+j.progress+'%',done:'✅ Gata',error:'❌ Eroare',stopped:'⏹ Oprit'}[j.status];
 const meta=yt?(j.fmt==='mp3'?'YouTube · MP3':'YouTube · '+(j.fmt==='best'?'max':j.fmt+'p')):(j.mode==='ana'?'tonalitate/tempo':j.mode==='sep4'?'4 piste · '+j.model:j.model)+' · '+j.fmt;
 let body='';
 if(j.status==='processing'||j.status==='queued')body=`<div class="bar"><i style="width:${j.progress}%"></i></div>`;
 if(j.status==='done'){
  if(yt){const s=`dl/${j.id}/file`;
   body=`<div class="res one"><div>${j.fmt==='mp3'?`<audio controls preload="none" src="${s}?play=1"></audio>`:`<video controls preload="none" src="${s}?play=1"></video>`}<a class="d" href="${s}">⬇ Descarcă</a></div></div>`
   +(j.fmt!=='mp3'?(j.cv?cvDone(j):CV.enabled?`<div class="cvbox"><select id="cvd_${j.id}">${CV.dirs.map(d=>`<option value="${d.i}">📁 ${esc(d.name)}</option>`).join('')}</select>
   <input id="cvs_${j.id}" placeholder="Subfolder (opțional, ex. YouTube)"><button class="p" onclick="cvSend('${j.id}')">📺 Trimite în CineVerse</button></div>`:''):'')}
  else{const tk=TRK(j);
   body=`<div class="res${tk.length===1?' one':''}">${tk.map(k=>`<div><b>${TL[k]}</b>
   <audio controls preload="none" src="dl/${j.id}/${k}?play=1"></audio><a class="d" href="dl/${j.id}/${k}">⬇ Descarcă</a></div>`).join('')}</div>`+fx(j)}}
 if(j.status==='error'||j.status==='stopped')body=`<div class="err">${esc(j.error)}</div>`;
 return `<div class="job"><div class="top"><div class="nm">${yt?'▶️':'🎤'} ${esc(j.name)}</div>
  <div><span class="st">${st} · ${esc(meta)}</span>${j.status==='queued'||j.status==='processing'?`<button class="stp" title="Oprește" onclick="stopJob('${j.id}')">⏹ Stop</button>`:''}<button class="x" title="Șterge" onclick="del('${j.id}')">✕</button></div></div>${body}</div>`}
let last='';
async function load(){try{const t=await (await fetch('jobs')).text();if(t===last)return;last=t;
 const d=JSON.parse(t);d.forEach(j=>byId[j.id]=j);L.innerHTML=d.map(card).join('')}catch(e){}}
// nu reîncarcă lista cât timp rulează audio/video sau ajustezi ton/tempo
const busy=()=>dragging||[...document.querySelectorAll('audio,video')].some(a=>!a.paused)||
 (document.activeElement&&document.activeElement.tagName==='SELECT'&&L.contains(document.activeElement));
setInterval(()=>{if(!busy())load()},2500);
async function del(id){if(confirm('Ștergi?')){await fetch('delete/'+id,{method:'POST'});last='';load()}}
async function stopJob(id){if(confirm('Oprești procesarea?')){await fetch('stop/'+id,{method:'POST'});last='';load()}}
load();
</script></body></html>"""

CSS = HTML.split("<style>", 1)[1].split("</style>", 1)[0]

LOGIN = r"""<!doctype html><html lang="ro"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Subtitrări · Autentificare</title>
<style>%CSS%
.lg{max-width:360px;margin:12vh auto;padding:28px 22px;background:var(--card);border:1px solid var(--bd);border-radius:16px}
.lg h1{font-size:24px}.lg input[type=text],.lg input[type=password]{width:100%;margin-top:12px;background:var(--bg);color:var(--tx);border:1px solid var(--bd);border-radius:10px;padding:12px;font-size:15px}
.lg input:focus{outline:none;border-color:var(--ac)}.lg button{width:100%;margin-top:16px;padding:12px;font-size:15px}
.lg label{display:flex;gap:8px;align-items:center;margin-top:12px;color:var(--mu);font-size:14px}.lg code{color:var(--tx)}
</style></head><body><form class="lg" method="post" action="login">
<h1>📝 Subtitrări</h1><div class="sub">Autentifică-te pentru a continua</div>%MSG%
<input type="text" name="u" placeholder="Utilizator" autocomplete="username" autofocus required>
<input type="password" name="p" placeholder="Parolă" autocomplete="current-password" required>
<label><input type="checkbox" name="r" value="1" checked> Ține-mă minte 30 de zile</label>
<button class="p" type="submit">Intră</button></form></body></html>"""

SUBHTML = r"""<!doctype html><html lang="ro"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Subtitrări AI</title>
<style>%CSS%
.hd{display:flex;justify-content:space-between;align-items:flex-start;gap:10px}
.hd a{color:var(--mu);font-size:13px;text-decoration:none;white-space:nowrap}
</style></head><body><div class="w">
<div class="hd"><div><h1>📝 Subtitrări AI</h1><div class="sub">Transcriere și traducere automată cu Whisper · SRT / VTT / TXT</div></div>
<a href="logout">👤 %USER% · Ieșire</a></div>
<div class="drop" id="sdrop">📝 Trage aici filme, clipuri sau audio pentru subtitrare<br>
<small style="color:var(--mu)">MP4, MKV, AVI, MP3, WAV… sau o subtitrare .SRT în engleză de tradus · rezultat SRT / VTT / TXT</small>
<input type="file" id="sf" multiple accept="audio/*,video/*,.mkv,.avi,.ts,.srt,.vtt" hidden></div>
<div id="cvpick" hidden style="margin-top:12px">
 <input id="cvq" placeholder="🔎 Sau caută un film / episod direct din CineVerse (fără upload)…">
 <div id="cvres"></div>
</div>
<div class="row"><select id="wm">%WMODELS%</select><select id="wl">%WLANGS%</select>
<select id="wt"><option value="ro">🇷🇴 Traducere în română</option><option value="transcribe">Transcriere (aceeași limbă)</option><option value="translate">🇬🇧 Traducere în engleză</option></select>
<button class="p" id="sgo">Generează</button></div>
<label class="chk" id="embl" style="margin:-4px 0 12px"><input type="checkbox" id="emb" checked> 📄 Folosește subtitrarea din film (EN/RO) dacă există – mult mai rapid și mai exact decât din audio</label>
<div id="ssel" class="sub"></div>
<div id="list"></div></div>
<script>
const $=s=>document.querySelector(s);
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const api=(u,o)=>fetch('api/'+u,o).then(r=>{if(r.status===401){location.href='login';throw 0}return r});
let sfiles=[];const sdrop=$('#sdrop'),sinp=$('#sf');
sdrop.onclick=()=>sinp.click();
const sShow=()=>{$('#ssel').textContent=sfiles.length?sfiles.length+' fișier(e): '+sfiles.map(f=>f.name).join(', '):''};
sinp.onchange=()=>{sfiles=[...sinp.files];sShow()};
['dragover','dragenter'].forEach(e=>sdrop.addEventListener(e,ev=>{ev.preventDefault();sdrop.classList.add('on')}));
['dragleave','drop'].forEach(e=>sdrop.addEventListener(e,ev=>{ev.preventDefault();sdrop.classList.remove('on')}));
sdrop.addEventListener('drop',ev=>{sfiles=[...ev.dataTransfer.files];sShow()});
try{const v=JSON.parse(localStorage.getItem('wopt')||'{}');for(const k of ['wm','wl','wt'])if(v[k])$('#'+k).value=v[k]}catch(e){}
let CV={enabled:false,dirs:[]};const cvSel=new Set();
api('cv').then(r=>r.json()).then(d=>{CV=d;$('#cvpick').hidden=!d.enabled;last='';load()}).catch(()=>{});
let cvT;$('#cvq').oninput=()=>{clearTimeout(cvT);cvT=setTimeout(cvSearch,300)};
async function cvSearch(){const q=$('#cvq').value.trim();if(q.length<2){$('#cvres').innerHTML='';return}
 const d=await (await api('videos?q='+encodeURIComponent(q))).json();
 $('#cvres').innerHTML=d.length?d.map(v=>`<label class="cvi"><input type="checkbox" value="${esc(v.path)}" ${cvSel.has(v.path)?'checked':''}>🎬 ${esc(v.rel)}</label>`).join(''):'<div class="st" style="padding:8px">Nimic găsit</div>'}
$('#cvres').addEventListener('change',e=>{if(e.target.checked)cvSel.add(e.target.value);else cvSel.delete(e.target.value);
 $('#ssel').textContent=cvSel.size?cvSel.size+' film(e) din CineVerse selectate':''});
async function cvVideoPick(id){const q=prompt('Caută filmul / episodul din CineVerse:');if(!q)return;
 const d=await (await api('videos?q='+encodeURIComponent(q))).json();
 if(!d.length)return alert('Nimic găsit');
 const s=document.getElementById('cvv_'+id);s.innerHTML=d.map(v=>`<option value="${esc(v.path)}">${esc(v.rel)}</option>`).join('');s.hidden=false;
 document.getElementById('cvb_'+id).hidden=false}
async function cvSend(id){const s=document.getElementById('cvv_'+id);if(!s.value)return;
 const fd=new FormData();fd.append('video',s.value);
 const r=await api('send/'+id,{method:'POST',body:fd});const d=await r.json().catch(()=>({}));
 if(!r.ok||!d.ok)return alert(d.error||'Eroare');last='';load()}
const syncEmb=()=>{const ro=$('#wt').value==='ro';$('#emb').disabled=!ro;$('#embl').style.opacity=ro?1:.4};
$('#wt').addEventListener('change',syncEmb);setTimeout(syncEmb,0);
const opts=fd=>{fd.append('wmodel',$('#wm').value);fd.append('lang',$('#wl').value);fd.append('task',$('#wt').value);
 fd.append('emb',$('#emb').checked?'1':'0');
 try{localStorage.setItem('wopt',JSON.stringify({wm:$('#wm').value,wl:$('#wl').value,wt:$('#wt').value}))}catch(e){}};
$('#sgo').onclick=async()=>{
 if(cvSel.size&&!sfiles.length){const fd=new FormData();[...cvSel].forEach(p=>fd.append('paths',p));opts(fd);
  $('#sgo').disabled=true;$('#ssel').textContent='Se trimite…';
  let d={ids:[],errors:['Eroare server']};
  try{const r=await api('fromcv',{method:'POST',body:fd});d=await r.json().catch(()=>({ids:[],errors:['Eroare server ('+r.status+')']}))}catch(e){}
  $('#sgo').disabled=false;
  if(!d.ids||!d.ids.length){$('#ssel').textContent='';return alert('Nu am putut porni subtitrarea:\n'+(d.errors||[]).join('\n'))}
  if(d.errors&&d.errors.length)alert('Unele filme au fost sărite:\n'+d.errors.join('\n'));
  cvSel.clear();$('#cvres').innerHTML='';$('#cvq').value='';
  $('#ssel').textContent='✅ '+d.ids.length+' film(e) adăugate în coadă';setTimeout(()=>$('#ssel').textContent='',4000);
  last='';return load()}
 if(!sfiles.length)return alert('Alege fișiere sau un film din CineVerse!');
 const fd=new FormData();sfiles.forEach(f=>fd.append('files',f));opts(fd);
 const x=new XMLHttpRequest();x.open('POST','api/upload');
 x.upload.onprogress=e=>$('#ssel').textContent='Încărcare: '+Math.round(e.loaded/e.total*100)+'%';
 x.onload=()=>{if(x.status===401)return location.href='login';sfiles=[];sinp.value='';$('#ssel').textContent='';last='';load()};x.send(fd)};
const LN={ro:'Română',en:'English',it:'Italiano',es:'Español',fr:'Français',de:'Deutsch',hu:'Magyar',ru:'Русский',tr:'Türkçe'};
function card(j){
 const stg=j.stage==='model'?'⬇️ Pregătesc modelul Whisper (prima dată se descarcă)…':j.stage==='audio'?'🎧 Extrag sunetul…':j.stage==='emb'?'📄 Caut subtitrări în film…':j.stage==='run'?'⚙️ Transcriere '+j.progress+'%':j.stage==='tr'?'🇷🇴 Traducere în română '+j.progress+'%':'⏳ Pornire…';
 const st={queued:'⏳ În așteptare'+(j.queue_pos?' (#'+j.queue_pos+')':''),processing:stg,done:'✅ Gata',error:'❌ Eroare',stopped:'⏹ Oprit'}[j.status];
 const meta=(j.cvsrc?'CineVerse · ':'')+j.wmodel+' · '+(j.task==='translate'?'→ English':j.task==='ro'?'→ Română':(j.lang==='auto'?'auto':LN[j.lang]||j.lang));
 let body='';
 if(j.status==='processing'||j.status==='queued')body=`<div class="bar"><i style="width:${j.progress}%"></i></div>`;
 if(j.status==='done')body=`<div class="ana"><span>🌐 Limbă: <b>${esc(LN[j.dlang]||j.dlang||'?')}</b></span><span>💬 ${j.segs||0} replici</span>${j.srcinfo?`<span>${j.srcinfo==='emb:en'?'📄 Din subtitrarea EN a filmului':j.srcinfo==='emb:ro'?'📄 Din subtitrarea RO a filmului':j.srcinfo==='file'?'📄 Din fișierul .srt':'🎧 Din audio (Whisper)'}</span>`:''}</div>
  <div class="res one"><div style="display:flex;gap:14px;flex-wrap:wrap">${['srt','vtt','txt'].map(k=>`<a class="d" href="api/dl/${j.id}/${k}">⬇ ${k.toUpperCase()}</a>`).join('')}
  <a class="d" style="color:var(--mu)" href="api/dl/${j.id}/srt?play=1" target="_blank">👁 Vezi SRT</a></div></div>`
  +(j.cv?`<div class="ok">✅ În CineVerse: ${esc(j.cv)}</div>`:CV.enabled?`<div class="cvbox"><button onclick="cvVideoPick('${j.id}')">📺 Trimite în CineVerse</button>
   <select id="cvv_${j.id}" hidden></select><button class="p" id="cvb_${j.id}" hidden onclick="cvSend('${j.id}')">Pune subtitrarea lângă film</button></div>`:'')
  +(j.cverr?`<div class="err">CineVerse: ${esc(j.cverr)}</div>`:'');
 if(j.status==='error'||j.status==='stopped')body=`<div class="err">${esc(j.error)}</div>`;
 return `<div class="job"><div class="top"><div class="nm">📝 ${esc(j.name)}</div>
  <div><span class="st">${st} · ${esc(meta)}</span>${j.status==='queued'||j.status==='processing'?`<button class="stp" title="Oprește" onclick="stopJob('${j.id}')">⏹ Stop</button>`:''}<button class="x" title="Șterge" onclick="del('${j.id}')">✕</button></div></div>${body}</div>`}
let last='';const L=$('#list');
async function load(){try{const t=await (await api('jobs')).text();if(t===last)return;last=t;L.innerHTML=JSON.parse(t).map(card).join('')}catch(e){}}
setInterval(()=>{const a=document.activeElement;if(!(a&&a.tagName==='SELECT'&&L.contains(a)))load()},2500);
async function del(id){if(confirm('Ștergi?')){await api('delete/'+id,{method:'POST'});last='';load()}}
async function stopJob(id){if(confirm('Oprești procesarea?')){await api('stop/'+id,{method:'POST'});last='';load()}}
load();
</script></body></html>"""

load()
threading.Thread(target=sep_worker, daemon=True).start()
threading.Thread(target=yt_worker, daemon=True).start()
threading.Thread(target=fx_worker, daemon=True).start()
threading.Thread(target=sub_worker, daemon=True).start()

if __name__ == "__main__":
    from waitress import serve
    serve(app, host="0.0.0.0", port=int(os.environ.get("PORT", 8095)), threads=8)
PYEOF

echo "==> Login Subtitrări..."
cat > /usr/local/bin/subtitrari-parola <<'SPEOF'
#!/bin/bash
# Schimbă utilizatorul / parola paginii Subtitrări
[ "$EUID" -ne 0 ] && { echo "Rulează cu sudo!"; exit 1; }
B=/opt/vocal-remover
read -rp "Utilizator [admin]: " U; U="${U:-admin}"
while :; do
  read -rsp "Parolă nouă: " P; echo; read -rsp "Confirmă: " P2; echo
  [ -n "$P" ] && [ "$P" = "$P2" ] && break; echo "Parolele nu coincid sau sunt goale."
done
U="$U" P="$P" "$B/venv/bin/python" -c "import json,os;from werkzeug.security import generate_password_hash as g;json.dump({'user':os.environ['U'],'hash':g(os.environ['P'])},open('$B/subauth.json','w'))"
chown "$(stat -c %U "$B/app.py")": "$B/subauth.json"; chmod 600 "$B/subauth.json"
echo "✅ Parola a fost schimbată (sesiunile vechi sunt delogate)."
SPEOF
chmod 755 /usr/local/bin/subtitrari-parola
if [ -n "$SUB_PASS" ]; then
  U="$SUB_USER" P="$SUB_PASS" "$BASE/venv/bin/python" -c "import json,os;from werkzeug.security import generate_password_hash as g;json.dump({'user':os.environ['U'],'hash':g(os.environ['P'])},open('$BASE/subauth.json','w'))"
  chmod 600 "$BASE/subauth.json"
  echo "   utilizator Subtitrări: $SUB_USER"
fi

chown -R "$APPUSER":"$APPUSER" "$BASE"

echo "==> Descarc modelele AI (o singură dată)..."
sudo -u "$APPUSER" "$BASE/venv/bin/python" -c "
from demucs.pretrained import get_model
for m in ['htdemucs','htdemucs_ft']:
    get_model(m); print('  OK', m)
"

echo "==> Update zilnic automat yt-dlp..."
cat > /etc/cron.daily/vocal-remover-ytdlp <<EOF
#!/bin/sh
runuser -u $APPUSER -- $BASE/venv/bin/pip install -q -U "yt-dlp[default]" >/dev/null 2>&1
EOF
chmod +x /etc/cron.daily/vocal-remover-ytdlp

echo "==> Integrare CineVerse..."
CVDB=/var/lib/cineverse/cineverse.db
if [ -f "$CVDB" ]; then
  CVDIRS=$(python3 - "$CVDB" <<'PYEOF'
import sqlite3, re, sys
c = sqlite3.connect(sys.argv[1], timeout=30)
r = c.execute("select v from settings where k='media_dirs'").fetchone()
print("\n".join(d.strip() for d in re.split(r"[\n;]+", (r[0] if r else "")) if d.strip()))
PYEOF
)
  if [ -n "$CVDIRS" ]; then
    command -v setfacl >/dev/null 2>&1 || apt-get install -y -qq acl >/dev/null
    CVUSR=$(stat -c %U "$CVDB")
    python3 -c "import json,sys;json.dump({'dirs':[l for l in sys.stdin.read().splitlines() if l.strip()]},open('$BASE/cineverse.json','w'),indent=1)" <<< "$CVDIRS"
    while IFS= read -r d; do
      [ -d "$d" ] || { echo "   ⚠ folder inexistent: $d"; continue; }
      # vocal-remover poate citi filmele și scrie subtitrări/clipuri; CineVerse poate citi ce adăugăm
      find "$d" -type d -exec setfacl -m "u:$APPUSER:rwx,d:u:$APPUSER:rwx,d:u:$CVUSR:rwx" {} + 2>/dev/null || true
      find "$d" -type f -exec setfacl -m "u:$APPUSER:r" {} + 2>/dev/null || true
      # acces la folderele părinte (ex. /home/user)
      p="$d"; while [ "$p" != "/" ]; do p=$(dirname "$p"); setfacl -m "u:$APPUSER:x" "$p" 2>/dev/null || true; done
      echo "   📁 $d"
    done <<< "$CVDIRS"
  else
    echo "   CineVerse găsit, dar fără foldere media configurate"; echo '{"dirs":[]}' > "$BASE/cineverse.json"
  fi
else
  echo "   CineVerse nu e instalat pe acest server (opțiunea „Trimite în CineVerse” rămâne ascunsă)"
  echo '{"dirs":[]}' > "$BASE/cineverse.json"
fi
chown "$APPUSER":"$APPUSER" "$BASE/cineverse.json"

echo "==> Serviciu systemd..."
cat > /etc/systemd/system/vocal-remover.service <<EOF
[Unit]
Description=Vocal Remover (Demucs + Whisper + YouTube Web UI)
After=network.target

[Service]
User=$APPUSER
WorkingDirectory=$BASE
Environment=PORT=$PORT
Environment=OMP_NUM_THREADS=$(nproc)
Environment=PATH=/usr/local/bin:/usr/bin:/bin:$BASE/venv/bin
Environment=NUMBA_CACHE_DIR=$BASE/.numba
Environment=HF_HOME=$BASE/hf
ExecStart=$BASE/venv/bin/python $BASE/app.py
Restart=always
Nice=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vocal-remover >/dev/null 2>&1
systemctl restart vocal-remover

if ufw status 2>/dev/null | grep -q active; then ufw allow $PORT/tcp >/dev/null; fi

# ---------- nginx + parolă (opțional) ----------
EXTURL=""
write_snip() {
  cat > "$SNIP" <<'NGEOF'
# Vocal Remover + Subtitrări – inclus în server block-ul domeniului
location = /vocal { return 301 /vocal/; }
location /vocal/ {
    auth_basic "Vocal Remover";
    auth_basic_user_file __HTP__;
    proxy_pass http://127.0.0.1:__PORT__/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    client_max_body_size 2G;
    proxy_request_buffering off;
    proxy_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}
# Subtitrări – login propriu (fără auth_basic)
location = /subtitrari { return 301 /subtitrari/; }
location /subtitrari/ {
    proxy_pass http://127.0.0.1:__PORT__/subtitrari/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    client_max_body_size 8G;
    proxy_request_buffering off;
    proxy_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}
NGEOF
  sed -i "s|__HTP__|$HTP|; s|__PORT__|$PORT|g" "$SNIP"
}
if command -v nginx >/dev/null 2>&1; then
  CONF=$(nginx -V 2>&1 | grep -o -- '--conf-path=[^ ]*' | cut -d= -f2)
  NDIR=$(dirname "${CONF:-/etc/nginx/nginx.conf}")
  SNIP="$NDIR/vocal-remover.conf"; HTP="$NDIR/.htpasswd-vocal"
  # nginx configurat de o instalare anterioară -> doar actualizez rutele (adaug /subtitrari/)
  if [ "$SETUP_NGINX" != "yes" ] && [ -f "$SNIP" ]; then
    echo "==> nginx: actualizez rutele (/vocal/ + /subtitrari/)..."
    cp -a "$SNIP" "/root/vocal-remover.conf.bak"
    write_snip
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx 2>/dev/null || nginx -s reload; EXTURL="$DOMAIN"
    else
      cp -a "/root/vocal-remover.conf.bak" "$SNIP"; echo "   ⚠ nginx -t a eșuat, am păstrat configurația veche"
    fi
  fi
fi
if [ "$SETUP_NGINX" = "yes" ]; then
  echo "==> nginx pentru $DOMAIN/vocal/ și /subtitrari/ ..."
  command -v nginx >/dev/null 2>&1 || apt-get install -y -qq nginx >/dev/null
  CONF=$(nginx -V 2>&1 | grep -o -- '--conf-path=[^ ]*' | cut -d= -f2)
  NDIR=$(dirname "${CONF:-/etc/nginx/nginx.conf}")
  SNIP="$NDIR/vocal-remover.conf"
  HTP="$NDIR/.htpasswd-vocal"
  BK="/root/nginx-backup-vocal-$(date +%Y%m%d-%H%M%S)"

  printf '%s:%s\n' "$VR_USER" "$(openssl passwd -apr1 "$VR_PASS")" > "$HTP"
  chmod 644 "$HTP"
  write_snip

  DRE="${DOMAIN//./\\.}"
  FILES=$(grep -rlE "server_name[^;]*${DRE}" "$NDIR" 2>/dev/null | grep -v -e "$SNIP" -e '\.bak' || true)
  mkdir -p "$BK"
  if [ -n "$FILES" ]; then
    for f in $FILES; do
      grep -q "vocal-remover.conf" "$f" && { echo "   deja inclus în $f"; continue; }
      cp -a "$f" "$BK/"
      sed -i "/server_name[^;]*${DRE}/a\\    include $SNIP;" "$f"
      echo "   inclus în $f"
    done
  else
    if [ -d "$NDIR/sites-available" ]; then
      SITE="$NDIR/sites-available/vocal-remover-site"
      ln -sf "$SITE" "$NDIR/sites-enabled/vocal-remover-site"
    else
      SITE="$NDIR/conf.d/vocal-remover-site.conf"; mkdir -p "$NDIR/conf.d"
    fi
    cat > "$SITE" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    include $SNIP;
}
EOF
    echo "   creat $SITE (HTTP). Pentru HTTPS: sudo certbot --nginx -d $DOMAIN"
  fi

  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx 2>/dev/null || nginx -s reload
    EXTURL="$DOMAIN"
  else
    echo "   ⚠ nginx -t a eșuat, restaurez configurația:"
    nginx -t 2>&1 | tail -3
    for f in $FILES; do [ -f "$BK/$(basename "$f")" ] && cp -a "$BK/$(basename "$f")" "$f"; done
    [ -n "$SITE" ] && rm -f "$SITE" "$NDIR/sites-enabled/vocal-remover-site"
    rm -f "$SNIP"
  fi
fi

IP=$(hostname -I | awk '{print $1}')
echo ""
echo "============================================"
echo " ✅ Vocal Remover + Subtitrări instalat!"
echo " 🎤 Vocal Remover:  http://$IP:$PORT"
echo " 📝 Subtitrări:     http://$IP:$PORT/subtitrari/"
[ -n "$EXTURL" ] && echo " 🌍 Extern:  https://$EXTURL/vocal/   și   https://$EXTURL/subtitrari/"
[ -n "$SUB_GEN" ] && echo " 🔑 Login Subtitrări:  $SUB_USER / $SUB_PASS   (schimbă cu: sudo subtitrari-parola)"
echo " Parolă Subtitrări: sudo subtitrari-parola"
echo " Log:     journalctl -u vocal-remover -f"
echo "============================================"
