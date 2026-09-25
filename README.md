# Spec Check for REAPER

A REAPER script that measures your master mix against a delivery spec and
shows a pass/fail scoreboard: loudness, true peak, clipping, loudness
range, stereo correlation, noise floor and silence. REAPER sibling of the
[Spec Check panel for Premiere Pro](https://github.com/tro2789/SpecCheck).

## Install (ReaPack)

1. Install [ReaPack](https://reapack.com) if you don't have it, and restart
   REAPER.
2. **Extensions > ReaPack > Browse packages**, search **ReaImGui**, install
   it, and restart REAPER.
3. **Extensions > ReaPack > Import repositories...**, paste this URL, and
   click OK:

   ```
   https://raw.githubusercontent.com/tro2789/SpecCheck-REAPER/main/index.xml
   ```
4. **Extensions > ReaPack > Browse packages**, search **Spec Check**,
   right-click it > Install, then Apply.
5. Open the action list (**?**), search **Spec Check**, and run it. Add it
   to a toolbar or give it a shortcut from there.

ReaPack offers updates when new versions come out. Windows and macOS.
js_ReaScriptAPI is optional (used for the Save report file dialog).

## How it works

- **Check** renders the master mix (entire project, time selection, one
  region, or every region in turn) to a temp 32-bit float WAV. Your render
  settings are saved first and restored afterwards, including the project's
  modified flag. Render normalization, dither and tail are turned off for
  the measurement, so your render dialog settings never change the result.
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
  Apple Music, YouTube, Tidal, Amazon). Spoken-word presets cover ACX,
  Audible Originals, Apple Podcasts, Spotify, EBU R128 and YouTube. The
  **Edit...** button makes custom presets.
- Clip list rows jump the edit cursor; **Add clip markers** drops one
  project marker per clip spot (undoable). **Save report...** writes a
  `.qc.txt`.
- Right-click the window to dock it or clear results.
- The window takes its colors from the active REAPER theme and follows
  theme switches.

Measurements were checked against ffmpeg `ebur128` on a stereo song:
integrated loudness, loudness range, sample peak and true peak match to
the displayed precision. A 4-minute song takes about 10 s to check.

## Repo and releases

- Source of truth is a private Gitea; this GitHub repo is a push mirror.
  Don't push to GitHub directly.
- The version lives in two places, bump both together: the `@version`
  header (and `@changelog`) in `Spec Check.lua`, and `M.VERSION` in
  `speccheck_core.lua`.
- Release: commit, tag `vX.Y.Z`, run `python tools/make_index.py`, commit
  `index.xml`, push with tags. ReaPack reads `index.xml` from `main`; each
  version's files are pinned to its tag with SHA-256 hashes.

## Dev

`dev/` holds headless helpers driven through a REAPER MCP bridge
(`script_run`): `run_core.lua` (full check, stores a text report),
`read_result.lua`, `syntax.lua`, `ui_autocheck.lua`, `theme_probe.lua`.
If REAPER is set to take media offline while in the background, renders
started from outside are silent; the dev scripts run "Item: Set all media
online" first for that reason. They are marked `@noindex` and are not part
of the ReaPack package.

## License

MIT, see [LICENSE](LICENSE).
