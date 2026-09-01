#!/usr/bin/env bash
# AsenaDPI kurulum — Debian / Ubuntu / Kali / Arch / Fedora / openSUSE.
# Normal kullanici olarak calistir (sudo'yu kendisi cagirir):  ./install.sh
# root olarak da calisir (container/CI): sudo gerekmez.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ZAPRET_URL="https://github.com/bol-van/zapret"
ZAPRET_DIR="/usr/local/share/asena-dpi/zapret"
BINDIR="/usr/local/bin"
USER_NAME="$(id -un)"
CFG="$HOME/.config/asena-dpi"

say() { printf '\033[1;36m>> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

# root ise sudo gerekmez; degilse sudo kullan (yoksa hata)
if [ "$(id -u)" = 0 ]; then SUDO=""; else
  command -v sudo >/dev/null || die "root degilsin ve sudo yok. root olarak calistir ya da sudo kur."
  SUDO="sudo"
fi

# --- 1) dagitim + paket yoneticisi ---
. /etc/os-release 2>/dev/null || true
say "Dagitim: ${PRETTY_NAME:-bilinmiyor}"
if   command -v apt-get >/dev/null; then PM=apt
elif command -v pacman  >/dev/null; then PM=pacman
elif command -v dnf     >/dev/null; then PM=dnf
elif command -v zypper  >/dev/null; then PM=zypper
else die "Desteklenen paket yoneticisi yok (apt/pacman/dnf/zypper)."; fi

say "Bagimliliklar kuruluyor ($PM)..."
case "$PM" in
  apt)
    # ZORUNLU build/runtime deps (tek basina -> her zaman kurulur)
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt-get update -y
    $SUDO apt-get install -y git make gcc nftables curl ca-certificates iptables python3 python3-pip \
        zlib1g-dev libcap-dev libnetfilter-queue-dev libnfnetlink-dev libmnl-dev
    # PySide6 apt'te (Debian'da olabilir; Ubuntu 24.04'te YOK -> pip fallback yakalar) - best-effort
    $SUDO apt-get install -y python3-pyside6.qtwidgets python3-pyside6.qtgui python3-pyside6.qtcore 2>/dev/null || true
    ;;
  pacman)
    $SUDO pacman -Sy --needed --noconfirm git make gcc nftables curl base-devel \
        zlib libcap libnetfilter_queue libnfnetlink libmnl python
    $SUDO pacman -S --needed --noconfirm pyside6 2>/dev/null || true
    ;;
  dnf)
    $SUDO dnf install -y git make gcc nftables curl iptables python3 python3-pip \
        zlib-devel libcap-devel libnetfilter_queue-devel libnfnetlink-devel libmnl-devel
    $SUDO dnf install -y python3-pyside6 2>/dev/null || true
    ;;
  zypper)
    $SUDO zypper install -y git make gcc nftables curl python3 python3-pip \
        zlib-devel libcap-devel libnetfilter_queue-devel libnfnetlink-devel libmnl-devel
    $SUDO zypper install -y python3-pyside6 2>/dev/null || true
    ;;
esac

# PySide6 dogrula, yoksa pip fallback
if ! python3 -c 'import PySide6.QtWidgets' 2>/dev/null; then
  say "PySide6 paketten gelmedi -> pip ile kuruluyor..."
  python3 -m pip install --user PySide6 2>/dev/null \
    || python3 -m pip install --user --break-system-packages PySide6 2>/dev/null \
    || say "UYARI: PySide6 kurulamadi (tray calismaz). Elle: pip install PySide6"
fi

# --- 2) zapret'i indir + nfqws ---
say "zapret indiriliyor..."
$SUDO mkdir -p "$(dirname "$ZAPRET_DIR")"
if [ -d "$ZAPRET_DIR/.git" ]; then
  $SUDO git -C "$ZAPRET_DIR" pull --ff-only || true
else
  $SUDO git clone --depth 1 "$ZAPRET_URL" "$ZAPRET_DIR"
fi

say "nfqws derleniyor (make -C nfq)..."
if $SUDO make -C "$ZAPRET_DIR/nfq" >/dev/null 2>&1 && [ -x "$ZAPRET_DIR/nfq/nfqws" ]; then
  $SUDO install -m755 "$ZAPRET_DIR/nfq/nfqws" "$BINDIR/nfqws"
  say "nfqws derlendi ✓"
