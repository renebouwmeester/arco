# A fixed 96 kHz per zone (12 Oct 2026, released in 0.3.7)

René: an optional fixed 96 kHz for a zone, for a continuous stream as with Spotify (no change of rate, so no run frozen and
started again, no DAC locking on to a new rate). Built on this branch (0a7d520): the Arco device fixed at 96 kHz for the Music
app, the clock not followed, and set back when something else changed it.

**What happened on the KEF:** a 44.1 kHz track on the fixed device, and every ~10.5 s the Music app was paused and played
again — audible gaps. The device itself never changed rate.

**Why — not the Music app:** it was Basso's own motor on the same Mac (Continuo, with "This Mac" as maestro). Its clock follower
saw a 44.1 track on a 96 kHz device, paused the Music app, asked to set the rate (which it rightly leaves to Arco), and played
again — every ten seconds. The Music app never sets a device's rate itself (measured 9 Oct, and again 12 Oct: the MacBook's
speakers that went back from 48 to 44.1 were Basso too). Fixed in Basso (045ddbc8): with Arco as the output, the follower
doesn't touch the Music app.

**Retest after the fix (18:36–18:56):** 96, 44.1 and 192 kHz tracks one after another in one run — the changes to the
next track to the tenth of a second, the Music app resampling to the fixed 96 kHz, Roon 7 s behind as usual, no pauses. A
skip or a new album still starts a new run (Roon sets up the stream again, 3–4 s), as with Spotify and Solo: so a skip is
heard at once instead of after Roon's lag (René: keep it so). Released in 0.3.7.
