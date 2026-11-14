#!/bin/sh
# Builds and adds Seoritsu to the app launcher (user-local, no root needed).
set -e
cd "$(dirname "$0")"
./build.sh
BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
mkdir -p "$BIN" "$DATA/applications" "$DATA/icons/hicolor/scalable/apps"
ln -sf "$PWD/seoritsu" "$BIN/seoritsu" # symlink: later ./build.sh runs update the launcher too
cp assets/seoritsu.svg "$DATA/icons/hicolor/scalable/apps/seoritsu.svg"
# absolute Exec: launchers do not always have ~/.local/bin in PATH
sed "s|^Exec=seoritsu|Exec=$BIN/seoritsu|" packaging/seoritsu.desktop > "$DATA/applications/seoritsu.desktop"
command -v update-desktop-database >/dev/null && update-desktop-database "$DATA/applications" || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$DATA/icons/hicolor" || true
echo "installed: $BIN/seoritsu, $DATA/applications/seoritsu.desktop"
