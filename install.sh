#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Check dependencies
for cmd in ffmpeg zenity; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd is not installed. Please install it first."
        exit 1
    fi
done

if ! command -v magick &>/dev/null; then
    echo "WARNING: ImageMagick is not installed. Image conversion will use ffmpeg (limited format support)."
fi

# Create ~/Scripts if needed
mkdir -p ~/Scripts

# Install script
cp "$SCRIPT_DIR/ffmpegconvert.sh" ~/Scripts/
chmod +x ~/Scripts/ffmpegconvert.sh

# Install desktop files
mkdir -p ~/.local/share/kio/servicemenus
for desktop in "$SCRIPT_DIR"/*.desktop; do
    cp "$desktop" ~/.local/share/kio/servicemenus/
    chmod +x ~/.local/share/kio/servicemenus/"$(basename "$desktop")"
done

echo "Done. Right-click files in Dolphin to convert."
