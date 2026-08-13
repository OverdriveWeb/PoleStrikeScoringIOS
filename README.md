# PoleStrikeScoringIOS

Camera scoring for a glow-in-the-dark Strike Pole / Beersbee set. Runs on iPhone
or iPad from Swift Playgrounds — no Apple Developer account needed.

**Latest build: `PoleScore-v8.zip`** (`PoleScore-v7.zip` is the previous
release, kept for reference).

Download the zip on the device, uncompress it in the Files app, and tap
`PoleScore.swiftpm`. Full instructions, including the camera capability you must
enable before the first run, are in
[`PoleScore.swiftpm/README.md`](PoleScore.swiftpm/README.md).

## What changed in v8

- **No court setup.** The six-tap calibration is gone. The app finds the poles
  and the ground line by watching the scene, and re-reads them by itself if the
  phone moves or you zoom.
- **No colour settings.** Disc, bottle, and pole glow colours are learned while
  you play, and re-learned when they change mid-game as the glow fades.
- **Pinch to zoom**, exactly like the camera app, with double-tap to snap
  between 1× and 2×. Camera orientation is detected instead of configured, and
  the brightness threshold is chosen per frame from the frame's own histogram.
- **A cloud vision model** reads the court from a single frame and reviews each
  play after it is scored. Optional, free-tier, and rate-limited to one call per
  play; the app works fully without it.
- **Automatic mode is genuinely hands-off** — no prompts, no confirmations, no
  waiting for anyone to press anything. Ask-first and Tap-only are unchanged.
- **Shared learning is always on**, with the project baked into the build.

## Backend

Two pieces, both on Supabase free tiers:

| Piece | What it does | Setup |
|---|---|---|
| `training_examples` table | Pools anonymous play measurements across installs | Run `PoleScore.swiftpm/supabase-schema.sql` once |
| `polescore` Edge Function | Fronts the vision model so no model key ships in the app | `supabase secrets set GEMINI_API_KEY=…` then `supabase functions deploy polescore` |

The Edge Function picks its provider from whichever secret is set —
`GEMINI_API_KEY` (free tier) or `ANTHROPIC_API_KEY` (paid). With neither set it
returns 503 and the app scores entirely on device, which is a supported
configuration.
