# 🎤 Vocal Remover + YouTube Downloader

Separare **voce / instrumental** cu AI ([Demucs](https://github.com/facebookresearch/demucs) de la Meta) și **descărcare YouTube** (video MP4 / MP3, prin [yt-dlp](https://github.com/yt-dlp/yt-dlp)), cu interfață web simplă, pentru servere Ubuntu.

Încarci o melodie (sau un videoclip), iar aplicația îți dă două piste separate: **Voce** și **Instrumental** (karaoke).

## ✨ Funcții

- 📂 Drag & drop, cu mai multe fișiere deodată
- 🎵 Acceptă MP3, WAV, FLAC, M4A, OGG și chiar MP4 / MKV (sunetul se extrage automat)
- 🤖 3 modele AI:
  - `htdemucs`: rapid
  - `htdemucs_ft`: calitate maximă (~4x mai lent)
  - `mdx_extra`: alternativ
- 💾 Export în MP3 320k, WAV sau FLAC
- ▶️ Ascultare direct în browser și descărcare
- ⏳ Coadă de procesare, păstrată și după restart
- 🔁 Serviciu systemd, pornește automat la boot
- 📱 Interfață responsive (merge și pe telefon)
- 🥁 Mod **4 piste**: Voce, Tobe, Bas, Altele (pian, chitară, synth) + Instrumental complet

### 🎼 Tonalitate și tempo
- Detectează automat **tonalitatea** (ex. `Am · La minor`) și **BPM-ul** fiecărei melodii
- **Transpunere** ±12 semitonuri și **schimbare tempo** 50–150%, independent, fără să afecteze calitatea (Rubber Band)
- Arată live noua tonalitate și noul BPM înainte de aplicare
- Se aplică pe Instrumental, Voce sau ambele (pentru voce se păstrează timbrul natural)
- Mod **„Doar tonalitate/tempo”** pentru melodii pe care vrei doar să le transpui, fără separare

### 📝 Subtitrări AI (Whisper) · pagină separată `/subtitrari/`
- Pagină proprie, **protejată cu utilizator și parolă** (login cu sesiune, „ține-mă minte 30 de zile”, blocare după 5 încercări greșite)
- Parola se setează la instalare și se schimbă oricând cu `sudo subtitrari-parola`
- Încarci un film, clip sau fișier audio și primești subtitrarea în **SRT**, **VTT** și **TXT**
- Detectare automată a limbii, sau alegi tu (română, engleză etc.)
- **Traducere în română** 🇷🇴: din engleză direct (Opus-MT, offline), din alte limbi prin engleză
- **Folosește subtitrarea din film**: dacă MKV/MP4 conține o subtitrare text în engleză (sau română), o extrage și o traduce direct, fără Whisper (mult mai rapid și mai exact); sare peste piste „forced” și curăță etichetele SDH ([muzică], NUME:)
- Poți încărca și o subtitrare **.srt în engleză** și o primești tradusă în română
- Opțiune **„Traducere în engleză”**
- 3 modele: `small` (rapid), `medium` (recomandat), `large-v3-turbo` (cel mai precis)
- Fișierul se numește `Film.ro.srt`, gata de pus lângă film în Jellyfin / Plex
- Modelul se descarcă automat la prima utilizare (~0.5–1.6 GB)

### 📺 Integrare CineVerse
Dacă pe server rulează [CineVerse](https://github.com/maxvideostar/CineVerse), installer-ul îi citește automat folderele media și dă drepturile necesare:
- **Subtitrări direct din bibliotecă**: cauți filmul sau episodul în CineVerse și îl transcrii fără upload; `Film.ro.srt` se pune automat lângă film
- **„Trimite în CineVerse”** pentru subtitrări generate din fișiere încărcate (alegi filmul) și pentru clipuri video YouTube (alegi biblioteca și, opțional, un subfolder)
- CineVerse detectează automat fișierele noi (copiere atomică, fără fișiere incomplete)

### ▶️ YouTube
- Lipești unul sau mai multe link-uri (unul pe linie)
- **MP3 320k** cu copertă și metadate, sau **video MP4** la calitate maximă (până la 4K), 1080p, 720p sau 480p
- Opțiunea **„+ separă vocea”**: după descărcarea MP3-ului, melodia intră automat la separare
- yt-dlp se actualizează zilnic automat (cron)

### 🌍 Acces extern (opțional)
Scriptul poate configura nginx pe domeniul tău la `/vocal/`, protejat cu utilizator și parolă. Detectează automat server block-ul existent pentru domeniu și face backup înainte de modificare.

## 🖥️ Cerințe

- Ubuntu 22.04 / 24.04
- ~2 GB spațiu liber (PyTorch + modele)
- Recomandat: minim 8 GB RAM

Procesarea rulează pe **CPU**. Pe un i5/i7 de generația 9, o melodie de 4 minute durează ~1–3 minute cu `htdemucs`.

## 🚀 Instalare

```bash
git clone https://github.com/maxvideostar/Vocal-Remover.git
cd Vocal-Remover
sudo bash vocal-remover-install.sh
```

Sau direct:

```bash
wget https://raw.githubusercontent.com/maxvideostar/Vocal-Remover/main/vocal-remover-install.sh
sudo bash vocal-remover-install.sh
```

După instalare, deschide în browser:

```
http://IP-SERVER:8095
```

## ⚙️ Administrare

| Acțiune | Comandă |
|---|---|
| Status | `sudo systemctl status vocal-remover` |
| Log-uri live | `journalctl -u vocal-remover -f` |
| Restart | `sudo systemctl restart vocal-remover` |
| Oprire | `sudo systemctl stop vocal-remover` |

Fișierele aplicației se află în `/opt/vocal-remover/`:

```
/opt/vocal-remover/
├── app.py        # aplicația web (Flask + Waitress)
├── venv/         # mediu Python
├── uploads/      # fișiere în curs de procesare
├── output/       # rezultate (voce + instrumental)
├── youtube/      # descărcări YouTube
├── whisper-models/ # modele Whisper (descărcate la prima utilizare)
└── jobs.json     # istoric / coadă
```

Acces: Vocal Remover pe `http://IP-SERVER:8095`, Subtitrări pe `http://IP-SERVER:8095/subtitrari/` (extern: `https://domeniu/vocal/` și `https://domeniu/subtitrari/`).

Pentru alt port, modifică `PORT=` în script înainte de instalare.

Instalare neinteractivă, cu nginx:

```bash
sudo DOMAIN=exemplu.ro SETUP_NGINX=yes VR_USER=admin VR_PASS='parola' SUB_USER=admin SUB_PASS='parola2' bash vocal-remover-install.sh
```

Scriptul poate fi rulat din nou oricând pentru update; istoricul se păstrează.

## 🗑️ Dezinstalare

```bash
sudo systemctl disable --now vocal-remover
sudo rm /etc/systemd/system/vocal-remover.service
sudo rm -rf /opt/vocal-remover /etc/cron.daily/vocal-remover-ytdlp /usr/local/bin/subtitrari-parola
sudo systemctl daemon-reload
```

## ⚠️ Securitate

Aplicația nu are autentificare. Folosește-o în rețeaua locală sau pune-o în spatele unui reverse proxy (nginx) cu parolă și HTTPS dacă o expui pe internet.

Descarcă doar conținut pe care ai dreptul să-l folosești.

## 📜 Licență

MIT. Demucs este distribuit sub licență MIT de Meta Research.

---

Made by **NetStreaming** · [netstreaming.eu](https://netstreaming.eu)
