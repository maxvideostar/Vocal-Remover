# 🎤 Vocal Remover

Separare **voce / instrumental** cu AI ([Demucs](https://github.com/facebookresearch/demucs) de la Meta), cu interfață web simplă, pentru servere Ubuntu.

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
└── jobs.json     # istoric / coadă
```

Pentru alt port, modifică `PORT=` în script înainte de instalare.

## 🗑️ Dezinstalare

```bash
sudo systemctl disable --now vocal-remover
sudo rm /etc/systemd/system/vocal-remover.service
sudo rm -rf /opt/vocal-remover
sudo systemctl daemon-reload
```

## ⚠️ Securitate

Aplicația nu are autentificare. Folosește-o în rețeaua locală sau pune-o în spatele unui reverse proxy (nginx) cu parolă și HTTPS dacă o expui pe internet.

## 📜 Licență

MIT. Demucs este distribuit sub licență MIT de Meta Research.

---

Made by **NetStreaming** · [netstreaming.eu](https://netstreaming.eu)
