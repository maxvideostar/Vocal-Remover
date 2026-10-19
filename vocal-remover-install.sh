#!/bin/bash
# ============================================================
#  Vocal Remover (Demucs AI) + Web UI — HP ProDesk / Ubuntu 24.04
#  Rulare:  sudo bash vocal-remover-install.sh
#  Acces:   http://IP-SERVER:8095
# ============================================================
set -e
[ "$EUID" -ne 0 ] && { echo "Rulează cu sudo!"; exit 1; }

APPUSER="${SUDO_USER:-netstreaming}"
BASE="/opt/vocal-remover"
PORT=8095

echo "==> Pachete sistem..."
apt-get update -qq
apt-get install -y -qq python3-venv python3-pip ffmpeg >/dev/null

echo "==> Mediu Python..."
mkdir -p "$BASE"/{uploads,output}
python3 -m venv "$BASE/venv"
"$BASE/venv/bin/pip" install -q --upgrade pip wheel
# torch CPU (fixat pe 2.5.1 – compatibil sigur cu demucs)
"$BASE/venv/bin/pip" install -q torch==2.5.1 torchaudio==2.5.1 --index-url https://download.pytorch.org/whl/cpu
"$BASE/venv/bin/pip" install -q demucs==4.0.1 flask waitress soundfile

echo "==> Aplicație web..."
cat > "$BASE/app.py" <<'PYEOF'
import os, re, uuid, glob, json, shutil, threading, queue, subprocess, time
from flask import Flask, request, jsonify, send_file, abort, Response

BASE = "/opt/vocal-remover"
UP, OUT = f"{BASE}/uploads", f"{BASE}/output"
DB = f"{BASE}/jobs.json"
PY = f"{BASE}/venv/bin/python"
os.makedirs(UP, exist_ok=True); os.makedirs(OUT, exist_ok=True)

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 2 * 1024 ** 3
MODELS = {"htdemucs": "Rapid (htdemucs)",
          "htdemucs_ft": "Calitate maximă (htdemucs_ft, ~4x mai lent)",
          "mdx_extra": "MDX Extra (alternativ)"}
FMTS = {"mp3": ["--mp3", "--mp3-bitrate", "320"], "wav": [], "flac": ["--flac"]}

lock = threading.Lock()
q = queue.Queue()
jobs = {}

def save():
    with lock:
        json.dump(jobs, open(DB, "w"))

def load():
    global jobs
    if os.path.exists(DB):
        try: jobs = json.load(open(DB))
        except: jobs = {}
    for jid, j in jobs.items():
        if j["status"] in ("queued", "processing"):
            if os.path.exists(j.get("path", "")):
                j["status"], j["progress"] = "queued", 0; q.put(jid)
            else:
                j["status"], j["error"] = "error", "Întrerupt la restart"

def worker():
    while True:
        jid = q.get(); j = jobs.get(jid)
        if not j: continue
        j["status"], j["progress"] = "processing", 0; save()
        od = os.path.join(OUT, jid)
        cmd = [PY, "-m", "demucs", "--two-stems=vocals", "-n", j["model"],
               "-o", od, *FMTS[j["fmt"]], j["path"]]
        try:
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, bufsize=1)
            log = []
            for line in p.stdout:
                log.append(line); log = log[-30:]
                m = re.search(r"(\d+)%\|", line)
                if m: j["progress"] = int(m.group(1))
            p.wait()
            v = glob.glob(f"{od}/*/*/vocals.*"); n = glob.glob(f"{od}/*/*/no_vocals.*")
            if p.returncode != 0 or not v or not n:
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
            except: pass
            save()

@app.route("/")
def index():
    opts = "".join(f'<option value="{k}">{v}</option>' for k, v in MODELS.items())
    return Response(HTML.replace("%MODELS%", opts), mimetype="text/html")

@app.route("/upload", methods=["POST"])
def upload():
    model = request.form.get("model", "htdemucs")
    fmt = request.form.get("fmt", "mp3")
    if model not in MODELS or fmt not in FMTS: abort(400)
    ids = []
    for f in request.files.getlist("files"):
        if not f.filename: continue
        jid = uuid.uuid4().hex[:12]
        ext = os.path.splitext(f.filename)[1].lower() or ".bin"
        path = os.path.join(UP, jid + ext); f.save(path)
        jobs[jid] = dict(id=jid, name=os.path.splitext(f.filename)[0], path=path,
                         model=model, fmt=fmt, status="queued", progress=0,
                         created=time.time())
        q.put(jid); ids.append(jid)
    save()
    return jsonify(ids)

@app.route("/jobs")
def list_jobs():
    pos = list(q.queue)
    out = []
    for j in sorted(jobs.values(), key=lambda x: -x["created"]):
        d = {k: j.get(k) for k in ("id", "name", "model", "fmt", "status", "progress", "error", "ext")}
        d["queue_pos"] = pos.index(j["id"]) + 1 if j["id"] in pos else 0
        out.append(d)
    return jsonify(out)

@app.route("/dl/<jid>/<kind>")
def dl(jid, kind):
    j = jobs.get(jid)
    if not j or j["status"] != "done" or kind not in ("vocals", "instrumental"): abort(404)
    f = f"{OUT}/{jid}/{kind}.{j['ext']}"
    label = "Voce" if kind == "vocals" else "Instrumental"
    return send_file(f, as_attachment=request.args.get("play") is None,
                     download_name=f"{j['name']} - {label}.{j['ext']}", conditional=True)

