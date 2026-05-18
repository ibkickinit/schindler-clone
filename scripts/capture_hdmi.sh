#!/bin/bash
# capture_hdmi.sh — grab a single 1280x720 frame from MS2109 (/dev/video3) to JPEG.
# Kills cheese if it's holding the device. Usage: ./capture_hdmi.sh /tmp/out.jpg

OUT=${1:-/tmp/hdmi_cap.jpg}

# Free /dev/video3 if held
for pid in $(lsof -t /dev/video3 2>/dev/null); do
    kill -9 $pid 2>/dev/null
done
pkill -9 -f cheese 2>/dev/null
sleep 0.5

gst-launch-1.0 -e \
    v4l2src device=/dev/video3 num-buffers=10 \
    ! image/jpeg,width=1280,height=720,framerate=60/1 \
    ! jpegdec ! videoconvert ! jpegenc \
    ! filesink location="$OUT" \
    >/dev/null 2>&1

if [ -s "$OUT" ]; then
    echo "captured: $OUT  ($(stat -c %s $OUT) bytes)"
    exit 0
else
    echo "ERROR: capture failed"
    exit 1
fi
