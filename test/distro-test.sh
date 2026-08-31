#!/usr/bin/env bash
# AsenaDPI cok-dagitim kurulum testi — Docker/Podman ile IZOLE.
# Container kendi network namespace'inde calisir -> host nftables/DNS'ine DOKUNMAZ,
# kendi dosya sistemi -> senin sistemine DOKUNMAZ. install.sh + nfqws derlemesini dogrular.
#
#   test/distro-test.sh                 # ubuntu debian arch fedora
#   test/distro-test.sh ubuntu arch     # secili
#   test/distro-test.sh kali            # kali (imaj buyuk)
set -u

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$(command -v podman || command -v docker || true)"
[ -n "$ENGINE" ] || { echo "!! docker ya da podman gerekli"; exit 1; }
# docker root gerektiriyorsa sudo'ya dus
$ENGINE info >/dev/null 2>&1 || ENGINE="sudo $ENGINE"

declare -A IMG=(
  [ubuntu]=ubuntu:24.04
  [debian]=debian:12
  [kali]=kalilinux/kali-rolling
  [arch]=archlinux:latest
  [fedora]=fedora:latest
  [opensuse]=opensuse/tumbleweed
)

if [ $# -gt 0 ]; then TARGETS=("$@"); else TARGETS=(ubuntu debian arch fedora); fi

PASS=(); FAIL=()
for d in "${TARGETS[@]}"; do
  img="${IMG[$d]:-$d}"
  echo "======================================================================"
  echo ">> TEST: $d  ($img)"
  echo "======================================================================"
  if $ENGINE run --rm -v "$REPO_DIR":/src:ro "$img" bash -c '
      set -e
      cp -r /src /root/AsenaDPI && cd /root/AsenaDPI
      ./install.sh
      echo "----- DOGRULAMA -----"
      command -v nfqws >/dev/null && echo "  ✓ nfqws: $(command -v nfqws)" || { echo "  ✗ nfqws"; exit 1; }
      for f in asena-dpi-on asena-dpi-off asena-dpi-optimize asena-dpi-tray; do
        command -v "$f" >/dev/null && echo "  ✓ $f" || { echo "  ✗ $f"; exit 1; }
      done
      test -f /usr/local/share/asena-dpi/zapret/blockcheck.sh && echo "  ✓ blockcheck (optimize icin)" || echo "  ! blockcheck yok"
      python3 -c "import PySide6.QtWidgets" 2>/dev/null && echo "  ✓ PySide6 (tray)" || echo "  ! PySide6 yok (tray calismaz, kurulum sorunu degil)"
      echo ">> $d: KURULUM BASARILI"
  '; then
    PASS+=("$d")
  else
    FAIL+=("$d")
  fi
done

echo "======================================================================"
echo "SONUC:  PASS: ${PASS[*]:-yok}    FAIL: ${FAIL[*]:-yok}"
echo "======================================================================"
[ ${#FAIL[@]} -eq 0 ]
