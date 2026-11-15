// Standalone build of FAudio's copy of stb_vorbis: restores the CRT includes and alloca hooks FAudio replaced.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <math.h>
#include <alloca.h>
#include <limits.h>

#define FAUDIOAPI static
#define FAudio_alloca(size) alloca(size)
#define FAudio_dealloca(p) ((void)(p))

#include "stb_vorbis_impl.inc"

#include "include/CStbVorbis.h"

struct lav_vorbis { stb_vorbis *v; };

lav_vorbis *lav_vorbis_open_memory(const unsigned char *data, int length, int *error) {
    int err = 0;
    stb_vorbis *v = stb_vorbis_open_memory(data, length, &err, NULL);
    if (error) *error = err;
    if (!v) return NULL;
    lav_vorbis *w = (lav_vorbis *)malloc(sizeof(lav_vorbis));
    w->v = v;
    return w;
}

void lav_vorbis_close(lav_vorbis *w) {
    if (!w) return;
    stb_vorbis_close(w->v);
    free(w);
}

int lav_vorbis_channels(lav_vorbis *w) { return stb_vorbis_get_info(w->v).channels; }
unsigned int lav_vorbis_sample_rate(lav_vorbis *w) { return stb_vorbis_get_info(w->v).sample_rate; }
unsigned int lav_vorbis_length_samples(lav_vorbis *w) { return stb_vorbis_stream_length_in_samples(w->v); }

int lav_vorbis_read_planar(lav_vorbis *w, int channels, float **buffers, int frames) {
    return stb_vorbis_get_samples_float(w->v, channels, buffers, frames);
}