@app.route("/delete/<jid>", methods=["POST"])
def delete(jid):
    j = jobs.pop(jid, None)
    if j:
        shutil.rmtree(f"{OUT}/{jid}", ignore_errors=True)
        try: os.remove(j["path"])
        except: pass
        save()
    return jsonify(ok=True)

HTML = r"""<!doctype html><html lang="ro"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Vocal Remover</title><style>
:root{--bg:#0f1115;--card:#181b22;--bd:#2a2f3a;--tx:#e8eaf0;--mu:#8b93a7;--ac:#e50914;--ok:#2ecc71}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--tx);font-family:system-ui,sans-serif}
.w{max-width:820px;margin:0 auto;padding:24px 16px}h1{margin:0 0 4px;font-size:26px}
.sub{color:var(--mu);margin-bottom:20px}
.drop{border:2px dashed var(--bd);border-radius:14px;padding:34px 16px;text-align:center;cursor:pointer;transition:.2s;background:var(--card)}
.drop.on,.drop:hover{border-color:var(--ac)}
.row{display:flex;gap:10px;margin:14px 0;flex-wrap:wrap}
select,button{background:var(--card);color:var(--tx);border:1px solid var(--bd);border-radius:10px;padding:10px 12px;font-size:14px}
select{flex:1;min-width:160px}button.p{background:var(--ac);border-color:var(--ac);font-weight:600;cursor:pointer}
.job{background:var(--card);border:1px solid var(--bd);border-radius:12px;padding:14px;margin-top:12px}
.top{display:flex;justify-content:space-between;gap:10px;align-items:center}
.nm{font-weight:600;word-break:break-word}.st{color:var(--mu);font-size:13px;white-space:nowrap}
.bar{height:6px;background:var(--bd);border-radius:4px;margin-top:10px;overflow:hidden}
.bar i{display:block;height:100%;background:var(--ac);transition:width .5s}
.res{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:12px}
@media(max-width:600px){.res{grid-template-columns:1fr}}
.res div{background:var(--bg);border-radius:10px;padding:10px}.res b{font-size:13px}
audio{width:100%;margin:6px 0}a.d{color:var(--ok);font-size:13px;text-decoration:none}
.x{background:none;border:none;color:var(--mu);cursor:pointer;font-size:18px;padding:0 4px}
.err{color:#ff6b6b;font-size:12px;margin-top:8px;white-space:pre-wrap}
</style></head><body><div class="w">
<h1>🎤 Vocal Remover</h1><div class="sub">Separare voce / instrumental cu AI (Demucs)</div>
<div class="drop" id="drop">📂 Trage fișiere aici sau apasă pentru a alege<br>
<small style="color:var(--mu)">MP3, WAV, FLAC, M4A, OGG, chiar și MP4/MKV</small>
<input type="file" id="f" multiple accept="audio/*,video/*" hidden></div>
<div class="row"><select id="m">%MODELS%</select>
<select id="fmt"><option value="mp3">MP3 320k</option><option value="wav">WAV</option><option value="flac">FLAC</option></select>
<button class="p" id="go">Încarcă</button></div>
<div id="sel" class="sub"></div><div id="list"></div></div>
<script>
const $=s=>document.querySelector(s);let files=[];
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
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
let open={};
async function load(){const d=await (await fetch('jobs')).json();
 $('#list').innerHTML=d.map(j=>{let st={queued:'⏳ În așteptare'+(j.queue_pos?' (#'+j.queue_pos+')':''),processing:'⚙️ Procesare '+j.progress+'%',done:'✅ Gata',error:'❌ Eroare'}[j.status];
  let body='';
  if(j.status==='processing'||j.status==='queued')body=`<div class="bar"><i style="width:${j.progress}%"></i></div>`;
  if(j.status==='done')body=`<div class="res">${['vocals','instrumental'].map(k=>`<div><b>${k==='vocals'?'🎤 Voce':'🎵 Instrumental'}</b>
   <audio controls preload="none" src="dl/${j.id}/${k}?play=1"></audio><a class="d" href="dl/${j.id}/${k}">⬇ Descarcă</a></div>`).join('')}</div>`;
  if(j.status==='error')body=`<div class="err">${esc(j.error)}</div>`;
  return `<div class="job" id="j${j.id}"><div class="top"><div class="nm">${esc(j.name)}</div>
  <div><span class="st">${st} · ${j.model} · ${j.fmt}</span><button class="x" onclick="del('${j.id}')">✕</button></div></div>${body}</div>`}).join('');
}
// nu reîncarcă lista cât timp se redă audio
setInterval(()=>{if(![...document.querySelectorAll('audio')].some(a=>!a.paused))load()},2500);
async function del(id){if(confirm('Ștergi?')){await fetch('delete/'+id,{method:'POST'});load()}}
load();
</script></body></html>"""

load()
threading.Thread(target=worker, daemon=True).start()

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

echo "==> Serviciu systemd..."
cat > /etc/systemd/system/vocal-remover.service <<EOF
[Unit]
Description=Vocal Remover (Demucs Web UI)
After=network.target

[Service]
User=$APPUSER
WorkingDirectory=$BASE
Environment=PORT=$PORT
Environment=OMP_NUM_THREADS=$(nproc)
ExecStart=$BASE/venv/bin/python $BASE/app.py
Restart=always
Nice=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vocal-remover

if ufw status 2>/dev/null | grep -q active; then ufw allow $PORT/tcp >/dev/null; fi

IP=$(hostname -I | awk '{print $1}')
echo ""
echo "============================================"
echo " ✅ Vocal Remover instalat!"
echo " 🌐 http://$IP:$PORT"
echo " Log:     journalctl -u vocal-remover -f"
echo " Restart: sudo systemctl restart vocal-remover"
echo "============================================"
