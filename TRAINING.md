# Training the detector

Start-to-finish: footage on your phone → a `GameDetector.mlpackage` the app
loads and uses to set up any court by itself.

Budget about **3–4 hours the first time**, most of it labelling. Everything here
is free.

> **On button names.** Roboflow and Colab change their interfaces regularly. The
> labels below are what to look for, not a promise about pixel positions. If a
> button has moved, the shape of the step is still right — you are uploading
> images, drawing boxes, exporting a *dataset*, and training elsewhere.

---

## The one thing that decides whether this works

**A model only recognises what it has seen.** Train on 300 photos of your
backyard at 9pm and you get something excellent at your backyard at 9pm and
useless at a friend's place at dusk. There is no setting, no epoch count and no
architecture that fixes this — the fix is always more varied data.

So the target is not "300 good photos." It is **300 photos that disagree with
each other** about everything except what a pole, a bottle and a disc are:

| Vary this | Why |
|---|---|
| **Location** — different yards, parks, beaches, indoors | The single biggest factor. Two courts beats one court twice over. |
| **Time and light** — dusk, full dark, floodlit, moonlight | Otherwise it learns "dark green blur" rather than "bottle". |
| **Distance and height** — phone at 10ft and 40ft, on the ground and chest-high | The app is used from wherever is convenient. |
| **Angle** — square on, from one side, slightly above and below | Courts are rarely framed neatly. |
| **The set itself** — different bottles, different discs, glowing and not | Stops it keying on one specific green glow. |
| **Background clutter** — people walking, cars, porch lights, fences | Teaches it what is *not* a pole. |
| **The action** — disc mid-flight, bottle mid-fall, bottle on the grass, hands catching | Blurred mid-flight objects are the hard case and they must be in the training set. |

If you genuinely only have one court, you can still do this — vary everything in
the list you *can* control, and lean on the fallback described at the bottom.
Just know the ceiling is lower.

---

## Step 1 — Collect footage

Record on the phone you will actually score with, propped where it will actually
sit.

- **5–10 minutes of video per location.** Play a real game; do not pose.
- Move the phone between rounds: closer, further, higher, off to one side.
- Get at least one session that is **badly lit** and one that is **over-lit**.
- If a friend has a set, film theirs. One extra location is worth more than
  another hour at yours.

Target **at least 2 locations**, ideally 4+. This is the step people skip and
then wonder why the model does not travel.

---

## Step 2 — Turn video into stills

You want **200–500 images**, spread across everything you filmed.

Do **not** take every frame. Consecutive frames are nearly identical, and a
dataset of near-duplicates teaches the model almost nothing while tripling your
labelling time.

Roboflow can do this for you: upload the `.mp4` files directly and it offers a
frame rate to sample at. **Choose 1 frame per second**, or lower for long clips.

If you would rather do it locally:

```bash
ffmpeg -i game1.mp4 -vf fps=1 game1_%04d.jpg
```

---

## Step 3 — Set up the Roboflow project

1. Sign up at **roboflow.com** (the free plan is enough).
2. **Create New Project.**
   - Project Type: **Object Detection**
   - Annotation Group: `objects` (this is just a label for your own benefit)
   - License / name: anything.
3. **Upload** your images or videos. If uploading video, set the sampling rate
   to 1 fps when prompted.
4. When the upload finishes, click **Save and Continue**.

---

## Step 4 — Label

This is the long part. Open the first image and click **Start Annotating**.

Draw a box around every instance of these five classes. **Type the class names
exactly** — the app matches on them:

| Class | Where to draw the box | Notes |
|---|---|---|
| `pole` | **From the bottle at the top all the way down to the grass.** | The single most important box in the dataset. The app takes the **bottom edge as the ground line**, which is what separates a caught bottle from one lying on the floor — worth a point every time it is wrong. Do not stop the box partway down. |
| `bottle` | Tight around the bottle | Label it on the pole, mid-air, and on the ground. All three matter. |
| `frisbee` | Tight around the disc | **Include the blurry mid-flight ones.** A smeared streak is the hardest and most valuable example in the set. |
| `person` | Whole visible body | Even partial figures at the frame edge. |
| `ground` | *(optional)* a wide flat box over the grass at the base of the poles | Skip it if it feels ambiguous. The pole feet already give the ground line. |

Rules that matter more than they look:

- **Label every instance in every image.** One unlabelled bottle teaches the
  model that bottles are sometimes background, which is worse than not having
  the image at all.
