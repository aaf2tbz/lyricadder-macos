// Thin public interface to the vendored stb_vorbis decoder (v1.20, public domain / MIT; see stb_vorbis_impl.inc).
#ifndef CSTBVORBIS_H
#define CSTBVORBIS_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lav_vorbis lav_vorbis;

/// Opens an in-memory Ogg Vorbis stream. Returns NULL on failure (error code in *error if non-NULL).
lav_vorbis *lav_vorbis_open_memory(const unsigned char *data, int length, int *error);
void lav_vorbis_close(lav_vorbis *v);
int lav_vorbis_channels(lav_vorbis *v);
unsigned int lav_vorbis_sample_rate(lav_vorbis *v);
unsigned int lav_vorbis_length_samples(lav_vorbis *v);
/// Decodes up to `frames` frames into planar float buffers (one per channel). Returns frames decoded, 0 at end.
int lav_vorbis_read_planar(lav_vorbis *v, int channels, float **buffers, int frames);

#ifdef __cplusplus
}
#endif
#endif
