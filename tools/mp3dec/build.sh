#!/bin/sh
# Build readaloud.koplugin/bin/mp3dec-{armhf,armel}: a static minimp3-based
# MP3 -> raw PCM decoder for Kindle (hard-float for firmware >= 5.16.3 and
# Scribe/PW5/Colorsoft; soft-float for older PW2-PW4 firmware). Needs
# gcc-arm-linux-gnueabihf and gcc-arm-linux-gnueabi (Debian/Ubuntu packages).
set -eu
cd "$(dirname "$0")"
OUT=../../readaloud.koplugin/bin
mkdir -p "$OUT"
arm-linux-gnueabihf-gcc -O2 -static -march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=hard -o "$OUT/mp3dec-armhf" mp3dec.c -lm
arm-linux-gnueabi-gcc -O2 -static -march=armv7-a -mfloat-abi=soft -o "$OUT/mp3dec-armel" mp3dec.c -lm
arm-linux-gnueabihf-strip "$OUT/mp3dec-armhf"
arm-linux-gnueabi-strip "$OUT/mp3dec-armel"
ls -la "$OUT"
