#!/bin/sh
# Remove the PUA Call Mic AudioServerPlugIn. Usage: sudo scripts/uninstall-driver.sh
set -eu
DEST=/Library/Audio/Plug-Ins/HAL/PuaCallMic.driver
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
rm -rf "$DEST"
killall coreaudiod 2>/dev/null || launchctl kickstart -k system/com.apple.audio.coreaudiod
echo "removed $DEST"
