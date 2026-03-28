# KDE Plasma FFmpeg Converter

Right-click to convert audio/video/images in KDE Plasma. Uses FFmpeg. I only deal in KDE rn, feel free to PR for more compatibility

## Requirements
1. ffmpeg
2. zenity
3. imagemagick (optional but you want it — ffmpeg can't do SVG/EPS/RAW)
4. gifski (optional, for video to GIF)

## Install

```bash
./install.sh
```

or do it manually idk im not your mom:

1. put `ffmpegconvert.sh` in `~/Scripts/`
2. Put `.desktop` files in `~/.local/share/kio/servicemenus`
3. `chmod +x` all the `.desktop` files in `~/.local/share/kio/servicemenus`
4. `chmod +x ~/Scripts/ffmpegconvert.sh`

## Use

Right-click file in Dolphin -> Choose format. Can convert video to mp3 as a bonus. Also has a DaVinci Resolve preset, remux mode, and video to GIF.

## Formats

- Audio: MP3, AAC, OGG, WMA, FLAC, ALAC, WAV, AIFF, Opus
- Video: MP4, AVI, MOV, MKV, WMV, FLV, MPG, OGV, WebM
- Image: JPG, PNG, GIF, BMP, TIFF, WebP, EPS, TGA, ICO
