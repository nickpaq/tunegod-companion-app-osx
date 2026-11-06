#!/bin/zsh
# Builds the TuneGod Link driver and installs it into /Library/Audio/Plug-Ins/HAL, then restarts the Mac's audio service so it loads.
# The copy needs an administrator: macOS shows its own password dialog. All audio on the Mac stops for a second while the service
# restarts. `--uninstall` removes the driver instead.
set -e
cd "${0:A:h}/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
DEST=/Library/Audio/Plug-Ins/HAL/TuneGodLink.driver
RESTART="launchctl kickstart -k system/com.apple.audio.coreaudiod || killall coreaudiod"

if [[ "$1" == "--uninstall" ]]; then
  osascript -e "do shell script \"rm -rf '$DEST'; $RESTART\" with administrator privileges with prompt \"TuneGod Companion wants to remove its audio driver.\""
  echo "Removed $DEST"
  exit 0
fi

mkdir -p build
command -v xcodegen >/dev/null && xcodegen generate -q
xcodebuild -project TuneGodCompanion.xcodeproj -scheme TuneGodLinkDriver -configuration Release -derivedDataPath build/dd build \
  2>&1 | sed $'s/\x1b\\[[0-9;]*m//g' > build/driver-build.log || { grep -E "error:" -A3 build/driver-build.log | head -40; exit 1; }
grep -q "BUILD SUCCEEDED" build/driver-build.log || { grep -E "error:" -A3 build/driver-build.log | head -40; exit 1; }
BUILT="$PWD/build/dd/Build/Products/Release/TuneGodLink.driver"
echo "Built $BUILT"
osascript -e "do shell script \"rm -rf '$DEST' && cp -R '$BUILT' '$DEST' && chown -R root:wheel '$DEST' && ($RESTART)\" with administrator privileges with prompt \"TuneGod Companion wants to install its audio driver (TuneGod iPhone).\""
echo "Installed $DEST"
