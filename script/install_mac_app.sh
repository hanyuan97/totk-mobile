#!/usr/bin/env bash
# Puts a double-clickable app in /Applications (or the folder given) that starts the game from this checkout:
# "The Legend of Zelda - Tears of the Kingdom.app" is a thin wrapper around work/build/Zelda-Mobile.app, which
# script/build_and_run.sh makes, so a rebuild needs no reinstall. The icon is the game's own, work/icon.jpg: the
# 256x256 icon.jpg from the game's control data (the NSP's NACP; nxnative's build script extracts it as
# extract/<version>/icon.jpg). Without it the app gets the generic icon.
# The wrapper runs work/build/zelda_probe rather than the copy inside Zelda-Mobile.app: macOS files a program that lives
# inside an app bundle under that bundle for privacy permissions, and the ad-hoc signature changes with every build, so
# with the checkout on an external disk the bundled copy loses "removable volumes" access after a rebuild and the game
# dies at its first file ("FATAL open work/patched/main.fixups.tsv"). Started this way it counts as this wrapper app,
# whose permission stays, and the Dock shows this wrapper's name and icon.
set -euo pipefail
cd "$(dirname "$0")/.."
dest=${1:-/Applications}
name="The Legend of Zelda - Tears of the Kingdom"
src="$PWD/work/build/Zelda-Mobile.app/Contents"
test -x "$src/MacOS/launch" || { echo 'Run ./script/build_and_run.sh once first (it builds work/build/Zelda-Mobile.app)' >&2; exit 1; }
app="$dest/$name.app/Contents"
mkdir -p "$app/MacOS" "$app/Resources"
cat > "$app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.zelda-mobile.launcher</string>
<key>CFBundleName</key><string>The Legend of Zelda: Tears of the Kingdom</string>
<key>CFBundleDisplayName</key><string>The Legend of Zelda: Tears of the Kingdom</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>launch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cat > "$app/MacOS/launch" <<LAUNCH
#!/usr/bin/env bash
# Wrapper made by script/install_mac_app.sh: the game itself lives in the checkout below.
ZELDA_PROBE="$PWD/work/build/zelda_probe" exec "$src/MacOS/launch"
LAUNCH
chmod +x "$app/MacOS/launch"
if [[ -f "$src/Resources/AppIcon.icns" ]]; then cp "$src/Resources/AppIcon.icns" "$app/Resources/AppIcon.icns"; else rm -f "$app/Resources/AppIcon.icns"; fi
touch "$dest/$name.app"   # Finder and the Dock re-read the icon
echo "Installed $dest/$name.app → $src"
