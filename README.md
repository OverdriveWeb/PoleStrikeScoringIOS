# PoleStrikeScoringIOS

Camera scoring for a Strike Pole / Beersbee set. Runs on iPhone or iPad from
Swift Playgrounds — no Apple Developer account needed.

**Latest build: `PoleScore-v9.zip`** (`PoleScore-v7.zip` is the last release
before the rewrite, kept for reference).

Download the zip on the device, uncompress it in the Files app, and tap
`PoleScore.swiftpm`. Full instructions — including the camera capability you
must enable before the first run, and where to put the Core ML model — are in
[`PoleScore.swiftpm/README.md`](PoleScore.swiftpm/README.md).

## What changed in v9

- **On-device YOLO detection.** A Core ML model named `GameDetector` recognises
  the poles, bottles, disc and players directly. Everything runs on the device's
  neural engine: no AI service is called, no frames leave the phone, and it
  works in a field with no signal.
- **The court comes from the model.** A `pole` detection gives the whole pole in
  one frame, and the bottom of a pole *is* the ground line — the measurement
  worth a point every time it is wrong. Previously that had to be inferred from
  what stayed still and where thrown objects landed.
- **It degrades instead of failing.** With no model in the bundle, a model that
  will not load, or a device too hot to run inference, the app falls back to the
  original glow-brightness detector and says so on screen. It never crashes and
  never silently pretends.
- **Frames are dropped, never queued.** Inference is capped at 10 fps
  (configurable), drops to 6 when the device reports a `serious` thermal state,
  and stops entirely at `critical`.
- **No cloud AI.** The Gemini/Claude Edge Function from the unreleased v8 has
  been removed along with all frame uploads.

Carried over from the v8 rewrite: no court setup, no glow-colour settings,
pinch-to-zoom, detected camera orientation, a per-frame brightness threshold,
and a genuinely hands-off Automatic mode. Ask-first and Tap-only are unchanged.

## Backend

One piece, on the Supabase free tier, and it is not an AI service:

| Piece | What it does | Setup |
|---|---|---|
| `training_examples` table | Pools anonymous play measurements across installs | Run `PoleScore.swiftpm/supabase-schema.sql` once |

What leaves the device is fourteen numbers per play and the correct call — no
video, no images, no account. The project URL and anon key are baked into
`CloudDefaults.swift`, so there is nothing to configure on the phone.

## Repository layout

| Path | What it is |
|---|---|
| `PoleScore.swiftpm/` | The app. Open this in Swift Playgrounds or Xcode. |
| `Tests/DetectionTests.swift` | XCTest wrappers for the detection maths. Deliberately **outside** the package — a Playgrounds app package cannot host a test target. On device the same checks run from Coach → Detection self-checks. |
| `PoleScore-v9.zip` | Packaged build, for downloading straight onto a device. |
