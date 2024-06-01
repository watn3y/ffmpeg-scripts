#!/usr/bin/env bash


################### VARIABLES ###################

inputDir="/tank/stuff/clip_todo"
outputDir="/tank/drive/Clips/$(date +%F)"

telegramChatID=
telegramBotToken=


################### VARIABLES ###################



function encodeAV1 {
    local input=$1
    local output=$2

    docker run --rm --group-add 105 --group-add 5555 \
        --device=/dev/dri:/dev/dri -v "$(dirname "$input"):/in:ro" -v "$(dirname "$output"):/out:rw" linuxserver/ffmpeg:latest \
        -y -hide_banner -loglevel error \
        -hwaccel qsv -hwaccel_output_format qsv -init_hw_device qsv=hw -filter_hw_device hw -extra_hw_frames 100 \
        -i "/in/$(basename "$input")" \
        -vf hwupload=extra_hw_frames=100,format=qsv \
        -c:v av1_qsv -preset veryslow -low_power 1 -adaptive_i 1 -adaptive_b 1 -extbrc 1 -global_quality:v 27 -look_ahead_depth 100 \
        -c:a libopus -b:a 128K \
        "/out/$(basename "$input")"
}

function encodeJPG {
    local input=$1
    local output=$2

    docker run --rm --group-add 105 --group-add 5555 \
        -v "$(dirname "$input"):/in:ro" -v "$(dirname "$output"):/out:rw" linuxserver/ffmpeg:latest \
        -y -hide_banner -loglevel error \
        -i "/in/$(basename "$input")" \
        -frames:v 1 -c:v png -filter:v scale=\'if\(gt\(a,320/500\),320,-1\)\':\'if\(gt\(a,320/500\),-1,500\)\' \
        "/out/$(basename "$output" jpg)png"

    docker run --rm --group-add 105 --group-add 5555 \
        -v "$(dirname "$output"):/inout:rw" dpokidov/imagemagick:latest \
        "/inout/$(basename "$output" jpg)png" \
        -strip -interlace Plane -quality 85% \
        "/inout/$(basename "$output")"

    rm "$(dirname "$output")/$(basename "$output" jpg)png"
}

function syncRemote {
    local input=$1
    local output=$2

    rclone --config ./rclone.conf sync "$input" "$output" --exclude '.*/**'
}

function sendVideo {
    local video=$1
    local thumbnail=$2
    local caption=$3

    curl --fail --silent --show-error -X POST \
        "https://api.telegram.org/bot$telegramBotToken/sendVideo" \
        -F video=@"$video" \
        -F thumbnail=@"$thumbnail" \
        -F "chat_id=$telegramChatID" \
        -F "width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 "$video")" \
        -F "height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 "$video")" \
        -F "duration=$(ffprobe -v error -select_streams v:0 -show_entries stream=duration -of default=nw=1:nk=1 "$video" | xargs printf '%0.0f\n')" \
        -F "supports_streaming=true" \
        -F "caption=$caption"
}


function sendPhoto {
    local photo=$1
    local caption=$2

    curl --fail --silent --show-error -X POST \
        "https://api.telegram.org/bot$telegramBotToken/sendPhoto" \
        -F photo=@"$photo" \
        -F "chat_id=$telegramChatID" \
        -F "caption=$caption"
}

function runChmod {
    chmod -R 775 "$@"
    chown -R melchior:melchior "$@"
}


function checkRoot {
    if [ "$EUID" -ne 0 ]
    then echo "Please run as root"
        exit 1
    fi
}



function main {
    mkdir -p "$outputDir/.high"

    runChmod "$outputDir" "$inputDir"

    find "$inputDir" -type f -name '*.mp4' | while read filepath; do
        local mp4out="$outputDir"/$(basename "$filepath")
        local jpgout="$outputDir"/$(basename "$filepath" mp4)jpg

        encodeAV1 "$filepath" "$mp4out" &
        local waitAV1=$!
        encodeJPG "$filepath" "$jpgout" &
        local waitJPG=$!

        wait $waitJPG $waitAV1

        if [ $(du -sb "$mp4out" | cut -f1) -le 52428585 ]
        then
            sendVideo "$mp4out" "$jpgout" "Link for iOS: https://clips.watn3y.de/$(echo "$(dirname "$mp4out" | sed 's,^\(.*/\)\?\([^/]*\),\2,')/$(basename "$mp4out")" | jq '@uri' -jRr )" &
        else
            sendPhoto "$jpgout" "Link for iOS: https://clips.watn3y.de/$(echo "$(dirname "$mp4out" | sed 's,^\(.*/\)\?\([^/]*\),\2,')/$(basename "$mp4out")" | jq '@uri' -jRr )" &
        fi
        #local waitCURL=$!

        mv "$filepath" "$outputDir/.high"

    done
    syncRemote "$outputDir" "balthasar:/mnt/clips/$(basename "$outputDir")" &
    wait

    runChmod "$outputDir" "$inputDir"
    wait
}

main
printf "\n"
