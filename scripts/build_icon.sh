#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."

launcher_icon_output=${1:-work/AppIcon.icns}
launcher_iconset=work/AppIcon.iconset
mkdir -p "$launcher_iconset" "$(dirname "$launcher_icon_output")"

# Preserve the selected artwork and its alpha; generate macOS's standard icon sizes.
for launcher_icon_size in 16 32 128 256 512; do
    sips -z "$launcher_icon_size" "$launcher_icon_size" Assets/AppIcon-source.png \
        --out "$launcher_iconset/icon_${launcher_icon_size}x${launcher_icon_size}.png" >/dev/null
    launcher_icon_retina=$((launcher_icon_size * 2))
    sips -z "$launcher_icon_retina" "$launcher_icon_retina" Assets/AppIcon-source.png \
        --out "$launcher_iconset/icon_${launcher_icon_size}x${launcher_icon_size}@2x.png" >/dev/null
done
iconutil -c icns "$launcher_iconset" -o "$launcher_icon_output"
