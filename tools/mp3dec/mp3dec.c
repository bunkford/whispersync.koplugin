/*
 * mp3dec -- decode an MP3 file to raw 16-bit little-endian PCM.
 *
 * Built for the Read Aloud KOReader plugin: Kindle firmware ships no MP3
 * decoder, and the Edge voice service only speaks MP3, so this turns each
 * utterance into the raw PCM that GStreamer's mixersink can play. Static,
 * so it needs nothing from the device's libc or GStreamer.
 *
 *   mp3dec in.mp3 out.pcm      writes PCM, prints "rate=R channels=C samples=N" on stdout
 *   mp3dec --probe             prints "mp3dec ok" and exits 0 (is this binary runnable here?)
 *
 * Decoder: minimp3 by lieff (CC0 / public domain), single header.
 */
#define MINIMP3_IMPLEMENTATION
#define MINIMP3_ONLY_MP3
#define MINIMP3_NO_SIMD
#include "minimp3.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "--probe") == 0) {
        printf("mp3dec ok\n");
        return 0;
    }
    if (argc != 3) {
        fprintf(stderr, "usage: mp3dec in.mp3 out.pcm | mp3dec --probe\n");
        return 1;
    }
    FILE *in = fopen(argv[1], "rb");
    if (!in) { perror(argv[1]); return 2; }
    fseek(in, 0, SEEK_END);
    long size = ftell(in);
    fseek(in, 0, SEEK_SET);
    if (size <= 0 || size > 64L * 1024 * 1024) { fprintf(stderr, "mp3dec: bad input size\n"); fclose(in); return 2; }
    unsigned char *buf = malloc((size_t)size);
    if (!buf || fread(buf, 1, (size_t)size, in) != (size_t)size) { fprintf(stderr, "mp3dec: read failed\n"); fclose(in); return 2; }
    fclose(in);

    FILE *out = fopen(argv[2], "wb");
    if (!out) { perror(argv[2]); free(buf); return 2; }

    static mp3dec_t dec;
    mp3dec_init(&dec);
    mp3dec_frame_info_t info;
    short pcm[MINIMP3_MAX_SAMPLES_PER_FRAME];
    long pos = 0, total = 0;
    int rate = 0, channels = 0;
    while (pos < size) {
        int samples = mp3dec_decode_frame(&dec, buf + pos, (int)(size - pos), pcm, &info);
        if (info.frame_bytes <= 0) break;       /* nothing decodable left */
        pos += info.frame_bytes;
        if (samples > 0) {
            if (!rate) { rate = info.hz; channels = info.channels; }
            /* little-endian on every target we build for */
            fwrite(pcm, sizeof(short), (size_t)samples * (size_t)info.channels, out);
            total += samples;
        }
    }
    fclose(out);
    free(buf);
    if (total == 0) { fprintf(stderr, "mp3dec: no audio frames\n"); return 3; }
    printf("rate=%d channels=%d samples=%ld\n", rate, channels, total);
    return 0;
}
