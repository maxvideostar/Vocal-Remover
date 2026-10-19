#!/bin/bash
# ============================================================
#  Vocal Remover (Demucs AI) + YouTube Downloader + Web UI
#  Ubuntu 22.04 / 24.04
#
#  Rulare:   sudo bash vocal-remover-install.sh
#  Acces:    http://IP-SERVER:8095
#  Extern:   https://DOMENIU/vocal/   (opțional, nginx + parolă)
#
#  Variabile opționale (pentru rulare neinteractivă):
#    DOMAIN=testcam.go.ro  SETUP_NGINX=yes|no  VR_USER=admin  VR_PASS=parola
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
"$BASE/venv/bin/pip" install -q demucs==4.0.1 flask waitress soundfile
"$BASE/venv/bin/pip" install -q -U "yt-dlp[default]"

echo "==> Aplicație web..."
cat > "$BASE/app.py" <<'PYEOF'
import os, re, uuid, glob, json, shutil, threading, queue, subprocess, time
from flask import Flask, request, jsonify, send_file, abort, Response

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

lock = threading.RLock()
sq, yq = queue.Queue(), queue.Queue()
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
        if j["status"] in ("queued", "processing"):
            j["progress"] = 0
            if j["type"] == "yt":
                j["status"] = "queued"; yq.put(jid)
            elif os.path.exists(j.get("path", "")):
                j["status"] = "queued"; sq.put(jid)
            else:
                j["status"], j["error"] = "error", "Întrerupt la restart"

def run(cmd, j, pattern):
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, bufsize=1, errors="replace")
    log = []
    for line in p.stdout:
        log.append(line); log = log[-40:]
        m = re.search(pattern, line)
        if m: j["progress"] = int(float(m.group(1)))
        if j.get("type") == "yt" and j["name"] == j.get("url"):
            d = re.search(r"Destination: (.+)$", line.strip())
            if d: j["name"] = os.path.splitext(os.path.basename(d.group(1)))[0]
    p.wait()
    return p.returncode, log

def sep_worker():
    while True:
        jid = sq.get(); j = jobs.get(jid)
        if not j: continue
        j["status"], j["progress"] = "processing", 0; save()
        od = os.path.join(OUT, jid)
        cmd = [PY, "-m", "demucs", "--two-stems=vocals", "-n", j["model"],
               "-o", od, *FMTS[j["fmt"]], j["path"]]
        try:
            rc, log = run(cmd, j, r"(\d+)%\|")
            v = glob.glob(f"{od}/*/*/vocals.*"); n = glob.glob(f"{od}/*/*/no_vocals.*")
            if rc != 0 or not v or not n:
                raise RuntimeError("".join(log[-5:]) or "Demucs a eșuat")
            ext = v[0].rsplit(".", 1)[1]
            shutil.move(v[0], f"{od}/vocals.{ext}")
            shutil.move(n[0], f"{od}/instrumental.{ext}")
            for d in glob.glob(f"{od}/*/"): shutil.rmtree(d, ignore_errors=True)
            j.update(status="done", progress=100, ext=ext, finished=time.time())
        except Exception as e:
            j.update(status="error", error=str(e)[-400:])
        finally:
            try: os.remove(j["path"])
            except Exception: pass
            save()

def yt_worker():
    while True:
        jid = yq.get(); j = jobs.get(jid)
        if not j: continue
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
                sid = new_job(type="sep", name=j["name"], path="", model=j.get("model", "htdemucs"), fmt="mp3")
                path = os.path.join(UP, sid + ".mp3")
                shutil.copy(fp, path)
                jobs[sid]["path"] = path
                sq.put(sid)
        except Exception as e:
            j.update(status="error", error=str(e)[-400:])
            shutil.rmtree(od, ignore_errors=True)
        finally:
            save()

@app.route("/")
def index():
    o = lambda d: "".join(f'<option value="{k}">{v}</option>' for k, v in d.items())
    return Response(HTML.replace("%MODELS%", o(MODELS)).replace("%YTFMTS%", o(YT_FMTS)),
                    mimetype="text/html")

@app.route("/upload", methods=["POST"])
def upload():
    model = request.form.get("model", "htdemucs")
    fmt = request.form.get("fmt", "mp3")
    if model not in MODELS or fmt not in FMTS: abort(400)
    ids = []
    for f in request.files.getlist("files"):
        if not f.filename: continue
        ext = os.path.splitext(f.filename)[1].lower() or ".bin"
        jid = new_job(type="sep", name=os.path.splitext(f.filename)[0], path="", model=model, fmt=fmt)
        path = os.path.join(UP, jid + ext); f.save(path)
        jobs[jid]["path"] = path
        sq.put(jid); ids.append(jid)
    save()
    return jsonify(ids)

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