- **Box occluded objects** as far as you can see them. A bottle half behind a
  leg is still a bottle.
- **Keep boxes tight.** Loose boxes shift the ground line downward.
- If an image contains nothing at all, keep it and label nothing. Roboflow calls
  these **null / background images** and they are how the model learns not to
  see poles in a hedge. Aim for roughly 5–10% of the set.

Use keyboard shortcuts — press the number key for a class, drag, repeat. It is
about 3× faster than clicking the class list each time.

---

## Step 5 — Split the data (do not skip this)

Click **Generate** in the left sidebar. Before generating, check the
**Train/Test Split**.

Default is 70/20/10 train/valid/test, which is fine — **but there is a trap
specific to video-derived datasets.** Frames one second apart are nearly
identical. If Roboflow splits them randomly, near-copies of the same moment land
in both train and validation, the model effectively sees the answers, and your
reported accuracy will look superb while real performance is poor.

**Fix:** split by scene. The reliable way is to upload each location or session
as its own **Batch**, then assign whole batches to train or valid rather than
letting them shuffle. At minimum, keep **one entire location out of training**
and use it as validation — that number tells you what you actually want to know,
which is *does this work somewhere it has never seen*.

---

## Step 6 — Preprocessing and augmentation

Still on the **Generate** page.

**Preprocessing:**

| Setting | Value |
|---|---|
| Auto-Orient | **On** |
| Resize | **Stretch to 320 × 320** |

Match this to the `imgsz` you train and export with. The app feeds whole frames
to the model with `.scaleFill`, which stretches rather than crops — so training
on stretched images matches what it will see in the field.

**Augmentation** — this is where you buy generalization you did not film:

| Augmentation | Value | Why |
|---|---|---|
| Brightness | **±40%** | Covers dusk through floodlight. The highest-value one here. |
| Exposure | **±25%** | Phone auto-exposure swings a lot at night. |
| Blur | **up to 2.5px** | Teaches it to keep finding a disc in motion. |
| Noise | **up to 3%** | Night footage is grainy. High ISO looks like this. |
| Rotation | **±10°** | A propped phone is never perfectly level. |
| Scale / Crop | **0–20%** | Covers different distances. |
| Horizontal Flip | **On** | The court is symmetric left-to-right. Free doubling. |

**Do not enable:**

- **Vertical Flip** — gravity is the entire premise of the scoring. An upside
  down pole teaches the model that ground lines can be at the top.
- **Grayscale** — colour is a real signal for glowing objects.
- **Mosaic** at high intensity — it can chop poles in half and blur the
  relationship between a pole's top and its bottom.

Set **Max Version Size** to 3× your image count, then click **Create**.

---

## Step 7 — Export the dataset

When the version finishes, click **Export Dataset**.

- Format: **YOLOv8 PyTorch TXT**
- Choose **Show download code**

**Take the code snippet, not the zip.** You want to paste it into Colab.

> ⚠️ **Ignore the "Train with Roboflow" button.** That trains a model you then
> call through Roboflow's *hosted API* — cloud inference, which this app
> deliberately does not do, and it does not produce a Core ML file. It also
> costs credits. You want **Export Dataset**.

---

## Step 8 — Train on Colab (free GPU)

Go to **colab.research.google.com** → **New Notebook**.

First, turn the GPU on: **Runtime → Change runtime type → Hardware accelerator:
T4 GPU → Save.** Skipping this makes training roughly 20× slower.

Paste and run each cell.

**Cell 1 — install:**

```python
!pip install ultralytics roboflow -q
```

**Cell 2 — pull your dataset** (paste the snippet Roboflow gave you; it will
look like this):

```python
from roboflow import Roboflow
rf = Roboflow(api_key="YOUR_KEY_HERE")
project = rf.workspace("your-workspace").project("your-project")
dataset = project.version(1).download("yolov8")
print(dataset.location)
```

**Cell 3 — train:**

```python
from ultralytics import YOLO

model = YOLO("yolo11n.pt")   # nano: small and fast enough to run every frame

results = model.train(
    data=f"{dataset.location}/data.yaml",
    epochs=100,
    imgsz=320,
    batch=32,
    patience=25,       # stop early if validation stops improving
    device=0,
)
```

Starting from `yolo11n.pt` rather than scratch matters — those pretrained
weights already know edges, textures and object-ness from millions of images,
which is a large part of how a 300-image dataset generalizes at all.

