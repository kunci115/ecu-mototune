#!/bin/bash
# Build MotoTune Ride for a device and push it onto a USB-connected Garmin (MTP) — no store needed.
# usage: garmin/sideload.sh [device id, default fr265]
# needs: Connect IQ SDK (SDK Manager), Homebrew openjdk@21 + libmtp, ~/.Garmin/ConnectIQ/developer_key
set -e
DEV=${1:-fr265}
cd "$(dirname "$0")/MotoTuneRide"
export JAVA_HOME=/opt/homebrew/opt/openjdk@21 PATH=/opt/homebrew/opt/openjdk@21/bin:$PATH
SDK=$(ls -d ~/Library/Application\ Support/Garmin/ConnectIQ/Sdks/connectiq-sdk-mac-* | sort | tail -1)
mkdir -p bin
"$SDK/bin/monkeyc" -d "$DEV" -f monkey.jungle -o "bin/MotoTuneRide-$DEV.prg" -y ~/.Garmin/ConnectIQ/developer_key -w -l 1
[ -x ../tools/mtpsend ] || clang -O2 -I/opt/homebrew/include -L/opt/homebrew/lib -lmtp ../tools/mtpsend.c -o ../tools/mtpsend
APPS=$(mtp-folders 2>/dev/null | awk '/^[0-9]+\t  Apps$/ {print $1}')
[ -n "$APPS" ] || { echo "GARMIN/Apps folder not found — is the watch plugged in (data cable) and unlocked?"; exit 1; }
../tools/mtpsend "bin/MotoTuneRide-$DEV.prg" MotoTuneRide.prg "$APPS"
echo "done — unplug the watch; MotoTune Ride appears in the activity/app list after it reloads."
