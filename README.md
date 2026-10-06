# Arco

Play Apple Music and Spotify on your Roon zones, from a small app in your Mac's menu bar.

Arco takes what the Music app (or the Spotify app) plays on your Mac and hands it to Roon as a live source, with the
title, artist, album and cover of each track. Roon does the rest: your zones, your DSP, your endpoints — including the
ones that only speak RAAT.

> **Status:** early development. Not ready for use yet.

## How it works

- **Arco** — a virtual audio output. Music plays to it; nothing leaves your Mac until Arco sends it on.
- **The bridge** — Arco reads that output back (bit for bit what Music produced), cuts it per track and serves it to
  your Roon Core over your local network.
- **The extension** — Arco registers with your Roon Core as an extension and uses Roon's audio input API to play the
  stream on the zone you pick in the menu. Roon shows what is playing, and its own transport buttons work.

Each track arrives in Roon at its own sample rate: a 44.1 kHz track plays at 44.1, the next 96 kHz track at 96.

## Requirements

- macOS 14 or later
- A Roon Core on the same network (Roon 2.x)
- Apple Music and/or Spotify on the Mac

## A note on quality

Arco is lossless from the Music app into Roon. It does not promise bit-perfect playback of Apple Music's files: the
Music app itself does not always deliver them bit-exact.

## License

Apache License 2.0 — see [LICENSE](LICENSE).

Arco is an independent project. It is not affiliated with or endorsed by Roon Labs, Apple or Spotify. Roon, Apple
Music and Spotify are trademarks of their respective owners.
