#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ZAPRET_URL="https://github.com/bol-van/zapret"
ZAPRET_DIR="/usr/local/share/asena-dpi/zapret"
BINDIR="/usr/local/bin"
USER_NAME="$(id -un)"
CFG="$HOME/.config/asena-dpi"

GUM_BIN="gum"
if ! command -v gum >/dev/null 2>&1; then
    printf '\033[1;36m>> Arayuz araci (gum) indiriliyor...\033[0m\n'
    GUM_DIR="/tmp/asena_gum"
    mkdir -p "$GUM_DIR"
    curl -sL "https://github.com/charmbracelet/gum/releases/download/v2.0.2/gum_2.0.2_Linux_x86_64.tar.gz" | tar -xz -C "$GUM_DIR" 2>/dev/null || true
    GUM_BIN="$(find "$GUM_DIR" -name "gum" -type f | head -n 1)"
    [ -n "$GUM_BIN" ] && chmod +x "$GUM_BIN" || GUM_BIN="gum"
fi

banner() {
    if [ -x "$GUM_BIN" ]; then
        "$GUM_BIN" style --foreground 212 --border-foreground 212 --border double --align center --width 50 --margin "1 2" --padding "1 2" "AsenaDPI Kurulum"
    else
        printf '\033[1;35m=== AsenaDPI Kurulum ===\033[0m\n'
    fi
}

spin() {
    local title="$1"
    shift
    if [ -x "$GUM_BIN" ]; then
        "$GUM_BIN" spin --spinner dot --title "$title" -- bash -c "$*"
    else
        printf '\033[1;36m>> %s\033[0m\n' "$title"
        bash -c "$*"
    fi
}

say() {
    if [ -x "$GUM_BIN" ]; then
        "$GUM_BIN" style --foreground 86 ">> $1"
    else
        printf '\033[1;36m>> %s\033[0m\n' "$1"
    fi
}

die() {
    if [ -x "$GUM_BIN" ]; then
        "$GUM_BIN" style --foreground 196 "!! $1"
    else
        printf '\033[1;31m!! %s\033[0m\n' "$1" >&2
    fi
    exit 1
}

clear
banner

if [ -x "$GUM_BIN" ]; then
    "$GUM_BIN" confirm "AsenaDPI'yi kurmak istiyor musunuz?" || { say "Iptal edildi."; exit 0; }
fi

if [ "$(id -u)" = 0 ]; then SUDO=""; else
  command -v sudo >/dev/null || die "root degilsin ve sudo yok. root olarak calistir ya da sudo kur."
  SUDO="sudo"
fi

. /etc/os-release 2>/dev/null || true
say "Dagitim: ${PRETTY_NAME:-bilinmiyor}"
if   command -v apt-get >/dev/null; then PM=apt
elif command -v pacman  >/dev/null; then PM=pacman
elif command -v dnf     >/dev/null; then PM=dnf
elif command -v zypper  >/dev/null; then PM=zypper
else die "Desteklenen paket yoneticisi yok (apt/pacman/dnf/zypper)."; fi

export SUDO PM
step_deps() {
case "$PM" in
  apt)
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt-get update -y >/dev/null 2>&1 || true
    $SUDO apt-get install -y git make gcc nftables curl ca-certificates iptables python3 python3-pip zlib1g-dev libcap-dev libnetfilter-queue-dev libnfnetlink-dev libmnl-dev >/dev/null 2>&1
    $SUDO apt-get install -y python3-pyside6.qtwidgets python3-pyside6.qtgui python3-pyside6.qtcore >/dev/null 2>&1 || true
    ;;
  pacman)
    $SUDO pacman -Sy --noconfirm >/dev/null 2>&1 || true
    for p in git make gcc nftables curl base-devel zlib libcap libnetfilter_queue libnfnetlink libmnl python pyside6; do
        $SUDO pacman -S --needed --noconfirm "$p" >/dev/null 2>&1 || true
    done
    ;;
  dnf)
    $SUDO dnf install -y git make gcc nftables curl iptables python3 python3-pip zlib-devel libcap-devel libnetfilter_queue-devel libnfnetlink-devel libmnl-devel >/dev/null 2>&1
    $SUDO dnf install -y python3-pyside6 >/dev/null 2>&1 || true
    ;;
  zypper)
    $SUDO zypper install -y git make gcc nftables curl python3 python3-pip zlib-devel libcap-devel libnetfilter_queue-devel libnfnetlink-devel libmnl-devel >/dev/null 2>&1
    $SUDO zypper install -y python3-pyside6 >/dev/null 2>&1 || true
    ;;
esac
}
export -f step_deps
spin "Bagimliliklar kuruluyor ($PM)" "step_deps"

step_pyside() {
if ! python3 -c 'import PySide6.QtWidgets' 2>/dev/null; then
  python3 -m pip install --user PySide6 >/dev/null 2>&1 \
    || python3 -m pip install --user --break-system-packages PySide6 >/dev/null 2>&1 || true
fi
}
export -f step_pyside
spin "PySide6 kontrol ediliyor" "step_pyside"

