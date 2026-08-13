import Foundation

/// Works out where the court is by watching it, so nobody has to tap anything.
///
/// The old version asked for six taps: both pole tops, both bottles, and the
/// ground at each pole. That was the most reliable way to get the one
/// measurement everything hinges on — the ground line, which separates a caught
/// bottle from one lying in the grass — and it was also the thing most likely
/// to be done carelessly, or skipped, or invalidated the moment somebody
/// nudged the phone.
///
/// So it is inferred instead, from three signals that a beersbee court produces
/// for free:
///
///   **Bottles do not move.** Between throws, the two brightest things that
///   stay put in the same spot frame after frame are the bottles on the pole
///   tops. Everything else in shot is either moving or transient.
///
///   **Poles are long and vertical.** When the set glows, a pole is a tall thin
///   streak. Its top is where the bottle sits and its bottom is where it meets
///   the grass — the ground line, read directly.
///
///   **Things that fall come to rest on the ground.** When the poles are not
///   lit, the ground line is learned from the disc: wherever thrown objects
///   stop and stay, that is the floor. A few plays are enough.
///
/// Every one of those is a guess with an error bar, which is why a YOLO model
/// that can actually recognise a pole gets to overrule the lot of them — see
/// `accept(modelCourt:confidence:)`. This is the version that runs when the
/// model is missing, still loading, or paused because the device is too hot.
struct CourtEstimate {
    enum Source: String {
        case local, model

        var label: String {
            switch self {
            case .local: return "Read from the scene"
            case .model: return "Detected by the YOLO model"
            }
        }
    }

    var court: Court
    var confidence: Double
    var source: Source
}

final class CourtDetector {

    /// A lit thing that has stayed in one place. Anchors are how "the bottles
    /// are the two bright things that never move" becomes a measurement.
    private struct Anchor {
        var center: Pt
        var hits: Int
        var lastSeen: Double
        var top: Double
        var bottom: Double
        var maxAspect: Double
        var brightness: Double

        mutating func absorb(_ blob: Blob, timestamp: Double) {
            // Slow mean: an anchor is defined by where the object *usually* is,
            // so one frame of blur or bloom cannot drag it off the pole.
            let a = 0.15
            center = Pt(x: center.x * (1 - a) + blob.box.center.x * a,
                        y: center.y * (1 - a) + blob.box.center.y * a)
            top = min(top, blob.box.y)
            bottom = max(bottom, blob.box.y + blob.box.h)
            maxAspect = max(maxAspect, blob.box.aspect)
            brightness = max(brightness, blob.brightness)
            hits += 1
            lastSeen = timestamp
        }
    }

    // Tuning. These are the only numbers in the file and each one is a physical
    // claim about a backyard court, not a magic constant.

    /// How far a lit object may drift and still count as "the same anchor".
    var anchorRadius = 0.035
    /// Frames an anchor must hold before it is evidence of anything.
    var minimumHits = 12
    /// Anchors go stale if unseen for this long — the set was moved, or a light
    /// was switched off.
    var anchorTimeout = 6.0
    /// Poles must be at least this far apart across the frame. Closer than this
    /// and you are looking at one pole and a reflection.
    var minimumSeparation = 0.14
    /// Pole tops sit at roughly the same height. More tilt than this and the
    /// two anchors are not a pair.
    var maximumTilt = 0.26
    /// A blob this much taller than it is wide is a pole, not a bottle.
    var poleAspect = 2.0
    /// With no other evidence, a pole stands about this tall in frame relative
    /// to the gap between the poles. Only used as a last resort.
    var fallbackHeightRatio = 0.42

    private var anchors: [Anchor] = []
    private var groundSamples: [Double] = []
    private var lastTimestamp: Double = 0
    private var poleAspectSeen = false

    private(set) var current: CourtEstimate?

    var isReady: Bool { current != nil }

    /// How close this is to having an answer, for the one line of status the
    /// game screen shows while it works it out.
    var progress: Double {
        guard current == nil else { return 1 }
        let best = anchors.map(\.hits).sorted(by: >).prefix(2).reduce(0, +)
        return clamp(Double(best) / Double(minimumHits * 2), 0, 1)
    }

    func reset() {
        anchors = []
        groundSamples = []
        poleAspectSeen = false
        current = nil
    }

    /// Called for every analysed frame, before the classifier runs.
    func observe(blobs: [Blob], timestamp: Double) {
        lastTimestamp = timestamp
        anchors.removeAll { timestamp - $0.lastSeen > anchorTimeout }

        for blob in blobs {
            // Enormous blobs are a light source or a bloomed-out sky, not a set.
            guard blob.area <= 0.06 else { continue }
            if blob.box.aspect >= poleAspect { poleAspectSeen = true }

            if let index = nearestAnchor(to: blob.box.center) {
                anchors[index].absorb(blob, timestamp: timestamp)
            } else {
                anchors.append(Anchor(center: blob.box.center,
                                      hits: 1,
                                      lastSeen: timestamp,
                                      top: blob.box.y,
                                      bottom: blob.box.y + blob.box.h,
                                      maxAspect: blob.box.aspect,
                                      brightness: blob.brightness))
            }
        }

        // Keep the list bounded; a field of fairy lights should not grow this
        // without limit.
        if anchors.count > 40 {
            anchors.sort { $0.hits > $1.hits }
            anchors.removeLast(anchors.count - 40)
        }

        refresh(timestamp: timestamp)
    }

