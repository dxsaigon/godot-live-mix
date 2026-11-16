# Changelog

## 1.1.0 (2026-11-17)

UX improvements.

- Master is docked on the right, with Discard, Commit and the reference noise above it, and stays in view while the other buses scroll.
- Strips scale more smoothly with the dock's width: they narrow before the dock starts scrolling, and long names shorten with "…".
- The two Reset buttons are now one, which clears the clip lights and the loudness readings together.
- The noise mode "With game" is now called "Both".

## 1.0.0 (2026-11-15)

First release.

- Live meters for every bus of the running game, with peak hold, clip lights, a peak readout and a dB scale.
- Live faders, mute, solo, bypass and effect on/off, heard in the game straight away.
- Commit writes only what you changed into the project's bus layout; Discard puts the game back.
- Loudness meter on the game's output (ITU-R BS.1770 / EBU R128): momentary, short-term, integrated and true peak, against a target of -18 LUFS (PC / Steam), -24 LUFS (console) or your own.
- Reference pink noise at exactly the target loudness, with the game or solo, and hold-to-solo from the dock or the P key in the game.
- Active switch to pause everything at no cost to the game.
