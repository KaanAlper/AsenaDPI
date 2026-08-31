#!/usr/bin/env bash
# AsenaDPI kurulum — Debian / Ubuntu / Kali / Arch / Fedora.
# Normal kullanici olarak calistir (sudo'yu kendisi cagirir):  ./install.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ZAPRET_URL="https://github.com/bol-van/zapret"
ZAPRET_DIR="/usr/local/share/asena-dpi/zapret"
BINDIR="/usr/local/bin"
USER_NAME="$(id -un)"
CFG="$HOME/.config/asena-dpi"

say() { printf '\033[1;36m>> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }
[ "$USER_NAME" = root ] && die "sudo ile DEGIL, normal kullanici olarak calistir: ./install.sh"

# --- 1) dagitim + paket yoneticisi ---
. /etc/os-release 2>/dev/null || true
say "Dagitim: ${PRETTY_NAME:-bilinmiyor}"
if   command -v apt-get >/dev/null; then PM=apt
elif command -v pacman  >/dev/null; then PM=pacman
elif command -v dnf     >/dev/null; then PM=dnf
elif command -v zypper  >/dev/null; then PM=zypper
else die "Desteklenen paket yoneticisi yok (apt/pacman/dnf/zypper)."; fi

say "Bagimliliklar kuruluyor ($PM) — sudo parolasi sorulabilir..."
case "$PM" in
  apt)
    sudo apt-get update -y
    sudo apt-get install -y git make gcc nftables curl ca-certificates \
        libnetfilter-queue-dev iptables \
        python3 python3-pyside6.qtwidgets python3-pyside6.qtgui python3-pyside6.qtcore \
        || sudo apt-get install -y git make gcc nftables curl libnetfilter-queue-dev python3
    ;;
  pacman)
    sudo pacman -Sy --needed --noconfirm git make gcc nftables curl base-devel \
        libnetfilter_queue pyside6 python
    ;;
  dnf)
    sudo dnf install -y git make gcc nftables curl libnetfilter_queue-devel \
        python3 python3-pyside6 || true
    ;;
  zypper)
    sudo zypper install -y git make gcc nftables curl libnetfilter_queue-devel \
        python3 python3-pyside6 || true
    ;;
esac

# PySide6 dogrula, yoksa pip fallback
if ! python3 -c 'import PySide6.QtWidgets' 2>/dev/null; then
  say "PySide6 paketten gelmedi -> pip ile kuruluyor..."
  python3 -m pip install --user PySide6 2>/dev/null \
    || python3 -m pip install --user --break-system-packages PySide6 \
    || die "PySide6 kurulamadi. Elle: pip install PySide6"
fi

# --- 2) zapret'i indir + nfqws ---
say "zapret indiriliyor ($ZAPRET_URL)..."
sudo mkdir -p "$(dirname "$ZAPRET_DIR")"
if [ -d "$ZAPRET_DIR/.git" ]; then
  sudo git -C "$ZAPRET_DIR" pull --ff-only || true
else
  sudo git clone --depth 1 "$ZAPRET_URL" "$ZAPRET_DIR"
fi

say "nfqws derleniyor..."
if sudo make -C "$ZAPRET_DIR" nfqws >/dev/null 2>&1 && [ -x "$ZAPRET_DIR/nfq/nfqws" ]; then
  sudo install -m755 "$ZAPRET_DIR/nfq/nfqws" "$BINDIR/nfqws"
  say "nfqws derlendi ✓"
else
  # derleme olmadi -> zapret'in hazir static binary'sini kullan (arch'e gore)
  say "Derleme olmadi, hazir binary aranıyor..."
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) B="$ZAPRET_DIR/binaries/x86_64/nfqws" ;;
    aarch64|arm64) B="$ZAPRET_DIR/binaries/aarch64/nfqws" ;;
    armv7l|armhf) B="$ZAPRET_DIR/binaries/arm/nfqws" ;;
    *) B="" ;;
  esac
  [ -n "$B" ] && [ -x "$B" ] || die "nfqws ne derlendi ne de $ARCH icin hazir binary var."
  sudo install -m755 "$B" "$BINDIR/nfqws"
  say "hazir nfqws kuruldu ($ARCH) ✓"
fi

# blockcheck'in bu nfqws'i kullanmasi icin (kendi nfq/nfqws'i yoksa)
[ -x "$ZAPRET_DIR/nfq/nfqws" ] || sudo install -Dm755 "$BINDIR/nfqws" "$ZAPRET_DIR/nfq/nfqws"

# --- 3) scriptler + tray ---
say "Scriptler kuruluyor -> $BINDIR"
for f in asena-dpi-on asena-dpi-off asena-dpi-optimize asena-dpi-tray; do
  sudo install -m755 "$REPO_DIR/bin/$f" "$BINDIR/$f"
done

# --- 4) sudoers (parolasiz on/off/optimize) ---
say "sudoers (parolasiz kontrol) ..."
sudo tee /etc/sudoers.d/asena-dpi >/dev/null <<EOF
$USER_NAME ALL=(root) NOPASSWD: $BINDIR/asena-dpi-on, $BINDIR/asena-dpi-off, $BINDIR/asena-dpi-optimize
EOF
sudo chmod 440 /etc/sudoers.d/asena-dpi

# --- 5) NetworkManager dispatcher (ag degisince reapply) ---
if [ -d /etc/NetworkManager/dispatcher.d ]; then
  say "Ag-degisikligi hook'u (NetworkManager) ..."
  sudo install -m755 "$REPO_DIR/dispatcher/90-asena-dpi" /etc/NetworkManager/dispatcher.d/90-asena-dpi
else
  say "NetworkManager yok — ag-degisikligi otomatik reapply atlandi (tray'den 'DNS onar' kullan)."
fi

# --- 6) kullanici config ---
say "Ayar/blacklist -> $CFG"
mkdir -p "$CFG"
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

say "KURULUM TAMAM ✅"
echo
echo "  1) En iyi stratejiyi bul:   sudo asena-dpi-optimize"
echo "  2) Bağlan:                  sudo asena-dpi-on   (kapat: sudo asena-dpi-off)"
echo "  3) Tray'i başlat:           asena-dpi-tray &    (sonraki açılışlarda otomatik)"
echo
echo "  Tray: SOL tık = ayarlar penceresi · SAĞ tık = hızlı menü"
