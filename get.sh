#!/usr/bin/env bash
# AsenaDPI tek-komut kurulum bootstrap'i:
#   curl -fsSL https://raw.githubusercontent.com/KaanAlper/AsenaDPI/master/get.sh | bash
# Repoyu klonlar (ya da gunceller) ve install.sh'i calistirir.
set -euo pipefail
REPO="https://github.com/KaanAlper/AsenaDPI.git"
DIR="${ASENADPI_DIR:-$HOME/AsenaDPI}"

command -v git >/dev/null || { echo "!! once 'git' kur (apt/pacman/dnf install git)"; exit 1; }

if [ -d "$DIR/.git" ]; then
  echo ">> Mevcut kurulum guncelleniyor: $DIR"
  git -C "$DIR" pull --ff-only || true
else
  echo ">> Klonlaniyor -> $DIR"
  git clone --depth 1 "$REPO" "$DIR"
fi

cd "$DIR"
exec ./install.sh
