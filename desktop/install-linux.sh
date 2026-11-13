#!/bin/bash
# Installe Post-it pour l'utilisateur courant (sans sudo) :
#   ~/.local/bin/Post-it  +  raccourci dans le menu des applications.
# À lancer depuis le dossier qui contient l'exécutable « Post-it » et « icon.png ».
set -e
cd "$(dirname "$0")"

BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
ICONS="$HOME/.local/share/icons/hicolor/256x256/apps"
mkdir -p "$BIN" "$APPS" "$ICONS"

install -m 755 Post-it "$BIN/Post-it"
[ -f icon.png ] && install -m 644 icon.png "$ICONS/post-it.png"

cat > "$APPS/post-it.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Post-it
Comment=Notes de tâches façon Stickies
Exec=$BIN/Post-it
Icon=post-it
Categories=Utility;Office;
StartupNotify=false
EOF

command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" >/dev/null 2>&1 || true
echo "✓ Post-it est installé : cherche « Post-it » dans le menu des applications."
