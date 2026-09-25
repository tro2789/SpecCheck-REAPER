# Spec Check for REAPER

ReaImGui script: measure the master mix against a delivery spec and show a
pass/fail scoreboard. REAPER sibling of the Premiere Spec Check panel.

## How it works

- **Check** renders the master mix (entire project, time selection, one
  region, or every region in turn) to a temp 32-bit float WAV. Your render
  settings are saved first and restored afterwards, including the project's
  modified flag. Render normalization, dither and tail are turned off for
  the measurement.
- Loudness comes from REAPER's own `CalculateNormalization` (BS.1770):
  integrated LUFS, true peak, short-term and momentary max. Everything else
  comes from one Lua pass over the samples: loudness range (EBU Tech 3342),
  sample peak, clipped samples (at or above 0 dBFS) with their times, RMS,
  stereo correlation (overall and the worst 1 s window), DC offset, noise
  floor (quietest 0.5 s window, or a region named `roomtone`), head/tail
  silence (-60 dBFS).
- A preset is only a checklist over those metrics; switching presets
  re-scores instantly. Music presets check true peak and clipping;
  integrated loudness is shown as a per-platform playback change (Spotify,
  Apple Music, YouTube, Tidal, Amazon). Spoken-word presets match the
  Premiere Spec Check (bitrate check dropped: the render is WAV).
- Clip list rows jump the edit cursor; **Add clip markers** drops one
  project marker per clip spot (undoable). **Save report...** writes a
  `.qc.txt`.
- Right-click the window to dock it or clear results.

Validated 2026-09-25 against ffmpeg `ebur128` on a 3:48 stereo track:
LUFS-I, LRA, sample peak and true peak all match to the displayed
precision. A 4-minute song takes about 4 s to render and 6 s to analyze.

## Install (this PC)

`%APPDATA%\REAPER\Scripts\SpecCheck` is a junction to this folder. Load
`Spec Check.lua` once via Actions > Show action list > New action > Load
ReaScript, then give it a toolbar button or shortcut.

Needs ReaImGui 0.9.3+ (ReaPack, ReaTeam Extensions). js_ReaScriptAPI is
optional (used for the Save report dialog).

## Dev

`dev/` holds headless helpers for the REAPER MCP (`script_run`):
`run_core.lua` (full check, stores a text report), `read_result.lua`,
`syntax.lua`, `ui_autocheck.lua`. REAPER on this PC takes media offline
while it is not the foreground app (`offlineinact=1`), so the dev scripts
run "Item: Set all media online" first; otherwise the render is silent.
