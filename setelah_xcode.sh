#!/bin/zsh
# Jalankan SEKALI setelah Xcode selesai di-install dari App Store:
#   ~/Documents/Projects/aracer-xtune-re/setelah_xcode.sh
# Aman diulang. Akan minta password Mac (sudo) untuk mengaktifkan Xcode.
set -u
cd "$(dirname "$0")"
ok()   { print -P "%F{green}OK%f   $1" }
gagal(){ print -P "%F{red}GAGAL%f $1"; exit 1 }

echo "== 1. Cek Xcode terpasang"
XC=/Applications/Xcode.app
[[ -d $XC ]] || gagal "Xcode belum ada di /Applications. Tunggu App Store selesai, lalu jalankan lagi."
ok "ditemukan $XC"

echo "== 2. Aktifkan Xcode sebagai developer directory (butuh password)"
if [[ "$(xcode-select -p 2>/dev/null)" != "$XC/Contents/Developer" ]]; then
  sudo xcode-select -s "$XC/Contents/Developer" || gagal "xcode-select"
fi
ok "developer dir: $(xcode-select -p)"

echo "== 3. Terima lisensi dan first-launch (sekali saja, bisa 1-2 menit)"
sudo xcodebuild -license accept 2>/dev/null || true
sudo xcodebuild -runFirstLaunch >/dev/null 2>&1 || true
xcodebuild -version | head -1 | read XCV; ok "$XCV"

echo "== 4. Cek platform iOS"
if ! xcodebuild -showsdks 2>/dev/null | grep -q "iphoneos"; then
  echo "   iOS SDK belum ada, mengunduh (bisa lama)..."
  xcodebuild -downloadPlatform iOS || gagal "download platform iOS. Buka Xcode > Settings > Components, install iOS."
fi
ok "iOS SDK: $(xcodebuild -showsdks 2>/dev/null | grep iphoneos | tail -1 | sed 's/.*-sdk //')"

echo "== 5. Build + test ARacerKit dengan toolchain Xcode"
cd ARacerKit
rm -rf .build
swift build 2>&1 | tail -1
swift test 2>&1 | grep -E "✘|Test run|error:" || gagal "swift test"

echo "== 6. Build untuk target iOS (library saja, memastikan SDK iOS bekerja)"
xcodebuild -scheme ARacerKit -destination 'generic/platform=iOS Simulator' -quiet build 2>&1 | grep -E "error|warning: no" | head -5
ok "library ARacerKit bisa dikompilasi untuk iOS"

echo
print -P "%F{green}== SELESAI.%f Buka Claude Code di folder proyek dan bilang: \"xcode sudah siap\""
