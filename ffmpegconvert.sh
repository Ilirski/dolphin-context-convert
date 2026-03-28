#!/bin/bash

# === CONFIG ===
USE_HW_ACCEL=false  # "auto", "vaapi", or "false"

# === ARGUMENT PARSING ===
# Last arg = input_format, second-to-last = output_extension
# If third-to-last is "resolve", that's the resolve flag
# Everything before that = input files

if [ $# -lt 2 ]; then
    zenity --error --text="Usage: ffmpegconvert.sh <files...> <output_ext> <format>"
    exit 1
fi

input_format="${@: -1}"
output_extension="${@: -2:1}"

resolve_flag=""
if [[ "${@: -3:1}" == "resolve" ]]; then
    resolve_flag="resolve"
    input_files=("${@:1:$#-3}")
else
    input_files=("${@:1:$#-2}")
fi

# Normalize file:// URLs to paths
normalized_files=()
for f in "${input_files[@]}"; do
    f="${f#file://}"
    f=$(python3 -c "import urllib.parse; print(urllib.parse.unquote('$f'))" 2>/dev/null || echo "$f")
    normalized_files+=("$f")
done
input_files=("${normalized_files[@]}")

# === FORMAT ARRAYS ===
alossy=("mp3" "aac" "ogg" "wma" "m4a" "opus")
alossless=("flac" "alac" "wav" "aiff")
ilossy=("jpg" "gif" "webp")
ilossless=("png" "bmp" "tiff" "eps" "ico" "tga")
superlossless=("psd")
alllossy=("${alossy[@]}" "${ilossy[@]}")
alllossless=("${alossless[@]}" "${ilossless[@]}")

# === INPUT VALIDATION ===
if ! command -v ffmpeg &>/dev/null; then
    zenity --error --text="ffmpeg is not installed or not in PATH."
    exit 1
fi

if [ ${#input_files[@]} -eq 0 ]; then
    zenity --error --text="No input files provided."
    exit 1
fi

# === HARDWARE ACCELERATION DETECTION ===
HW_ACCEL="none"
detect_hw_accel() {
    if [ "$USE_HW_ACCEL" == "false" ]; then
        HW_ACCEL="none"
        return
    fi
    if [ -e /dev/dri/renderD128 ]; then
        if ffmpeg -hide_banner -f lavfi -i nullsrc=s=256x256:d=1 -c:v h264_vaapi -f null /dev/null 2>/dev/null; then
            HW_ACCEL="vaapi"
            return
        fi
    fi
    HW_ACCEL="none"
}
detect_hw_accel

# === HELPER: Check if output is audio format ===
is_audio_output() {
    [[ " ${alossy[@]} " =~ " ${output_extension} " ]] || [[ " ${alossless[@]} " =~ " ${output_extension} " ]]
}

# === HELPER: Build video codec args ===
build_video_args() {
    case "$output_extension" in
        mp4)
            ffmpeg_args=(
                -c:v libx264 -crf 23 -preset medium -movflags +faststart
                -c:a aac -b:a 192k
            )
            ;;
        avi)
            ffmpeg_args=(
                -c:v mpeg4 -q:v 2
                -c:a mp2 -b:a 192k
            )
            ;;
        mov)
            ffmpeg_args=(
                -c:v libx264 -crf 23 -preset medium -movflags +faststart
                -c:a aac -b:a 192k
            )
            ;;
        mkv)
            ffmpeg_args=(
                -c:v libx265 -crf 28 -preset fast
                -c:a aac -b:a 192k
            )
            ;;
        wmv)
            ffmpeg_args=(
                -c:v wmv2 -q:v 2
                -c:a wmav2 -b:a 192k
            )
            ;;
        flv)
            ffmpeg_args=(
                -c:v flv -q:v 2
                -c:a libmp3lame -b:a 192k
            )
            ;;
        mpg)
            ffmpeg_args=(
                -c:v mpeg2video -q:v 2
                -c:a mp2 -b:a 192k
            )
            ;;
        ogv)
            ffmpeg_args=(
                -c:v libtheora -q:v 6
                -c:a libvorbis -q:a 5
            )
            ;;
        webm)
            ffmpeg_args=(
                -c:v libvpx-vp9 -crf 30 -b:v 0 -row-mt 1 -threads 4
                -c:a libopus -b:a 192k
            )
            ;;
        *)
            ffmpeg_args=(
                -c:v libx264 -crf 23
                -c:a aac -b:a 192k
            )
            ;;
    esac

    # Apply VAAPI hardware acceleration if available
    if [[ "$HW_ACCEL" == "vaapi" ]]; then
        case "$output_extension" in
            mp4|mov)
                ffmpeg_args=(
                    -vaapi_device /dev/dri/renderD128
                    -c:v h264_vaapi -crf 23
                    -c:a aac -b:a 192k
                )
                ;;
            mkv)
                ffmpeg_args=(
                    -vaapi_device /dev/dri/renderD128
                    -c:v hevc_vaapi -crf 28
                    -c:a aac -b:a 192k
                )
                ;;
        esac
    fi
}