export ZAPRET_DIR ZAPRET_URL
step_zapret() {
$SUDO mkdir -p "$(dirname "$ZAPRET_DIR")"
if [ -d "$ZAPRET_DIR/.git" ]; then
  $SUDO git -C "$ZAPRET_DIR" pull --ff-only >/dev/null 2>&1 || true
else
  $SUDO git clone --depth 1 "$ZAPRET_URL" "$ZAPRET_DIR" >/dev/null 2>&1
fi
}
export -f step_zapret
spin "Zapret indiriliyor" "step_zapret"

export BINDIR
step_nfq() {
if $SUDO make -C "$ZAPRET_DIR/nfq" >/dev/null 2>&1 && [ -x "$ZAPRET_DIR/nfq/nfqws" ]; then
  $SUDO install -m755 "$ZAPRET_DIR/nfq/nfqws" "$BINDIR/nfqws"
else
  B="$($SUDO find "$ZAPRET_DIR/binaries" -type f -name nfqws 2>/dev/null | head -1)"
  [ -n "$B" ] && $SUDO install -m755 "$B" "$BINDIR/nfqws" || exit 1
fi
[ -x "$ZAPRET_DIR/nfq/nfqws" ] || $SUDO install -Dm755 "$BINDIR/nfqws" "$ZAPRET_DIR/nfq/nfqws"
}
export -f step_nfq
spin "nfqws hazirlaniyor" "step_nfq"

step_mdig() {
for sub in mdig tpws; do
  $SUDO make -C "$ZAPRET_DIR/$sub" >/dev/null 2>&1 || true
done
}
export -f step_mdig
spin "Bilesenler derleniyor (mdig, tpws)" "step_mdig"

export REPO_DIR
step_scripts() {
for f in asena-dpi-on asena-dpi-off asena-dpi-optimize asena-dpi-update asena-dpi-tray; do
  $SUDO install -m755 "$REPO_DIR/bin/$f" "$BINDIR/$f"
done
}
export -f step_scripts
spin "Scriptler kopyalaniyor" "step_scripts"

export USER_NAME
step_cfg() {
if [ "$USER_NAME" != root ]; then
  echo "$USER_NAME ALL=(root) NOPASSWD: $BINDIR/asena-dpi-on, $BINDIR/asena-dpi-off, $BINDIR/asena-dpi-optimize, $BINDIR/asena-dpi-update" | $SUDO tee /etc/sudoers.d/asena-dpi >/dev/null
  $SUDO chmod 440 /etc/sudoers.d/asena-dpi
fi

if [ -d /etc/NetworkManager/dispatcher.d ]; then
  $SUDO install -m755 "$REPO_DIR/dispatcher/90-asena-dpi" /etc/NetworkManager/dispatcher.d/90-asena-dpi
fi
}
export -f step_cfg
spin "Sistem ayarlari (Sudoers & NetworkManager)" "step_cfg"

export CFG
step_user() {
mkdir -p "$CFG"
echo "$REPO_DIR" > "$CFG/repo_dir"
[ -f "$REPO_DIR/config/asena-dpi.png" ] && cp -f "$REPO_DIR/config/asena-dpi.png" "$CFG/asena-dpi.png"
[ -f "$CFG/blacklist.txt" ] || cp "$REPO_DIR/config/blacklist.txt" "$CFG/blacklist.txt"
[ -f "$CFG/settings.conf" ] || cat > "$CFG/settings.conf" <<EOF
MODE=blacklist
HTTP=1
HTTP2=1
HTTP3=bypass
EOF

mkdir -p "$HOME/.config/autostart"
cat > "$HOME/.config/autostart/asena-dpi-tray.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=AsenaDPI
Comment=DPI/DNS bypass tray
Exec=$BINDIR/asena-dpi-tray
Icon=$CFG/asena-dpi.png
StartupWMClass=asena-dpi
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
}
export -f step_user
spin "Kullanici dosyalari ve Autostart" "step_user"

step_gnome() {
DESKTOP="${XDG_CURRENT_DESKTOP:-}${DESKTOP_SESSION:-}"
if echo "$DESKTOP" | grep -qi gnome || pgrep -x gnome-shell >/dev/null 2>&1; then
  case "$PM" in
    apt)    $SUDO apt-get install -y gnome-shell-extension-appindicator >/dev/null 2>&1 || true ;;
    dnf)    $SUDO dnf install -y gnome-shell-extension-appindicator >/dev/null 2>&1 || true ;;
    zypper) $SUDO zypper install -y gnome-shell-extension-appindicator >/dev/null 2>&1 || true ;;
  esac
fi
}
export -f step_gnome
spin "GNOME eklentileri (gerekliyse)" "step_gnome"

if [ "$USER_NAME" != root ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    pkill -f "$BINDIR/asena-dpi-tray" 2>/dev/null || true
    setsid "$BINDIR/asena-dpi-tray" >/dev/null 2>&1 < /dev/null &
fi

echo ""
if [ -x "$GUM_BIN" ]; then
    "$GUM_BIN" style --foreground 212 --border-foreground 212 --border normal --align left --width 60 --margin "1 2" --padding "1 2" "Kurulum Tamamlandi!" "Tray sistem tepsisinde baslatildi." "En iyi strateji icin: sudo asena-dpi-optimize"
else
    say "KURULUM TAMAM"
fi