else
  say "Derleme olmadi, repodaki hazir binary aranıyor..."
  B="$($SUDO find "$ZAPRET_DIR/binaries" -type f -name nfqws 2>/dev/null | head -1)"
  [ -n "$B" ] || die "nfqws derlenemedi. Eksik gelistirme kutuphanesi olabilir (zlib / libnetfilter_queue / libnfnetlink / libmnl -dev)."
  $SUDO install -m755 "$B" "$BINDIR/nfqws"
  say "hazir nfqws kuruldu ✓"
fi
[ -x "$ZAPRET_DIR/nfq/nfqws" ] || $SUDO install -Dm755 "$BINDIR/nfqws" "$ZAPRET_DIR/nfq/nfqws"

# --- 3) scriptler + tray ---
say "Scriptler kuruluyor -> $BINDIR"
for f in asena-dpi-on asena-dpi-off asena-dpi-optimize asena-dpi-update asena-dpi-tray; do
  $SUDO install -m755 "$REPO_DIR/bin/$f" "$BINDIR/$f"
done

# --- 4) sudoers (parolasiz on/off/optimize) — yalniz normal kullanicida ---
if [ "$USER_NAME" != root ]; then
  say "sudoers (parolasiz kontrol) ..."
  echo "$USER_NAME ALL=(root) NOPASSWD: $BINDIR/asena-dpi-on, $BINDIR/asena-dpi-off, $BINDIR/asena-dpi-optimize, $BINDIR/asena-dpi-update" \
    | $SUDO tee /etc/sudoers.d/asena-dpi >/dev/null
  $SUDO chmod 440 /etc/sudoers.d/asena-dpi
fi

# --- 5) NetworkManager dispatcher (ag degisince reapply) ---
if [ -d /etc/NetworkManager/dispatcher.d ]; then
  say "Ag-degisikligi hook'u (NetworkManager) ..."
  $SUDO install -m755 "$REPO_DIR/dispatcher/90-asena-dpi" /etc/NetworkManager/dispatcher.d/90-asena-dpi
else
  say "NetworkManager yok — ag-degisikligi otomatik reapply atlandi (tray'den 'DNS onar')."
fi

# --- 6) kullanici config ---
say "Ayar/blacklist -> $CFG"
mkdir -p "$CFG"
echo "$REPO_DIR" > "$CFG/repo_dir"   # 'Güncelle' bunu kullanır (git pull)
[ -f "$CFG/blacklist.txt" ] || cp "$REPO_DIR/config/blacklist.txt" "$CFG/blacklist.txt"
[ -f "$CFG/settings.conf" ] || cat > "$CFG/settings.conf" <<EOF
# AsenaDPI ayarlari (tray yazar)
MODE=blacklist
HTTP=1
HTTP2=1
HTTP3=bypass
EOF

# --- 7) autostart (tum masaustleri: XDG) ---
say "Autostart (XDG .desktop) ..."
mkdir -p "$HOME/.config/autostart"
cat > "$HOME/.config/autostart/asena-dpi-tray.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=AsenaDPI
Comment=DPI/DNS bypass tray
Exec=$BINDIR/asena-dpi-tray
Icon=network-vpn
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

# --- 8) GNOME tray ikonu (GNOME legacy tray GOSTERMEZ -> AppIndicator uzantisi) ---
DESKTOP="${XDG_CURRENT_DESKTOP:-}${DESKTOP_SESSION:-}"
if echo "$DESKTOP" | grep -qi gnome || pgrep -x gnome-shell >/dev/null 2>&1; then
  say "GNOME algilandi — tray ikonu icin AppIndicator uzantisi kuruluyor..."
  case "$PM" in
    apt)    $SUDO apt-get install -y gnome-shell-extension-appindicator || true ;;
    dnf)    $SUDO dnf install -y gnome-shell-extension-appindicator || true ;;
    zypper) $SUDO zypper install -y gnome-shell-extension-appindicator || true ;;
    pacman) echo "   Arch+GNOME: AUR'dan 'gnome-shell-extension-appindicator' kur." ;;
  esac
  echo "   Etkinlestir: 'Extensions' -> AppIndicator/KStatusNotifier ON (ya da oturumu kapat/ac)."
fi

say "KURULUM TAMAM ✅"
echo
echo "  1) En iyi stratejiyi bul:   sudo asena-dpi-optimize"
echo "  2) Bağlan:                  sudo asena-dpi-on   (kapat: sudo asena-dpi-off)"
echo "  3) Tray'i başlat:           asena-dpi-tray &    (sonraki açılışta otomatik)"
echo
echo "  Tray: SOL tık = ayarlar penceresi · SAĞ tık = hızlı menü"