Watch the **mAP50** column. Rough read: above 0.8 is good, 0.5–0.8 is usable,
below 0.5 means go back to Step 1 and get more varied footage.

**Cell 4 — export to Core ML:**

```python
model.export(format="coreml", nms=True, quantize=8, imgsz=320)
```

If that errors (building the NMS pipeline is the least portable part of the
export and Colab is Linux, not macOS), use this instead — the app handles it:

```python
model.export(format="coreml", nms=False, quantize=8, imgsz=320)
```

**Cell 5 — download:**

```python
from google.colab import files
import glob, shutil
src = glob.glob("runs/detect/train*/weights/*.mlpackage")[0]
shutil.make_archive("GameDetector", "zip", src)
files.download("GameDetector.zip")
```

---

## Step 9 — Get it into the app

1. Unzip `GameDetector.zip`. Inside is a `.mlpackage` folder.
2. **Rename it exactly `GameDetector.mlpackage`.** The app looks for that name.
3. Get it onto the iPad or iPhone — AirDrop, iCloud Drive, or a USB cable.
4. In the **Files** app, open the `PoleScore.swiftpm` folder and drop
   `GameDetector.mlpackage` in **next to the `.swift` files**.
5. Open the app in Swift Playgrounds and press ▶.

First launch takes a few extra seconds — the app compiles the model itself and
caches the result. **You do not need a Mac for any of this**; that on-device
compile step is exactly why.

---

## Step 10 — Check it worked

In the app: **Settings → Show detection boxes**, and **Developer overlay**.

| What to look for | Meaning |
|---|---|
| Top line reads **Court set · Detected by the YOLO model** | Working. |
| Boxes sit **on** the objects | Coordinates are right. |
| **Coach → Detection self-checks** shows 10/10 | The maths is right. |
| HUD `last` under ~60ms, `thermal` nominal or fair | Fast enough to keep up. |
| "YOLO model missing from app bundle" | Wrong filename or wrong folder. Recheck step 9. |

Then take it to a court it has never seen. That is the only test that answers
the question you actually care about.

---

## Making it work on *any* court

Realistically, generalization comes in tiers.

**Tier 1 — one location, ~300 images.** Excellent at your court. Mediocre
elsewhere. This is where everyone starts and it is a perfectly good place to be.

**Tier 2 — 3–4 locations, ~800 images.** Now it is learning "pole" rather than
"that pole". This is the point where it starts working at a friend's place
without being retrained.

**Tier 3 — 6+ locations across different surfaces, light and sets.** Robust
enough to hand to someone else.

Getting from Tier 1 to Tier 2 is almost entirely about filming somewhere else.
Not more epochs, not a bigger model, not more augmentation. **A larger model
trained on one court generalizes worse than a nano model trained on four**, and
it will thermally throttle your phone.

To retrain later: upload the new images to the same Roboflow project, label,
**Generate a new version**, and rerun the Colab notebook with `version(2)`. Your
old labels are kept.

### The safety net

The app does not fall over when the model is out of its depth. If YOLO cannot
find two poles, the court is built from the **bottles** instead — and if the
model is missing, broken, or paused because the device is hot, the whole thing
falls back to the original glow-brightness detector and says so on screen.

So a Tier 1 model at an unfamiliar court degrades rather than dying. That is
worth knowing before you spend a weekend chasing Tier 3.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| "YOLO model missing from app bundle" | Wrong name or location | Must be exactly `GameDetector.mlpackage`, inside `PoleScore.swiftpm` |
| Court never sets up | No `pole` detections | Check you labelled poles full-height; try lowering **Detection confidence** in Settings |
| Boxes are vertically mirrored | Origin flip | Run Coach → Detection self-checks; report which check fails |
| Boxes squashed toward the centre | Aspect-fill crop | Same self-checks — this is what they exist to catch |
| Disc never detected in flight | Not enough motion-blurred examples | Add blurred mid-flight frames, raise the Blur augmentation |
| Bottle/ground confused | Ground line too high | Label poles all the way to the grass and retrain |
| Works at home, fails elsewhere | Tier 1 dataset | Film another location. This is the answer basically every time. |
| Phone gets hot, "AI paused" | Inference too expensive | Lower **Inference rate** in Settings; make sure you used `yolo11n` |
| mAP50 looks great, real use is poor | Train/valid leak from video frames | Redo the split by location (Step 5) |
