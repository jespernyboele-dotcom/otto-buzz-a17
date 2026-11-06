# Measure real fps on a car screen with a phone camera

Encoder logs tell you what you *send*. Only a camera tells you what the car screen *shows*. With a phone's 120 fps
slow-motion mode and the script here, we measured that OTTO's MIB4 panel showed 99.5 % of the pictures of a 60 fps video.

## 1. Make a test video where every frame is different
A moving pattern plus a yellow block that moves 24 px to the right on every frame:
```sh
ffmpeg -f lavfi -i testsrc2=size=1920x840:rate=60 -f lavfi -i color=c=yellow:size=80x80:rate=60 -t 90 \
  -filter_complex "[0][1]overlay=x='mod(n*24\,W-w)':y=H*0.82:shortest=1" \
  -c:v libx264 -pix_fmt yuv420p -g 60 test60.mp4
```
Use your screen's size. Self-test the analyser on the file itself first:
`python3 camera_analyze.py test60.mp4` → "panel picture changes … 60.0 distinct pictures/s".

## 2. Film the car screen
- Play the video on the device that projects to the car (full screen).
- Phone on a stand, **slow motion (120 fps or more)**, the whole picture area in view, no reflections on the screen.
- Film at least 20–30 s of the video. Do it parked.

## 3. Analyse
```sh
python3 camera_analyze.py PXL_xxx.mp4 --cam-fps 120 --crop x:y:w:h --start 5 --dur 20
```
- `--cam-fps`: the real capture rate. Slow-motion files often say 30 fps in their header (Android stores the real rate in
  `com.android.capture.fps`).
- `--crop x:y:w:h`: the screen's picture area in the camera frame, in source pixels (take a still and read it off).
- `--start/--dur`: a stretch where the block is visible all the time.

## 4. Read the result
- **Index method** (first line): the script turns every block position into a source-frame number. "distinct pictures shown"
  and "never shown" give the share of source pictures the screen showed: ours was 1162 shown, 6 never shown = **99.5 %**.
  This number holds even when the camera catches the panel halfway through a change.
- "panel picture changes … /s": simpler count of position changes. Good for the self-test.
- The script skips frames where the block is partly hidden, and the static yellow bar of the test pattern.

## Requirements
Python 3 with numpy, ffmpeg/ffprobe on the PATH. `camera_analyze.py` is in this folder.
