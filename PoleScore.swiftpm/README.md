# PoleScore for Swift Playgrounds

Live camera scoring for a Strike Pole / Beersbee set, built to run on your iPad
or iPhone straight from Swift Playgrounds — **no Apple Developer account, no
cloud build, no expiry to work around.**

Everything runs on the device. There is no AI service call, no frame upload, and
the app works in a field with no signal.

## Getting it running

1. Download the zip on the device, then unzip it in the **Files** app (long
   press → Uncompress).
2. Tap `PoleScore.swiftpm`. It opens in Swift Playgrounds.
3. **Turn on camera access before the first run.** Tap the app-settings control
   in Playgrounds (the ⚙/app icon at the top), find **Capabilities**, add
   **Camera**, and give it a description like "Watches the court to score
   plays." Without this the app builds fine but the preview stays black.
4. Press ▶ to run.

## Adding the YOLO model

The app looks for a Core ML model named **`GameDetector`** in its bundle. Without
one it still works — it falls back to the glow-brightness detector and says so
on the game screen — but the model is what makes the ground line reliable.

### Which model?

There is no off-the-shelf beersbee detector, and the class the app most wants —
`pole` — does not exist in any pretrained model. Every stock YOLO is trained on
COCO, which has `frisbee`, `bottle` and `person` but no `pole` and no `ground`.

So there are two routes, and the first is worth doing even if you intend to do
the second.

**Route 1 — a stock COCO model, about ten minutes.** You get `frisbee`, `bottle`
and `person` free, and the app builds the court from the bottles instead of the
poles. This will not be as accurate as a trained model, and a COCO model has
never seen a glowing object at night, so expect it to struggle in the dark. Its
real value is that it proves the whole pipeline end to end — model loads, boxes
land on objects, court establishes, score moves — before you spend a day
labelling.

```python
from ultralytics import YOLO
YOLO("yolo11n.pt").export(format="coreml", nms=True, imgsz=320)
```

Rename the result to `GameDetector.mlpackage`.

**Route 2 — train on your own court.** This is what gets you a `pole` class and
something that works after dark.

1. Record a few minutes of video on the phone, from where it will actually sit,
   at night, with the set lit. Include throws, knocked bottles, catches.
2. Pull 200–500 stills out of it. More matters less than variety: different
   light, different distances, disc mid-flight, bottle mid-fall.
