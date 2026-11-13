#!/bin/bash
# Installe OPost-it pour l'utilisateur courant (sans sudo) :
#   ~/.local/bin/OPost-it  +  raccourci dans le menu des applications.
# À lancer depuis le dossier qui contient l'exécutable « OPost-it » et « icon.png ».
set -e
cd "$(dirname "$0")"

BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
ICONS="$HOME/.local/share/icons/hicolor/256x256/apps"
mkdir -p "$BIN" "$APPS" "$ICONS"

install -m 755 OPost-it "$BIN/OPost-it"
[ -f icon.png ] && install -m 644 icon.png "$ICONS/opost-it.png"

cat > "$APPS/opost-it.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=OPost-it
Comment=Notes de tâches façon Stickies
Exec=$BIN/OPost-it
Icon=opost-it
Categories=Utility;Office;
StartupNotify=false
EOF

command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" >/dev/null 2>&1 || true
echo "✓ OPost-it est installé : cherche « OPost-it » dans le menu des applications."
