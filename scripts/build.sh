#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
swift build -c release
launcher_bin_dir=$(swift build -c release --show-bin-path)
launcher_app=${1:-'dist/魔力宝贝启动器.app'}
mkdir -p "$launcher_app/Contents/MacOS" "$launcher_app/Contents/Resources"
zsh scripts/build_icon.sh "$launcher_app/Contents/Resources/AppIcon.icns"
cp "$launcher_bin_dir/CGLauncher" "$launcher_app/Contents/MacOS/CGLauncher"
i686-w64-mingw32-gcc -O2 -Wall -Wextra -static bridge/cg_bridge.c -o "$launcher_app/Contents/Resources/cg_bridge.exe"
i686-w64-mingw32-gcc -O2 -Wall -Wextra -static bridge/cg_network.c -o "$launcher_app/Contents/Resources/cg_network.exe" -lws2_32
cat > "$launcher_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.crossgate.native-launcher</string>
<key>CFBundleName</key><string>魔力宝贝启动器</string>
<key>CFBundleDisplayName</key><string>魔力宝贝启动器</string>
<key>CFBundleExecutable</key><string>CGLauncher</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.3</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$launcher_app"
print "Built: $PWD/$launcher_app"