3. Label them at [roboflow.com](https://roboflow.com) (free tier) with exactly
   these classes: `pole`, `bottle`, `frisbee`, `person`, and optionally
   `ground`. Draw the pole box from the bottle down to the grass — the bottom
   edge is what becomes the ground line.
4. Train free on Colab with a T4:
   ```python
   from ultralytics import YOLO
   model = YOLO("yolo11n.pt")
   model.train(data="data.yaml", epochs=100, imgsz=320)
   model.export(format="coreml", nms=True, quantize=8, imgsz=320)
   ```
5. Rename to `GameDetector.mlpackage`.

Use the smallest model that works — `yolo11n` (nano). This runs on every frame
on a phone in your pocket; `yolo11x` will thermally throttle the device long
before it improves a single call.

### 1. Export notes

Core ML export needs a Mac. Start at `imgsz=320` for live detection and only
increase it if the disc is being missed mid-flight. Keep `nms=True`: it produces
a pipeline Vision recognises directly, so no box decoding happens on device at
all. `quantize=8` roughly halves the file with little accuracy cost.

If you export with `nms=False`, the app still works — `YOLOOutputParser` decodes
the raw head and runs its own NMS — but that path does more work per frame and
is the less-tested of the two.

### 2. Add it to the app

**In Swift Playgrounds:** put `GameDetector.mlpackage` next to the `.swift`
files inside `PoleScore.swiftpm`, using the Files app. Playgrounds has no Core ML
build rule, so the app compiles the model itself on first launch — that takes a
few seconds once, then it is cached. This is why the code loads the model by URL
rather than through an Xcode-generated `GameDetector` class: that class does not
exist in a Playgrounds build.

**In Xcode:** drag `GameDetector.mlpackage` into the project, tick **Copy items
if needed**, and confirm **Target Membership** includes the app target — select
the file and check the box in the File Inspector on the right. If the model is
in the project navigator but the box is unticked, it will not be in the bundle
and the app will report "YOLO model missing from app bundle". Xcode compiles it
to `GameDetector.mlmodelc`, which the loader finds first and uses directly.

Either way, if the model is absent, damaged, or fails to compile, the app shows a
status line and keeps scoring. It does not crash.

### 3. Class names it expects

| Class | Used for |
|---|---|
| `pole` | Finding the court. The **bottom** of the pole box is the ground line. |
| `bottle` | The thing being knocked off. Assigned to a side by proximity to a pole. |
| `frisbee` | The disc. |
| `person` | Catch detection near a player. |
| `ground` | Optional. If present, its top edge overrides the pole feet as the ground line. |

Common synonyms are accepted (`disc`, `post`, `player`, `grass`, and a few
others — see `canonical(_:)` in `DetectionBridge.swift`). Anything else the model
reports is ignored rather than guessed at. To change the vocabulary, edit that
one function; nothing else in the app knows about class names.

### 4. Tuning it

**Settings → Object detection** has the two numbers worth changing:

- **Detection confidence** (default 0.45). Raise it if boxes appear on things
  that are not there; lower it if the disc is being missed in flight.
- **Inference rate** (default 10 fps). Lower it to save battery. Below about
  5 fps the tracker starts losing object identity between frames.

Both take effect immediately. The rate drops to 6 fps by itself when the device
reports a `serious` thermal state, and inference stops entirely at `critical`
with "AI paused: device too hot" on screen — scoring continues on the glow
detector throughout.

**Settings → Show detection boxes** draws what the model sees. The developer
overlay (also in Settings) adds tracker boxes, the ground line, an inference HUD,
and the coordinate self-checks under **Coach → Detection self-checks**.

## Testing on a real device

The simulator has no camera, so all of this needs hardware:

1. Run the app and open **Settings → Show detection boxes** and **Developer
   overlay**.
2. Point the phone at the court. Within a second or two the top line should read
   **Court set · Detected by the YOLO model**.
3. Check the HUD: `infer` should sit near your configured rate, `last` under
   about 60 ms, `thermal` at `nominal` or `fair`.
4. Confirm boxes sit **on** the objects, not offset. If every box is shifted
   vertically the origin flip is wrong; if they are squashed toward the middle
   the aspect-fill crop is not being undone. Both are covered by
   **Coach → Detection self-checks**, which should show 10/10 passing.
5. Throw. The score should move on its own in Automatic mode.
6. Pull the model out of the bundle and run again — the app should report the
   model missing and keep scoring.

## The three modes

| Mode | What it does |
|---|---|
| **Automatic** (default) | Hands off. Every play is called and scored on its own — no prompts, no pauses, nothing to confirm, and no waiting for anyone to put a bottle back on a pole before it carries on. |
| **Ask first** | Every call waits for one tap. Costs a tap per play and gives the learning system a human label each time. |
| **Tap only** | A plain scoreboard with big buttons. Detection still runs for the overlay. |

## How detection works

Two pipelines, one live at a time.

**With the model:** frames go to `YOLODetectionService`, which reuses a single
`VNCoreMLRequest`, runs at most 10 inferences a second, and drops any frame that
arrives while the previous one is still running — it never queues, so detections
cannot drift behind the picture. Results come back as `YOLODetection` in Vision
coordinates, and `DetectionBridge` turns them into the `Detection` type the
tracker and state machine already consumed.

**Without it:** the original glow-brightness detector, unchanged. It finds the
lit blobs, learns which glow colours belong to which object, and infers the court
from what stays still and where thrown objects come to rest.

The model's real advantage is the ground line. Brightness cannot tell a pole from
a bottle from a porch light, so the old path had to infer the floor indirectly. A
model with a `pole` class hands over the whole pole in one frame, and the bottom
of a pole *is* the ground line — which is worth exactly one point per play, every
time it is wrong.

## Catch vs ground

In the dark there are often no visible players, so a catch is recognised by
**height**: an object that stops moving well above the ground line is being held;
one that stops at the line is not.

| What happened | How it is recognised |
|---|---|
| Disc caught | Disc was moving, then stops **above** the ground line |
| Disc hits the ground | Disc reaches the ground line and settles |
| Bottle knocked, then caught | Bottle leaves the pole top, then stops **above** the line |
| Bottle knocked, hits ground | Bottle leaves the pole top and reaches the line |

One subtlety that caused a real bug during development: the first moments of a
bottle toppling look *exactly* like a catch — high up and barely moving. So a
catch requires motion **followed by** stillness. An object that never moved fast
during a play can never be called caught.

## Camera

Pinch anywhere on the game screen to zoom, exactly like the camera app;
double-tap snaps between 1× and 2×. Zooming moves every normalized coordinate in
the frame, so the court is re-read automatically straight afterwards.

Orientation comes from the system's rotation coordinator, which rotates the
capture connection — so what the model sees and what you see are the same picture
in the same orientation, and the app passes `.up` to Vision rather than trying to
work the angle out a second time.

## Learning

**Ask-first mode** is where labelled examples come from. Automatic mode never
asks, so it never collects one.

**Threshold tuning (evolutionary).** Coach → **Tune thresholds** runs a
mutation-and-selection loop over the six numbers that decide a call. Fitness is
how often a threshold set reproduces the calls that were confirmed. Gradient
descent is the wrong tool — confirm frames is an integer and the rules are hard
comparisons with no derivative — but evolution handles that and converges in
under a second. Needs about 8 examples.

**A learned model.** A small network (14 inputs → 10 hidden → 6 calls) trained by
SGD on the same examples, blended into the confidence score by how much evidence
it has earned. At zero examples it has no say at all.

### Shared learning

Always on, nothing to set up. What leaves the device is **fourteen numbers per
play and the correct call** — a row is literally `[1, 5, 0, 0.02, 0.41, ...] -> 0`.
No video, no images, no location, no account. This is the only network traffic
the app generates, and it is not an AI service.

Run `supabase-schema.sql` in the Supabase SQL editor once and the table exists;
the project URL and anon key are already baked into `CloudDefaults.swift`.

## Honest limits

- The model is only as good as what it was trained on. A model that has never
  seen a glowing bottle at night will not find one at night.
- A bottle landing behind a pole, hidden from the camera, cannot be resolved.
- Keep the device still. A moved phone triggers a court re-read, which costs a
  few seconds of scoring.
- Inference costs battery and heat. The thermal guard protects the device, but a
  long game on a hot day will spend time on the fallback detector.
- Nothing is uploaded except the fourteen numbers. No video is recorded; frames
  are analysed and dropped.
