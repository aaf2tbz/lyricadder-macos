# Third-party notices

## lyricAdder (original)

This project is a native port of [lyricAdder](https://github.com/DarkAngel2096/lyricAdder) by DarkAngel2096,
released under the ISC license (see `LICENSE`). No original JavaScript ships in this repository;
`scripts/parity_original.js` only loads it from a copy you extract yourself, to compare results.

## stb_vorbis 1.20 — `Sources/CStbVorbis/stb_vorbis_impl.inc`

Ogg Vorbis decoder by Sean Barrett and contributors, https://github.com/nothings/stb.
Dual-licensed: public domain (Unlicense) or MIT, at your choice. The full license text is at the end of
`stb_vorbis_impl.inc`.

This copy comes from [FAudio](https://github.com/FNA-XNA/FAudio) (zlib license), which made small
changes: an exported-function macro, alloca hooks, and a disabled stdio include block.
`Sources/CStbVorbis/stb_vorbis.c` defines those hooks back to the standard C library so the file
builds on its own.