    /// Where something that was thrown finally stopped. Over a few plays this
    /// is the most honest ground line available, because it is literally the
    /// height at which objects stop falling.
    func observeRest(_ point: Pt) {
        groundSamples.append(point.y)
        if groundSamples.count > 60 { groundSamples.removeFirst() }
    }

    /// The YOLO model saw actual poles rather than a handful of bright pixels,
    /// so its answer replaces the local one outright.
    ///
    /// This is the single biggest thing the model buys. Everything above infers
    /// the ground line indirectly, because a brightness threshold cannot tell a
    /// pole from a bottle from a porch light. A model with a `pole` class hands
    /// over the whole pole in one frame, and the bottom of a pole *is* the
    /// ground line — measured, first frame, no waiting for something to land.
    func accept(modelCourt: Court, confidence: Double) {
        current = CourtEstimate(court: modelCourt,
                                confidence: max(0.8, confidence),
                                source: .model)
    }

    /// True when the scene no longer matches the court we are scoring against —
    /// the phone was bumped, or somebody zoomed. The caller starts over.
    func hasDrifted() -> Bool {
        guard let estimate = current, estimate.source == .local else { return false }
        guard let pair = polePair() else { return false }
        let court = estimate.court
        return distance(pair.left.center, court.leftTop) > 0.09
            || distance(pair.right.center, court.rightTop) > 0.09
    }

    // MARK: - Estimation

    private func nearestAnchor(to point: Pt) -> Int? {
        var best: Int?
        var bestDistance = anchorRadius
        for (index, anchor) in anchors.enumerated() {
            let d = distance(anchor.center, point)
            if d <= bestDistance {
                bestDistance = d
                best = index
            }
        }
        return best
    }

    /// The two settled anchors furthest apart horizontally, at roughly the same
    /// height. On a two-pole court that is the poles, every time.
    private func polePair() -> (left: Anchor, right: Anchor)? {
        let settled = anchors.filter { $0.hits >= minimumHits }
        guard settled.count >= 2 else { return nil }

        var best: (Anchor, Anchor)?
        var bestScore = 0.0
        for i in 0..<settled.count {
            for j in (i + 1)..<settled.count {
                let a = settled[i], b = settled[j]
                let separation = abs(a.center.x - b.center.x)
                guard separation >= minimumSeparation else { continue }
                guard abs(a.center.y - b.center.y) <= maximumTilt else { continue }
                // Prefer wide, well-attested pairs over wide flukes.
                let score = separation * Double(min(a.hits, b.hits))
                if score > bestScore {
                    bestScore = score
                    best = a.center.x <= b.center.x ? (a, b) : (b, a)
                }
            }
        }
        guard let best else { return nil }
        return (best.0, best.1)
    }

    private func refresh(timestamp: Double) {
        // A model answer outranks anything found here, and is not re-derived.
        if let current, current.source == .model { return }
        guard let pair = polePair() else { return }

        let leftTop = Pt(x: pair.left.center.x, y: pair.left.top)
        let rightTop = Pt(x: pair.right.center.x, y: pair.right.top)
        let ground = groundLine(pair: pair, leftTop: leftTop, rightTop: rightTop)

        var court = Court(
            leftTop: leftTop,
            rightTop: rightTop,
            leftBase: ground.left,
            rightBase: ground.right,
            leftBottle: bottleBox(at: pair.left.center),
            rightBottle: bottleBox(at: pair.right.center),
            groundA: ground.left,
            groundB: ground.right
        )
        court.teamASide = .left

        // Sanity: a court whose ground line sits above its poles is not a court.
        guard ground.left.y > leftTop.y + 0.03, ground.right.y > rightTop.y + 0.03 else { return }

        current = CourtEstimate(court: court,
                                confidence: ground.confidence,
                                source: .local)
    }

    private func groundLine(pair: (left: Anchor, right: Anchor),
                            leftTop: Pt, rightTop: Pt) -> (left: Pt, right: Pt, confidence: Double) {
        // Best case: the poles themselves are lit, so their lower ends are the
        // ground, measured rather than guessed.
        if poleAspectSeen,
           pair.left.maxAspect >= poleAspect, pair.right.maxAspect >= poleAspect,
           pair.left.bottom > leftTop.y + 0.05, pair.right.bottom > rightTop.y + 0.05 {
            return (Pt(x: leftTop.x, y: pair.left.bottom),
                    Pt(x: rightTop.x, y: pair.right.bottom),
                    0.85)
        }

        // Next best: things that were thrown and came to rest. The floor is
        // where they stopped. A high percentile rather than the maximum, so one
        // disc landing in a bush does not define the court.
        if groundSamples.count >= 6 {
            let sorted = groundSamples.sorted()
            let y = sorted[Int(Double(sorted.count - 1) * 0.8)]
            if y > max(leftTop.y, rightTop.y) + 0.05 {
                return (Pt(x: leftTop.x, y: y), Pt(x: rightTop.x, y: y), 0.72)
            }
        }

        // Last resort: a pole is about this tall relative to the gap between
        // the poles. Good enough to start scoring; the two routes above replace
        // it within a play or two, and the cloud read replaces it immediately.
        let span = abs(rightTop.x - leftTop.x)
        let drop = max(0.16, span * fallbackHeightRatio)
        return (Pt(x: leftTop.x, y: min(0.98, leftTop.y + drop)),
                Pt(x: rightTop.x, y: min(0.98, rightTop.y + drop)),
                0.5)
    }

    /// The resting zone for a bottle, centred on where the bottle actually sits.
    private func bottleBox(at point: Pt) -> Box {
        Box(x: point.x - 0.015, y: point.y - 0.0175, w: 0.03, h: 0.035)
    }
}
