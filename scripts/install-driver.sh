#!/bin/sh
# Install the PUA Call Mic AudioServerPlugIn and reload Core Audio.
# Usage: sudo scripts/install-driver.sh   (build first with `make driver`)
# Restarting coreaudiod interrupts all audio for a second or two.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/build/PuaCallMic.driver"
DEST=/Library/Audio/Plug-Ins/HAL/PuaCallMic.driver
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
[ -d "$SRC" ] || { echo "missing $SRC; run: make driver" >&2; exit 1; }
codesign --verify --strict "$SRC"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
chown -R root:wheel "$DEST"
chmod -R go-w "$DEST"
killall coreaudiod 2>/dev/null || launchctl kickstart -k system/com.apple.audio.coreaudiod
sleep 3
echo "installed $DEST"
system_profiler SPAudioDataType 2>/dev/null | grep -q "PUA Call Mic:" && echo "PUA Call Mic is loaded" || echo "PUA Call Mic not listed yet; if it stays missing, restart the Mac"
