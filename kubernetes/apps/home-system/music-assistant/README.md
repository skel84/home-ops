# Music Assistant

Runs with host networking (mDNS discovery and AirPlay need the LAN) and as
root so AirPlay 2 PTP timing can bind UDP 319/320. As uid 1000 MA logs
"Cannot bind UDP 319" and falls back to NTP timing.

## Players

Only the speakers in use are enabled in MA: Onkyo TX-RZ30, SVS Pro
SoundBase, Terrazzo (WiiM), HomePod Bagno, HomePod Bagno In Camera,
HomePod Camera Pippi, and Camera da letto. The rest (TVs, Apple TVs,
duplicate Cast/DLNA entries) are disabled under Settings → Players, not
deleted, so they can be turned back on.

AirPlay is the default protocol. Chromecast is deliberately not used.

## Onkyo TX-RZ30 quirks (MA 2.10.9)

- **Streaming mode is pinned to "AirPlay 2 - compatibility mode"** on its
  AirPlay player (`ap6c724a120e6b`, `streaming_mode=ap2_compat`; logs show
  `raop-compat, NTP`). On Automatic (buffered, PTP) starts fail with
  `Events connect failed` or `did not acknowledge its start within 7.0s`
  (a hard-coded limit), even right after a mains power cycle, while iPhone
  AirPlay works. Grouped with HomePods (PTP), both play and resume together.
- **Resume after a short pause is a silent no-op**: `player_queues/play`
  (and the play/pause toggle) takes 5 s and leaves the queue paused, alone
  or grouped, in compat and RAOP modes. Pauses over roughly 15 s work,
  because MA closes the session and starts a fresh one. `player_queues/resume`
  works every time. HomePods are unaffected.
- **The receiver's AirPlay service can hang**: port 7000 accepts
  connections but `GET /info` never answers, and the front panel shows
  "connecting". Turning the receiver off and on (HA `media_player.tx_rz30`)
  clears it.
