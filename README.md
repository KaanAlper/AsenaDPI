<div align="center">

# AsenaDPI

**Beat Turkish DPI *and* DNS poisoning with one tray toggle — no VPN, no tunnel.**

Tek tuşla DPI **ve** DNS zehirlemesini aş — VPN yok, tünel yok, throttle yok.

[![Platform](https://img.shields.io/badge/platform-Linux-1793D1?style=flat-square&logo=linux&logoColor=white)](#installation--kurulum)
[![Engine](https://img.shields.io/badge/engine-zapret%20%C2%B7%20nfqws-2A59FF?style=flat-square)](https://github.com/bol-van/zapret)
[![Tray](https://img.shields.io/badge/tray-PySide6-41CD52?style=flat-square&logo=qt&logoColor=white)](#usage--kullan%C4%B1m)
[![Distros](https://img.shields.io/badge/Debian%20%C2%B7%20Ubuntu%20%C2%B7%20Kali%20%C2%B7%20Arch-supported-orange?style=flat-square)](#supported-distros--desteklenen-da%C4%9F%C4%B1t%C4%B1mlar)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

<br>

<table>
<tr>
<td align="center" width="33%"><img src="docs/screenshots/tray.png" width="100%" alt="Tray menu"></td>
<td align="center" width="33%"><img src="docs/screenshots/settings.png" width="100%" alt="Settings window"></td>
<td align="center" width="33%"><img src="docs/screenshots/optimize.png" width="100%" alt="Auto-optimize"></td>
</tr>
<tr>
<td align="center"><sub><b>Tray</b><br>Left-click settings, right-click quick menu</sub></td>
<td align="center"><sub><b>Settings</b><br>Batch changes, live "what changes" preview</sub></td>
<td align="center"><sub><b>Auto-optimize</b><br>blockcheck finds the best strategy for you</sub></td>
</tr>
</table>

**[English](#english) · [Türkçe](#türkçe)**

</div>

---

## English

### What this is

A small Linux tray app that unblocks censored sites (Discord, and whatever you add to
the list) using [zapret](https://github.com/bol-van/zapret)'s `nfqws` for packet-level
DPI evasion **plus** encrypted DNS (DoT) for DNS poisoning. No VPN, no tunnel, no
account, no throttling — your traffic goes out natively, only the handshake is nudged.

Turkey (and many networks) censors in **two different ways**, often on different
networks. AsenaDPI handles both at once:

| Censorship | What happens | AsenaDPI's answer |
|---|---|---|
| **DPI** (workplace, mobile) | Real IP is reached, but the TLS handshake is reset based on the SNI hostname | `nfqws` packet desync (fake/split) — the DPI can't read the SNI |
| **DNS poisoning** (home ISP, TTNet) | The domain resolves to a fake block-page IP (`195.175.254.x`) | Encrypted DNS over TLS to `1.1.1.1` — you get the real IP |

### Installation & setup

**One command (Linux):**

```bash
curl -fsSL https://raw.githubusercontent.com/KaanAlper/AsenaDPI/master/get.sh | bash
```

<sub>On **Windows** use the PowerShell one-liner in the [Windows](#windows) section instead — this `curl … | bash` is Linux only.</sub>

<sub>Or manually: `git clone https://github.com/KaanAlper/AsenaDPI.git && cd AsenaDPI && ./install.sh`
— run it **without** sudo; it calls sudo itself.</sub>

The installer detects your distro, installs dependencies, **downloads and builds zapret's
`nfqws` automatically** (falls back to zapret's prebuilt binary if it can't compile),
installs the scripts + tray, sets up passwordless control, a network-change hook, and
autostart.

Then:

```bash
sudo asena-dpi-optimize     # find the best DPI strategy for YOUR network (a few minutes)
sudo asena-dpi-on           # connect  (asena-dpi-off to stop)
asena-dpi-tray &            # start the tray (autostarts on next login)
```

> [!TIP]
> `asena-dpi-optimize` runs zapret's `blockcheck`, tries dozens of desync strategies
> against Discord, picks the one that works on **your** ISP (preferring network-independent
> ones), writes it to `~/.config/asena-dpi/tcp443.conf`, and applies it. Re-run it if you
> switch to a very different network and something stops working.

### Usage

The tray icon is a shield — **teal when on**, grey when off.

- **Left-click** → settings window (Qt-drawn, stays open): pick Mode / HTTP-3 / advanced
  options, review the **"what changes"** preview, hit **Apply**. Batch several changes at once.
- **Right-click** → quick menu: Connect/Disconnect, Settings, *Find best strategy*, Log,
  *Repair DNS*, Quit.

**Options**

| Option | Meaning |
|---|---|
| **Mode: Blacklist** | Only domains in your list are processed; everything else stays native-speed *(recommended)* |
| **Mode: Full** | All traffic goes through DPI-bypass |
| **HTTP/3: Bypass** | Try to push QUIC through the DPI |
| **HTTP/3: Off** | Leave QUIC alone |
| **HTTP/3: Block** | Kill QUIC → apps fall back to TCP/HTTP-2 *(fixes games on eduroam-type networks)* |
| **Advanced: HTTP / HTTP-2** | Toggle port 80 / 443 desync (leave HTTP-2 on — it's Discord & the web) |

Edit the blocked-domain list from the tray (**Blacklist…**) or at `~/.config/asena-dpi/blacklist.txt`.

### How it works

`nftables` sends only the **first few handshake packets** of connections to blocked hosts
into an NFQUEUE with the **`bypass`** flag; `nfqws` rewrites the TLS ClientHello so the DPI
can't match the SNI. Everything after the handshake — the actual data — flows **natively**,
at full speed. There is no tunnel and no proxy.

For DNS poisoning, `asena-dpi-on` points `systemd-resolved` at Cloudflare over **DNS-over-TLS**
so blocked domains resolve to their real IPs. `asena-dpi-off` reverts it.

### Fail-safe by design

| Situation | Behaviour |
|---|---|
| `nfqws` dies / is killed / crashes | `queue ... bypass` → packets pass normally, **internet never drops** |
| You switch Wi-Fi / networks | NetworkManager hook re-applies DNS + DPI automatically |
| DoT is blocked on some network | On connect it's tested; if it fails, DNS reverts → **internet stays up** |
| Reboot / hard crash | Nothing persists (kernel nft + runtime DNS + `/run`) → clean boot |
| Disconnect | nft removed + DNS restored → fully native |

### Supported distros

Debian · Ubuntu · Kali · Arch · Fedora · openSUSE (anything with `apt`/`pacman`/`dnf`/`zypper`,
`systemd-resolved`, and `nftables`).

### Troubleshooting

- **Discord still won't open** → run `sudo asena-dpi-optimize` (finds a working strategy for your ISP).
- **A game won't connect** (school/eduroam) → set **HTTP/3 → Block** and Apply.
- **DNS looks poisoned after a network change** → tray → **Repair DNS**.
- **See what's happening** → tray → **Show log**, or `cat /var/log/asena-dpi.log`.

### Uninstall

```bash
cd AsenaDPI && ./uninstall.sh
```

---

## Türkçe

### Bu ne?

Sansürlü siteleri (Discord ve listene eklediğin her şey) açan küçük bir Linux tray
uygulaması. [zapret](https://github.com/bol-van/zapret)'in `nfqws`'i ile **paket
seviyesinde DPI atlatma** + DNS zehirlemesi için **şifreli DNS (DoT)** kullanır. VPN yok,
tünel yok, hesap yok, throttle yok — trafiğin native gider, sadece el sıkışma dürtülür.

Türkiye (ve çoğu ağ) **iki farklı yolla** sansürler, çoğu zaman ağdan ağa değişir.
AsenaDPI ikisini birden halleder:

| Sansür | Ne olur | AsenaDPI'ın cevabı |
|---|---|---|
| **DPI** (iş yeri, mobil) | Gerçek IP'ye ulaşılır ama TLS el sıkışması SNI'ye göre resetlenir | `nfqws` paket desync (fake/split) — DPI SNI'yi okuyamaz |
| **DNS zehri** (ev ISP'si, TTNet) | Domain sahte blok-sayfası IP'sine (`195.175.254.x`) çözülür | `1.1.1.1`'e DNS-over-TLS — gerçek IP'yi alırsın |

### Kurulum

**Tek komut (Linux):**

```bash
curl -fsSL https://raw.githubusercontent.com/KaanAlper/AsenaDPI/master/get.sh | bash
```

<sub>**Windows** için bunun yerine [Windows](#windows) bölümündeki PowerShell tek-satırını kullan — bu `curl … | bash` yalnız Linux.</sub>

<sub>Ya da elle: `git clone https://github.com/KaanAlper/AsenaDPI.git && cd AsenaDPI && ./install.sh`
— **sudo İLE DEĞİL**, kendisi sudo çağırır.</sub>

Kurucu dağıtımını tanır, bağımlılıkları kurar, **zapret'in `nfqws`'ini otomatik indirip
derler** (derleyemezse zapret'in hazır binary'sine düşer), scriptleri + tray'i kurar,
parolasız kontrol + ağ-değişikliği hook'u + autostart ayarlar.

Sonra:

```bash
sudo asena-dpi-optimize     # AĞINA en iyi DPI stratejisini bul (birkaç dakika)
sudo asena-dpi-on           # bağlan  (durdur: asena-dpi-off)
asena-dpi-tray &            # tray'i başlat (sonraki açılışta otomatik)
```

> [!TIP]
> `asena-dpi-optimize`, zapret'in `blockcheck`'ini çalıştırır; Discord'a karşı onlarca
> strateji dener, **senin** ISP'nde çalışanı (ağdan-bağımsız olanı tercih ederek) seçer,
> `~/.config/asena-dpi/tcp443.conf`'a yazar ve uygular. Çok farklı bir ağa geçip bir şey
> bozulursa tekrar çalıştır.

### Kullanım

Tray ikonu bir kalkan — **açıkken teal**, kapalıyken gri.

- **Sol tık** → ayar penceresi (Qt çizer, açık kalır): Mod / HTTP-3 / gelişmiş seç,
  **"Değişecekler"** önizlemesine bak, **Uygula**'ya bas. Birden çok değişikliği toplu yap.
- **Sağ tık** → hızlı menü: Bağlan/Kes, Ayarlar, *En iyi stratejiyi bul*, Log,
  *DNS'i onar*, Çıkış.

**Seçenekler**

| Seçenek | Anlamı |
|---|---|
| **Mod: Blacklist** | Yalnız listendeki siteler işlenir; gerisi native hız *(önerilen)* |
| **Mod: Full** | Tüm trafik DPI-bypass'tan geçer |
| **HTTP/3: Bypass** | QUIC'i DPI'dan geçirmeye çalış |
| **HTTP/3: Kapalı** | QUIC'e dokunma |
| **HTTP/3: Engelle** | QUIC'i kes → uygulama TCP/HTTP-2'ye düşer *(eduroam tipi ağlarda oyunu düzeltir)* |
| **Gelişmiş: HTTP / HTTP-2** | Port 80 / 443 desync aç-kapa (HTTP-2'yi açık bırak — Discord & web odur) |

Engelli-domain listesini tray'den (**Blacklist…**) ya da `~/.config/asena-dpi/blacklist.txt`'ten düzenle.

### Nasıl çalışır

`nftables`, engelli hostlara giden bağlantıların yalnız **ilk birkaç el-sıkışma paketini**
`bypass` bayraklı bir NFQUEUE'ya yollar; `nfqws` TLS ClientHello'yu yeniden yazar, DPI SNI'yi
eşleyemez. El sıkışmadan sonrası — asıl veri — **native**, tam hızda akar. Tünel ya da proxy yok.

DNS zehri için `asena-dpi-on`, `systemd-resolved`'ı **DNS-over-TLS** ile Cloudflare'e
yönlendirir → engelli domainler gerçek IP'ye çözülür. `asena-dpi-off` geri alır.

### Tasarımdan fail-safe

| Durum | Davranış |
|---|---|
| `nfqws` ölür / kill / çöker | `queue ... bypass` → paketler normal geçer, **internet gitmez** |
| Wi-Fi / ağ değiştirirsin | NetworkManager hook DNS + DPI'ı otomatik yeniden uygular |
| Bir ağda DoT engelli | Bağlanınca test edilir; başarısızsa DNS geri alınır → **internet ayakta kalır** |
| Reboot / hard-crash | Hiçbir kalıntı kalmaz (kernel nft + runtime DNS + `/run`) → temiz açılış |
| Bağlantıyı kes | nft silinir + DNS geri gelir → tamamen native |

### Desteklenen dağıtımlar

Debian · Ubuntu · Kali · Arch · Fedora · openSUSE (`apt`/`pacman`/`dnf`/`zypper`,
`systemd-resolved` ve `nftables` olan her şey).

### Sorun giderme

- **Discord hâlâ açılmıyor** → `sudo asena-dpi-optimize` (ISP'ne çalışan strateji bulur).
- **Oyun bağlanmıyor** (okul/eduroam) → **HTTP/3 → Engelle** yap, Uygula.
- **Ağ değişiminden sonra DNS zehirli** → tray → **DNS'i onar**.
- **Ne olduğunu gör** → tray → **Logu göster**, ya da `cat /var/log/asena-dpi.log`.

### Kaldırma

```bash
cd AsenaDPI && ./uninstall.sh
```

---

## Windows

Windows uses zapret's **`winws.exe`** (WinDivert driver) instead of `nftables` — same desync
engine, generally stronger than GoodbyeDPI — plus native **DoH** (Windows 11) for DNS poisoning,
and the same PySide6 tray. blockcheck runs from the bundled zapret Windows tools.

Windows'ta `nftables` yerine zapret'in **`winws.exe`**'i (WinDivert sürücüsü) kullanılır — aynı
desync motoru, GoodbyeDPI'dan genelde daha güçlü — artı DNS zehri için native **DoH** (Windows 11)
ve aynı PySide6 tray. blockcheck, pakete gömülü zapret Windows araçlarından çalışır.

**One command** (normal PowerShell — the installer requests its own admin/UAC):

```powershell
irm https://raw.githubusercontent.com/KaanAlper/AsenaDPI/master/windows/get.ps1 | iex
```

<sub>Or manually: `git clone https://github.com/KaanAlper/AsenaDPI.git; cd AsenaDPI\windows;
Set-ExecutionPolicy -Scope Process Bypass -Force; .\install.ps1` (in an **admin** PowerShell).</sub>

The installer sets everything up and **starts the tray automatically**; on later boots it autostarts
elevated (no UAC). A Start-menu entry and desktop shortcut (search "AsenaDPI") are created too.

`install.ps1` downloads the zapret Windows bundle (`winws.exe` + WinDivert + blockcheck), installs
the tray, and registers it to start **elevated at logon** (a scheduled task — no repeated UAC), so
the tray manages `winws` and DoH directly. Left-click = settings, right-click = menu, same as Linux.

> [!NOTE]
> Native DoH needs **Windows 11** (Windows 10 has no built-in DoH). Requires Python 3 + PySide6
> (the installer fetches them via winget/pip if missing). This is a fresh v1 — report anything that
> breaks. / Native DoH **Windows 11** ister; Python 3 + PySide6 gerekir (installer winget/pip ile
> kurar). Yeni v1 — bozulan olursa bildir.

---

<div align="center">

Built on [zapret](https://github.com/bol-van/zapret) by bol-van · DPI/DNS bypass for Linux · MIT

<sub>Only unblock what you are legally allowed to access. Use responsibly.</sub>

</div>
