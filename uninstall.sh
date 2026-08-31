#!/usr/bin/env bash
# AsenaDPI kaldirma. Normal kullanici olarak calistir: ./uninstall.sh
set -euo pipefail
BINDIR="/usr/local/bin"
say() { printf '\033[1;36m>> %s\033[0m\n' "$*"; }

say "Durduruluyor..."
sudo "$BINDIR/asena-dpi-off" 2>/dev/null || true

say "Dosyalar kaldiriliyor (sudo)..."
sudo rm -f "$BINDIR"/asena-dpi-on "$BINDIR"/asena-dpi-off "$BINDIR"/asena-dpi-optimize "$BINDIR"/asena-dpi-tray
sudo rm -f /etc/sudoers.d/asena-dpi
sudo rm -f /etc/NetworkManager/dispatcher.d/90-asena-dpi
sudo rm -rf /usr/local/share/asena-dpi
rm -f "$HOME/.config/autostart/asena-dpi-tray.desktop"

echo
echo "nfqws ($BINDIR/nfqws), ayarlar (~/.config/asena-dpi) ve blacklist DOKUNULMADI."
echo "Tamamen silmek istersen:  sudo rm -f $BINDIR/nfqws && rm -rf ~/.config/asena-dpi"
say "Kaldirildi."
