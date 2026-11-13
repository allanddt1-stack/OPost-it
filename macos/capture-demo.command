#!/bin/bash
# Captures d'écran de OPost-it en mode démo (notes fictives).
# Tes vraies notes ne sont ni ouvertes ni modifiées ; la OPost-it habituelle peut rester ouverte.
set -e
APP="/Applications/OPost-it.app"
[ -d "$APP" ] || APP="$HOME/Applications/OPost-it.app"
if [ ! -x "$APP/Contents/MacOS/OPost-it" ]; then
  echo "OPost-it n'est pas installée : lance d'abord l'installateur."
  exit 1
fi

# Sécurité : une version sans mode démo ouvrirait tes vraies notes
VERSION="$(defaults read "$APP/Contents/Info" CFBundleVersion 2>/dev/null || echo 0)"
if [ "$VERSION" -lt 11 ]; then
  echo "La version installée ne connaît pas le mode démo (build $VERSION)."
  echo "Lance d'abord OPost-it_punaise.command pour la mettre à jour, puis relance ce script."
  exit 1
fi

OUT="$HOME/Desktop/OPost-it-captures"
mkdir -p "$OUT"
echo "→ Ouverture des notes de démonstration et captures…"
"$APP/Contents/MacOS/OPost-it" --demo --screenshots "$OUT"
echo "✓ Images enregistrées dans $OUT :"
ls -1 "$OUT"
open "$OUT"