@app.route("/jobs")
def list_jobs():
    pos = {jid: i + 1 for qq in (sq, yq) for i, jid in enumerate(list(qq.queue))}
    keys = ("id", "type", "name", "model", "fmt", "status", "progress", "error", "ext")
    with lock: js = sorted(jobs.values(), key=lambda x: -x["created"])
    return jsonify([{**{k: j.get(k) for k in keys}, "queue_pos": pos.get(j["id"], 0)} for j in js])

@app.route("/dl/<jid>/<kind>")
def dl(jid, kind):
    j = jobs.get(jid)
    if not j or j["status"] != "done": abort(404)
    play = request.args.get("play") is not None
    if j.get("type") == "yt":
        if kind != "file" or not os.path.exists(j.get("file", "")): abort(404)
        return send_file(j["file"], as_attachment=not play,
                         download_name=f"{j['name']}.{j['ext']}", conditional=True)
    if kind not in ("vocals", "instrumental"): abort(404)
    f = f"{OUT}/{jid}/{kind}.{j['ext']}"
    label = "Voce" if kind == "vocals" else "Instrumental"
    return send_file(f, as_attachment=not play,
                     download_name=f"{j['name']} - {label}.{j['ext']}", conditional=True)

@app.route("/delete/<jid>", methods=["POST"])
def delete(jid):
    with lock: j = jobs.pop(jid, None)
    if j:
        shutil.rmtree(f"{OUT}/{jid}", ignore_errors=True)
        shutil.rmtree(f"{YTD}/{jid}", ignore_errors=True)
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
.err{color:#ff6b6b;font-size:12px;margin-top:8px;white-space:pre-wrap;word-break:break-word}
</style></head><body><div class="w">
<h1>🎤 Vocal Remover</h1><div class="sub">Separare voce / instrumental cu AI (Demucs) · Descărcare YouTube</div>
<div class="tabs"><button class="t on" data-t="sep">🎤 Separare voce</button><button class="t" data-t="yt">▶️ YouTube</button></div>

<section id="sep">
<div class="drop" id="drop">📂 Trage fișiere aici sau apasă pentru a alege<br>
<small style="color:var(--mu)">MP3, WAV, FLAC, M4A, OGG, chiar și MP4/MKV</small>
<input type="file" id="f" multiple accept="audio/*,video/*" hidden></div>
<div class="row"><select id="m">%MODELS%</select>
<select id="fmt"><option value="mp3">MP3 320k</option><option value="wav">WAV</option><option value="flac">FLAC</option></select>
<button class="p" id="go">Încarcă</button></div>
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
let t0='sep';try{t0=localStorage.getItem('tab')||'sep'}catch(e){};tab(t0);

const drop=$('#drop'),inp=$('#f');
drop.onclick=()=>inp.click();
inp.onchange=()=>{files=[...inp.files];showSel()};
['dragover','dragenter'].forEach(e=>drop.addEventListener(e,ev=>{ev.preventDefault();drop.classList.add('on')}));
['dragleave','drop'].forEach(e=>drop.addEventListener(e,ev=>{ev.preventDefault();drop.classList.remove('on')}));
drop.addEventListener('drop',ev=>{files=[...ev.dataTransfer.files];showSel()});
function showSel(){$('#sel').textContent=files.length?files.length+' fișier(e): '+files.map(f=>f.name).join(', '):''}
$('#go').onclick=()=>{if(!files.length)return alert('Alege fișiere!');
 const fd=new FormData();files.forEach(f=>fd.append('files',f));fd.append('model',$('#m').value);fd.append('fmt',$('#fmt').value);
 const x=new XMLHttpRequest();x.open('POST','upload');
 x.upload.onprogress=e=>$('#sel').textContent='Încărcare: '+Math.round(e.loaded/e.total*100)+'%';
 x.onload=()=>{files=[];inp.value='';$('#sel').textContent='';load()};x.send(fd)};

const syncSep=()=>{const mp3=$('#yfmt').value==='mp3';$('#ysep').disabled=!mp3;if(!mp3)$('#ysep').checked=false;
 $('#ysep').parentElement.style.opacity=mp3?1:.4};
$('#yfmt').onchange=syncSep;syncSep();
$('#ygo').onclick=async()=>{const u=$('#urls').value.trim();if(!u)return alert('Lipește un link!');
 const fd=new FormData();fd.append('urls',u);fd.append('fmt',$('#yfmt').value);
 fd.append('sep',$('#ysep').checked?'1':'0');fd.append('model',$('#m').value);
 const r=await fetch('yt',{method:'POST',body:fd});if(!r.ok)return alert('Eroare server');
 const ids=await r.json();if(!ids.length)return alert('Niciun link valid');$('#urls').value='';load()};

const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
function card(j){const yt=j.type==='yt';
 const st={queued:'⏳ În așteptare'+(j.queue_pos?' (#'+j.queue_pos+')':''),processing:'⚙️ '+(yt?'Descărcare ':'Procesare ')+j.progress+'%',done:'✅ Gata',error:'❌ Eroare'}[j.status];
 const meta=yt?(j.fmt==='mp3'?'YouTube · MP3':'YouTube · '+(j.fmt==='best'?'max':j.fmt+'p')):j.model+' · '+j.fmt;
 let body='';
 if(j.status==='processing'||j.status==='queued')body=`<div class="bar"><i style="width:${j.progress}%"></i></div>`;
 if(j.status==='done'){
  if(yt){const s=`dl/${j.id}/file`;
   body=`<div class="res one"><div>${j.fmt==='mp3'?`<audio controls preload="none" src="${s}?play=1"></audio>`:`<video controls preload="none" src="${s}?play=1"></video>`}<a class="d" href="${s}">⬇ Descarcă</a></div></div>`}
  else body=`<div class="res">${['vocals','instrumental'].map(k=>`<div><b>${k==='vocals'?'🎤 Voce':'🎵 Instrumental'}</b>
   <audio controls preload="none" src="dl/${j.id}/${k}?play=1"></audio><a class="d" href="dl/${j.id}/${k}">⬇ Descarcă</a></div>`).join('')}</div>`}
 if(j.status==='error')body=`<div class="err">${esc(j.error)}</div>`;
 return `<div class="job"><div class="top"><div class="nm">${yt?'▶️':'🎤'} ${esc(j.name)}</div>
  <div><span class="st">${st} · ${esc(meta)}</span><button class="x" title="Șterge" onclick="del('${j.id}')">✕</button></div></div>${body}</div>`}
async function load(){try{const d=await (await fetch('jobs')).json();$('#list').innerHTML=d.map(card).join('')}catch(e){}}
// nu reîncarcă lista cât timp rulează audio/video
setInterval(()=>{if(![...document.querySelectorAll('audio,video')].some(a=>!a.paused))load()},2500);
async function del(id){if(confirm('Ștergi?')){await fetch('delete/'+id,{method:'POST'});load()}}
load();
</script></body></html>"""

load()
threading.Thread(target=sep_worker, daemon=True).start()
threading.Thread(target=yt_worker, daemon=True).start()

if __name__ == "__main__":
    from waitress import serve
    serve(app, host="0.0.0.0", port=int(os.environ.get("PORT", 8095)), threads=8)
PYEOF

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

echo "==> Serviciu systemd..."
cat > /etc/systemd/system/vocal-remover.service <<EOF
[Unit]
Description=Vocal Remover (Demucs + YouTube Web UI)
After=network.target

[Service]
User=$APPUSER
WorkingDirectory=$BASE
Environment=PORT=$PORT
Environment=OMP_NUM_THREADS=$(nproc)
Environment=PATH=/usr/local/bin:/usr/bin:/bin:$BASE/venv/bin
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
if [ "$SETUP_NGINX" = "yes" ]; then
  echo "==> nginx pentru $DOMAIN/vocal/ ..."
  command -v nginx >/dev/null 2>&1 || apt-get install -y -qq nginx >/dev/null
  CONF=$(nginx -V 2>&1 | grep -o -- '--conf-path=[^ ]*' | cut -d= -f2)
  NDIR=$(dirname "${CONF:-/etc/nginx/nginx.conf}")
  SNIP="$NDIR/vocal-remover.conf"
  HTP="$NDIR/.htpasswd-vocal"
  BK="/root/nginx-backup-vocal-$(date +%Y%m%d-%H%M%S)"

  printf '%s:%s\n' "$VR_USER" "$(openssl passwd -apr1 "$VR_PASS")" > "$HTP"
  chmod 644 "$HTP"

  cat > "$SNIP" <<'EOF'
# Vocal Remover – inclus în server block-ul domeniului
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
EOF
  sed -i "s|__HTP__|$HTP|; s|__PORT__|$PORT|" "$SNIP"

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
    EXTURL="$DOMAIN/vocal/"
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
echo " ✅ Vocal Remover + YouTube instalat!"
echo " 🌐 Local:  http://$IP:$PORT"
[ -n "$EXTURL" ] && echo " 🌍 Extern: https://$EXTURL  (sau http://, după cum e domeniul)  user: $VR_USER"
echo " Log:     journalctl -u vocal-remover -f"
echo " Restart: sudo systemctl restart vocal-remover"
echo "============================================"
