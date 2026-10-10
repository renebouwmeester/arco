# Arco 0.4 — a slice per track through Roon's queue

*10 Oct 2026, René: "Laten we Arco 0.4 oppakken." Agreed: the Music app only (Spotify stays a continuous run); the next
track's title goes to Roon ahead, its artist and cover with update_track_info at the change (2a; a lookup by album id is
for later, 2b); a hidden switch while testing.*

## Why now

0.2.x tried a slice per track through Roon's queue slot (branch `queue`, 7 Oct) and gave it up (2d563b5): Roon opens the
queued item about eleven seconds before the end of what plays and goes on by itself (OnToNext) — but Arco only learned the
next track when the Music app began it, and Roon plays five to seven seconds behind. "Reading ahead isn't possible."

It is now. The measurement of 10 Oct (Gaylord, macOS 27, the Music app itself — a meter on its log beside an album, a
shuffled playlist, a skip, autoplay and Play Next) showed that the Music app writes the next track to its log when the
current one begins, minutes ahead:

    ITMPAVItemCount INIT … (177582::177595) Goldberg Variations, BWV 988: Aria          — the item and its title
    [MPAVItem isInContiguousAlbum] Current song: contentIdentifier=… Next song: contentIdentifier=177582::177595 …
        album.identifiers=… storeAdamID=1694676611 …                                      — which item is next, its album
    🎥 <ITMPAVItem …> (177582::177595) Goldberg … loadedTimeRanges 15.00 of 245.38         — its length

- an album start: the whole album's items at once; the next one and its length within three seconds;
- a natural change: the prediction held, every time, minutes ahead;
- a skip: the new next one within two seconds;
- autoplay: the autoplay items already listed before the album ends; the next one named at the start of the last track;
- shuffle: the whole playlist's items in the shuffled order of play;
- Play Next: a new next item within seconds (its id carries a plus: `177604+177691::177693`).

And the rate: a lossless "Creating AudioQueue" line that comes after "next is X" is X's (autoplay, 16:21:11: 192 kHz, a
minute ahead); none means the same rate. The guesswork of timing windows (FormatLog's `.natural` since previous+3 s) can go.

## Scenarios (as for 0.3.4: each one with the meter beside it, first on 0.3.4 where useful, then on the dev build)

1. An album start (a cold start)
2. A natural change at the same rate
3. A natural change to another rate, its line well ahead
4. The same, its line only at the change (Sir Duke, 10 Oct: 0.45 s before)
5. A skip, at the same rate and to another
6. Autoplay
7. A shuffled playlist
8. Play Next in the Music app — also after Arco queued the old next one in Roon
9. Pause, short and long, and resume
10. A seek within a track
11. A track without a length
12. Roon's own buttons: pause, next
13. Spotify: stays a run, untouched

## Design

- **FormatLog** reads the next-track lines too: `next` = (item, title, album, length?) — the length as soon as its
  `loadedTimeRanges` line comes. The rate of the next track: the lossless line after `next` was named; none — the same.
- **A slice per track** for the Music app (SliceStore gets a track mode; Spotify keeps runs). A slice is a WAV declared at
  the track's own length and rate, so its header is ready at once.
- **Queued ahead:** as soon as the next track is known (title, length, rate), its slice goes into Roon's queue slot — minutes
  before Roon opens it. Roon's reader for it waits for the first bytes (they come when the Music app reaches the track,
  a few seconds before Roon does).
- **Changes before Roon opened it** (a late rate line, Play Next, a reshuffle): the queue slot is played again with the new
  slice. After Roon opened it: as today — at the change, a new slice in the play slot.
- **The cut:** the tap writes into the current slice until it is full, then into the next one. A slice shorter or longer
  than the music by a few milliseconds shifts the cut by that much (the Music app's change notification checks it).
- **A change of rate:** the next slice is declared at its own rate; the device follows at the change (setClock, as now);
  what the Music app plays of the new track at the old rate before its pause does not go in (restartTrackAtNewRate).
- **Skips** stay a new slice in the play slot; the next one is queued again right after.
- **Fallback:** whenever the queue can't be trusted (no next line, a mismatch at the change, the log unavailable), the
  0.3.4 run takes over for that stretch.
- **Switch:** `defaults write nl.renebouwmeester.arco QueueMode -bool true` (dev build, off by default) — remove or keep
  as an escape hatch at release.

## Steps

1. FormatLog: the next track, in Arco's log only (no behaviour) — check it in the dev build.
2. SliceStore: track mode (declared length, the cut, the overflow into the next slice).
3. Bridge: queue the next slice, re-queue on changes, the fallback.
4. The scenarios, with the meter; then the default and the release notes.

## Outcome (10 Oct, ~17:00) — the queue stays a run

Tried on the dev build (66d4dbb, QueueMode on): the first slice of a session, declared at its track's length (Bað, 192 kHz,
174.7 MB), stalled in Roon two seconds in — Roon's file cache took it for a file to download ("FTMSI-B got length …
174,7 MBytes", then "[zoneplayer] stopped"), the KEF waited, Roon's time crept on without sound. A run, declared at
gigabytes, Roon follows as a stream. And Basso's Roon zone showed on 8 Oct what a queued slice needs: "poor connection
kbps:1277 (min:3072) → couldn't queue URL" — Roon wants a queued track faster than real time, which music being played
can never be. Knowing the next track ahead doesn't change Roon's rule. So the runs stay; the next-track lines go into the
run's own guesswork instead (branch `licht`: the rate of the next track named, a late line that is the next track's never
corrects the current one, the length, a natural change recognised by the item). This branch stays as the record.
