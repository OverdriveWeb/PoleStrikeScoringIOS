import CoreGraphics
import Foundation

/// Translates what the model says into what the game already understands.
///
/// The scoring pipeline — `Tracker`, `PlayStateMachine`, `GameStore` — was
/// written against `Detection { label: Label, score: Double, box: Box }` and is
/// not being redesigned. YOLO speaks in strings and Vision rectangles. This is
/// the one file where those two vocabularies meet, which is what keeps the
/// model swappable: retrain with different class names and only
/// `expectedLabels` and `canonical(_:)` change.
///
/// The interesting work is not renaming. It is that YOLO reports "a bottle",
/// while the game needs "the *left* bottle" — a distinction the model cannot
/// make because it depends on the court, which is a thing only this app knows.
/// Assigning sides is done here, against the detected court.
enum DetectionBridge {

    /// Class names the app looks for. Anything else the model reports is
    /// ignored rather than guessed at.
    static let expectedLabels = ["frisbee", "bottle", "pole", "person", "ground"]

    /// Tolerate the obvious synonyms so a model exported from a slightly
    /// different dataset still works without a rebuild. COCO, for instance,
    /// calls the disc a frisbee and has no pole class at all.
    static func canonical(_ raw: String) -> String? {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "frisbee", "disc", "disk", "flying_disc", "flying disc":
            return "frisbee"
        case "bottle", "glass_bottle", "glass bottle":
            return "bottle"
        case "pole", "post", "stake", "pole_top":
            return "pole"
        case "person", "player", "people":
            return "person"
        case "ground", "grass", "floor", "field":
            return "ground"
        default:
            return nil
        }
    }

    /// Everything the frame told us, sorted into the shapes the rest of the app
    /// consumes.
    struct Reading {
        /// Ready for `Tracker.update`.
        var detections: [Detection] = []
        /// Pole boxes in app coordinates, left first. Used to detect the court.
        var poles: [Box] = []
        /// Bottle boxes in app coordinates, unassigned.
        var bottles: [Box] = []
        /// Top edge of any detected ground region, as a normalized y.
        var groundY: Double?
        /// True when the model saw enough to say where the court is.
        var canDefineCourt: Bool { poles.count >= 2 }
    }

    /// Convert one frame of model output.
    ///
    /// `court` may be nil — during the first seconds there is no court yet, and
    /// the poles detected here are what will create one. Without a court,
    /// bottles and poles simply come back unassigned rather than being given a
    /// side that would be a coin flip.
    static func read(_ raw: [YOLODetection], court: Court?) -> Reading {
        var reading = Reading()

        var poles: [(box: Box, score: Double)] = []
        var bottles: [(box: Box, score: Double)] = []

        for detection in raw {
            guard let name = canonical(detection.label) else { continue }
            let box = DetectionCoordinateMapper.topLeftNormalized(fromVisionBox: detection.boundingBox)
            let score = Double(detection.confidence)

            switch name {
            case "frisbee":
                reading.detections.append(Detection(label: .disc, score: score, box: box))
            case "person":
                reading.detections.append(Detection(label: .player, score: score, box: box))
            case "pole":
                poles.append((box, score))
            case "bottle":
                bottles.append((box, score))
            case "ground":
                // The top edge of the ground region is the ground line. Keep the
                // highest one seen this frame — the grass nearest the camera
                // sits lower in shot and would drag the line down.
                let top = box.y
                reading.groundY = reading.groundY.map { min($0, top) } ?? top
            default:
                break
            }
        }

        // Keep the two strongest poles and order them left to right. More than
        // two means a fence post or a chair leg got in; fewer means the court
        // is not fully in shot.
        let bestPoles = poles.sorted { $0.score > $1.score }.prefix(2)
            .sorted { $0.box.center.x < $1.box.center.x }
        reading.poles = bestPoles.map(\.box)
        reading.bottles = bottles.map(\.box)

        // Sides need a court. With one, a pole or bottle belongs to whichever
        // calibrated pole it is nearer — which is robust even when a bottle has
        // been knocked halfway across the frame, because it only has to be
        // nearer to its own pole than to the other one.
        if let court {
            for (box, score) in poles {
                let side: Side = distance(box.center, court.leftTop) <= distance(box.center, court.rightTop)
                    ? .left : .right
                reading.detections.append(Detection(label: .pole(side), score: score, box: box))
            }
            for (box, score) in bottles {
                let side: Side = distance(box.center, court.leftTop) <= distance(box.center, court.rightTop)
                    ? .left : .right
                reading.detections.append(Detection(label: .bottle(side), score: score, box: box))
            }
        } else if bestPoles.count == 2 {
            // No court yet, but two poles is itself enough to say which is
            // which, so bottles can be assigned by proximity to those.
            let left = bestPoles[0].box.center
            let right = bestPoles[1].box.center
            for (index, pole) in bestPoles.enumerated() {
                reading.detections.append(Detection(label: .pole(index == 0 ? .left : .right),
                                                    score: pole.score, box: pole.box))
            }
            for (box, score) in bottles {
                let side: Side = distance(box.center, left) <= distance(box.center, right) ? .left : .right
                reading.detections.append(Detection(label: .bottle(side), score: score, box: box))
            }
        }

        // One detection per label per frame. The tracker matches by label, and
        // two boxes claiming to be the left bottle would have it flipping
        // between them from frame to frame.
        return dedupe(reading)
    }

    private static func dedupe(_ reading: Reading) -> Reading {
        var best: [Label: Detection] = [:]
        for detection in reading.detections {
            if let existing = best[detection.label], existing.score >= detection.score { continue }
            best[detection.label] = detection
        }
        var result = reading
        result.detections = Array(best.values)
        return result
    }

    /// Build a court straight from a frame in which both poles were detected.
    ///
    /// This is the payoff for using a model at all. The blob-based detector had
    /// to infer the ground line from what stayed still and where thrown objects
    /// landed, because a brightness threshold cannot tell a pole from a bottle.
    /// A model that has a `pole` class gives the whole pole, top and bottom, in
    /// one frame — and the bottom of a pole *is* the ground line.
    static func court(from reading: Reading, existing: Court?) -> Court? {
        guard reading.poles.count >= 2 else { return nil }
        let left = reading.poles[0]
        let right = reading.poles[1]

        let leftTop = Pt(x: left.center.x, y: left.y)
        let rightTop = Pt(x: right.center.x, y: right.y)

        // Prefer an explicit ground detection; otherwise the foot of each pole.
        let leftGroundY = reading.groundY ?? (left.y + left.h)
        let rightGroundY = reading.groundY ?? (right.y + right.h)

        guard abs(rightTop.x - leftTop.x) >= 0.12,
              leftGroundY > leftTop.y + 0.04,
              rightGroundY > rightTop.y + 0.04 else { return nil }

        var court = Court(
            leftTop: leftTop,
            rightTop: rightTop,
            leftBase: Pt(x: leftTop.x, y: leftGroundY),
            rightBase: Pt(x: rightTop.x, y: rightGroundY),
            leftBottle: bottleBox(at: leftTop),
            rightBottle: bottleBox(at: rightTop),
            groundA: Pt(x: leftTop.x, y: leftGroundY),
            groundB: Pt(x: rightTop.x, y: rightGroundY)
        )
        court.teamASide = existing?.teamASide ?? .left
        return court
    }

    private static func bottleBox(at point: Pt) -> Box {
        Box(x: point.x - 0.015, y: point.y - 0.0175, w: 0.03, h: 0.035)
    }
}