# === HELPER: Build audio codec args ===
build_audio_args() {
    case "$output_extension" in
        mp3)
            ffmpeg_args=(-codec:a libmp3lame -b:a 320k)
            ;;
        aac|m4a)
            ffmpeg_args=(-codec:a aac -q:a 0)
            ;;
        ogg)
            ffmpeg_args=(-codec:a libvorbis -q:a 10)
            ;;
        wma)
            ffmpeg_args=(-codec:a wmav2 -b:a 192k)
            ;;
        opus)
            ffmpeg_args=(-codec:a libopus -b:a 256k)
            ;;
        flac)
            ffmpeg_args=(-c:a flac)
            ;;
        wav|aiff)
            ffmpeg_args=(-c:a pcm_s16le)
            ;;
        alac)
            ffmpeg_args=(-acodec alac)
            ;;
        *)
            ffmpeg_args=(-q:a 0)
            ;;
    esac
}

# === CLEANUP TRAP ===
PIPE=""
FFMPEG_PID=""
cleanup() {
    [ -n "$FFMPEG_PID" ] && kill "$FFMPEG_PID" 2>/dev/null
    [ -n "$PIPE" ] && rm -f "$PIPE"
}
trap cleanup EXIT

# === MAIN LOOP ===
total_files=${#input_files[@]}
current=0
failed=0

for input_file in "${input_files[@]}"; do
    current=$((current + 1))

    # --- Per-file validation ---
    if [ ! -f "$input_file" ]; then
        zenity --error --text="File not found:\n$input_file"
        failed=$((failed + 1))
        continue
    fi
    if [ ! -r "$input_file" ]; then
        zenity --error --text="Cannot read file:\n$input_file\nPermission denied."
        failed=$((failed + 1))
        continue
    fi

    # --- Derive filenames ---
    filename=$(basename -- "$input_file")
    filename_noext="${filename%.*}"
    input_extension="${filename##*.}"

    # --- Set output file path ---
    if [ "$output_extension" == "alac" ]; then
        output_file="${filename_noext}.m4a"
    elif [[ "$resolve_flag" == "resolve" ]]; then
        output_file="${filename_noext}_resolve.mp4"
    else
        output_file="${filename_noext}.${output_extension}"
    fi

    # --- Overwrite handling ---
    if [ -e "$output_file" ]; then
        if [ "$total_files" -gt 1 ]; then
            zenity --question --text="File already exists:\n$output_file\n\nOverwrite?" \
                --ok-label="Overwrite" --cancel-label="Skip"
        else
            zenity --question --text="File already exists:\n$output_file\n\nOverwrite?" \
                --ok-label="Overwrite" --cancel-label="Cancel"
        fi
        if [ $? -ne 0 ]; then
            failed=$((failed + 1))
            continue
        fi
        rm -f "$output_file"
    fi

    # --- Lossy/lossless warnings ---
    if [[ " ${alllossy[@]} " =~ " ${input_extension} " ]] && [[ " ${alllossless[@]} " =~ " ${output_extension} " ]]; then
        zenity --question --text="WARNING: Converting from lossy to lossless.\nQuality will NOT improve.\nContinue?" \
            --ok-label="Continue" --cancel-label="Cancel" --default-cancel --icon-name="warning"
        if [ $? -ne 0 ]; then exit 1; fi
    fi

    if [[ " ${alllossless[@]} " =~ " ${input_extension} " ]] && [[ " ${alllossy[@]} " =~ " ${output_extension} " ]]; then
        zenity --question --text="WARNING: Converting from lossless to lossy.\nQuality will NOT be preserved.\nContinue?" \
            --ok-label="Continue" --cancel-label="Cancel" --default-cancel --icon-name="warning"
        if [ $? -ne 0 ]; then exit 1; fi
    fi

    if [[ " ${superlossless[@]} " =~ " ${input_extension} " ]]; then
        zenity --question --text="WARNING: This file contains extra data (layers, etc.) that will be lost.\nContinue?" \
            --ok-label="Continue" --cancel-label="Cancel" --default-cancel --icon-name="warning"
        if [ $? -ne 0 ]; then exit 1; fi
    fi

    # --- Build FFmpeg command ---
    ffmpeg_args=()
    is_gif=false
    use_imagemagick=false

    if [[ "$resolve_flag" == "resolve" ]]; then
        # DaVinci Resolve preset
        ffmpeg_args=(
            -map 0 -map_metadata 0
            -c:v libsvtav1 -crf 30 -preset 6
            -c:a libopus -b:a 192k
        )
        needs_progress=true
    elif [[ "$input_format" == "remux" ]]; then
        # Remux: just copy streams to new container
        ffmpeg_args=(-map 0 -map_metadata 0 -c copy)
        needs_progress=false
    elif [[ "$input_format" == "audio" ]] || is_audio_output; then
        # Audio conversion
        build_audio_args
        ffmpeg_args=(-map 0:a -map_metadata 0 "${ffmpeg_args[@]}")
        # For short audio files, progress is less important
        needs_progress=true
    elif [[ "$output_extension" == "gif" ]]; then
        # GIF conversion via ffmpeg + gifski pipeline
        is_gif=true
        needs_progress=true
    elif [[ "$input_format" == "video" ]]; then
        # Video conversion with per-format codec settings
        build_video_args
        ffmpeg_args=(-map 0 -map_metadata 0 "${ffmpeg_args[@]}")
        needs_progress=true
    elif [[ "$input_format" == "image" ]]; then
        # Image conversion: prefer ImageMagick, fall back to ffmpeg
        if command -v magick &>/dev/null; then
            use_imagemagick=true
        else
            use_imagemagick=false
            ffmpeg_args=(-map_metadata 0 -q:v 1)
        fi
        needs_progress=false
    else
        # Unknown format, generic fallback
        ffmpeg_args=(-map_metadata 0 -q:v 1)
        needs_progress=false
    fi

    ffmpeg_cmd=(ffmpeg -i "$input_file" "${ffmpeg_args[@]}" "$output_file")

    # --- Execute ImageMagick pipeline (images) ---
    if [[ "$input_format" == "image" ]] && $use_imagemagick; then
        img_args=()
        case "$output_extension" in
            jpg) img_args=(-quality 95) ;;
            png) img_args=(-quality 95) ;;
            tiff) img_args=(-compress lzw) ;;
            webp) img_args=(-quality 95) ;;
            eps) img_args=(-quality 95) ;;
            ico) img_args=(-resize 256x256) ;;
        esac
        error_output=$(magick "$input_file" "${img_args[@]}" "$output_file" 2>&1)
        if [ $? -ne 0 ]; then
            zenity --error --text="An error occurred during conversion of:\n$filename\n\n$error_output"
            failed=$((failed + 1))
            continue
        fi

    # --- Execute GIF pipeline (ffmpeg → gifski) ---
    elif $is_gif; then
        if ! command -v gifski &>/dev/null; then
            zenity --error --text="gifski is not installed.\nInstall it to convert to GIF."
            failed=$((failed + 1))
            continue
        fi

        temp_file=$(mktemp /tmp/ffmpeg_gif_temp_XXXXXX.mp4)

        # Step 1: ffmpeg creates downscaled temp MP4
        title="Converting ($current/$total_files)"
        [ "$total_files" -eq 1 ] && title="Converting to GIF"

        ffmpeg -i "$input_file" -vf "scale=720:-2,fps=15" -an -c:v libx264 -crf 18 -map_metadata 0 "$temp_file" &
        FFMPEG_PID=$!

        (
            while kill -0 "$FFMPEG_PID" 2>/dev/null; do
                echo "# Step 1/2: Preparing\n$filename"
                sleep 1
            done
        ) | zenity --progress --title="$title" \
            --text="Preparing $filename for GIF conversion..." --auto-close

        if [ $? -eq 1 ]; then
            kill "$FFMPEG_PID" 2>/dev/null
            wait "$FFMPEG_PID" 2>/dev/null
            rm -f "$temp_file" "$output_file"
            zenity --error --text="Conversion canceled."
            [ "$total_files" -eq 1 ] && exit 1
            failed=$((failed + 1))
            FFMPEG_PID=""
            continue
        fi

        wait "$FFMPEG_PID" 2>/dev/null
        ffmpeg_exit=$?
        FFMPEG_PID=""

        if [ "$ffmpeg_exit" -ne 0 ]; then
            zenity --error --text="Failed to prepare GIF from:\n$filename"
            rm -f "$temp_file"
            failed=$((failed + 1))
            continue
        fi

        # Step 2: gifski converts temp MP4 to GIF
        (
            gifski -o "$output_file" -W 720 -Q 90 -r 15 "$temp_file"
            gifski_exit=$?
            rm -f "$temp_file"
            exit $gifski_exit
        ) &

        (
            while kill -0 $! 2>/dev/null; do
                echo "# Step 2/2: Generating GIF\n$filename"
                sleep 1
            done
        ) | zenity --progress --title="$title" \
            --text="Generating GIF from $filename..." --auto-close

        if [ $? -eq 1 ]; then
            # gifski likely finished already, just check
            :
        fi

        if [ ! -f "$output_file" ]; then
            zenity --error --text="Failed to generate GIF from:\n$filename"
            failed=$((failed + 1))
            continue
        fi

    # --- Execute with progress ---
    elif $needs_progress; then
        # Get duration for progress calculation
        duration=$(ffprobe -v error -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null)

        # Duration in centiseconds (integer) for bash math
        if [ -n "$duration" ]; then
            duration_cs=$(echo "$duration" | awk '{printf "%d", $1 * 100}')
        else
            duration_cs=0
        fi

        if [ "$duration_cs" -gt 0 ]; then
            # Real progress mode using named pipe
            PIPE=$(mktemp -u /tmp/ffmpeg_progress_XXXXXX)
            mkfifo "$PIPE"

            title="Converting ($current/$total_files)"
            if [ "$total_files" -eq 1 ]; then
                title="Converting Media"
            fi

            "${ffmpeg_cmd[@]}" -stats 2>"$PIPE" &
            FFMPEG_PID=$!

            (
                while IFS= read -r line; do
                    if [[ "$line" =~ time=([0-9]+):([0-9]+):([0-9]+\.?[0-9]*) ]]; then
                        h="${BASH_REMATCH[1]}"
                        m="${BASH_REMATCH[2]}"
                        s="${BASH_REMATCH[3]}"
                        # Convert to centiseconds
                        s_int="${s%%.*}"
                        [ -z "$s_int" ] && s_int=0
                        current_cs=$(( 10#$h * 360000 + 10#$m * 6000 + 10#$s_int * 100 ))
                        if [ "$duration_cs" -gt 0 ]; then
                            pct=$(( current_cs * 100 / duration_cs ))
                            [ "$pct" -gt 99 ] && pct=99
                            echo "$pct"
                            echo "# Converting\n$filename\nto\n$output_file\n$pct%"
                        fi
                    fi
                done < "$PIPE"
                echo "100"
            ) | zenity --progress --title="$title" \
                --text="Converting\n$filename\nto\n$output_file" \
                --percentage=0 --auto-close

            zenity_exit=$?

            # Cleanup pipe
            rm -f "$PIPE"
            PIPE=""

            # Check if cancelled
            if [ "$zenity_exit" -eq 1 ]; then
                kill "$FFMPEG_PID" 2>/dev/null
                wait "$FFMPEG_PID" 2>/dev/null
                rm -f "$output_file"
                if [ "$total_files" -gt 1 ]; then
                    zenity --question --text="Cancel remaining conversions?" \
                        --ok-label="Cancel All" --cancel-label="Skip This File"
                    if [ $? -eq 0 ]; then
                        zenity --error --text="Conversion canceled."
                        exit 1
                    fi
                else
                    zenity --error --text="Conversion canceled."
                    exit 1
                fi
                failed=$((failed + 1))
                FFMPEG_PID=""
                continue
            fi

            # Check exit status
            wait "$FFMPEG_PID" 2>/dev/null
            exit_status=$?
            FFMPEG_PID=""
            if [ "$exit_status" -ne 0 ]; then
                zenity --error --text="An error occurred during conversion of:\n$filename"
                failed=$((failed + 1))
                continue
            fi
        else
            # No duration available, fall back to spinner
            "${ffmpeg_cmd[@]}" &
            FFMPEG_PID=$!

            title="Converting ($current/$total_files)"
            [ "$total_files" -eq 1 ] && title="Converting Media"

            (
                while kill -0 "$FFMPEG_PID" 2>/dev/null; do
                    echo "# Converting\n$filename\nto\n$output_file"
                    sleep 1
                done
            ) | zenity --progress --title="$title" \
                --text="Converting\n$filename\nto\n$output_file" --auto-close

            if [ $? -eq 1 ]; then
                kill "$FFMPEG_PID" 2>/dev/null
                wait "$FFMPEG_PID" 2>/dev/null
                rm -f "$output_file"
                if [ "$total_files" -gt 1 ]; then
                    zenity --question --text="Cancel remaining conversions?" \
                        --ok-label="Cancel All" --cancel-label="Skip This File"
                    if [ $? -eq 0 ]; then
                        zenity --error --text="Conversion canceled."
                        exit 1
                    fi
                else
                    zenity --error --text="Conversion canceled."
                    exit 1
                fi
                failed=$((failed + 1))
                FFMPEG_PID=""
                continue
            fi

            wait "$FFMPEG_PID" 2>/dev/null
            exit_status=$?
            FFMPEG_PID=""
            if [ "$exit_status" -ne 0 ]; then
                zenity --error --text="An error occurred during conversion of:\n$filename"
                failed=$((failed + 1))
                continue
            fi
        fi
    else
        # Image/remux: run directly (too fast for progress)
        error_output=$("${ffmpeg_cmd[@]}" 2>&1)
        if [ $? -ne 0 ]; then
            zenity --error --text="An error occurred during conversion of:\n$filename\n\n$error_output"
            failed=$((failed + 1))
            continue
        fi
    fi
done

# === SUMMARY ===
if [ "$total_files" -gt 1 ]; then
    success=$((total_files - failed))
    if [ "$failed" -eq 0 ]; then
        zenity --info --text="Conversion complete.\nAll $total_files files converted successfully."
    else
        zenity --info --text="Conversion complete.\n$success of $total_files files converted.\n$failed skipped or failed."
    fi
fi
