import Foundation

/// Running estimate of one object's glow colour.
///
/// Hue is an angle, so it cannot be averaged the ordinary way — the mean of 350
/// and 10 degrees is 180, which is the opposite colour. Summing unit vectors and
/// taking the angle of the total is the correct version, and it comes with a
/// free bonus: the *length* of that total says how consistent the samples were.
/// A tight cluster gives a long vector; a set that glows every colour at once
/// gives a short one. That length is what decides whether colour is worth
/// trusting at all.
struct HueTracker {
    /// Every sample decays a little, so the estimate follows the set rather
    /// than remembering what colour it was an hour ago. Glow fades toward green
    /// as the night goes on, somebody swaps in a different disc, a bottle gets
    /// recharged at halftime — all of that is tracked automatically.
    var decay = 0.985
    var minimumWeight = 10.0
    var minimumSaturation = 0.2

    private var sinSum = 0.0
    private var cosSum = 0.0
    private var weight = 0.0

    mutating func add(hue: Double, saturation: Double) {
        guard saturation >= minimumSaturation else { return }
        sinSum *= decay
        cosSum *= decay
        weight *= decay

        // Weak colours vote quietly; a washed-out near-white blob should not
        // decide what colour the disc is.
        let vote = clamp((saturation - minimumSaturation) / 0.35, 0.15, 1)
        let radians = hue * .pi / 180
        sinSum += sin(radians) * vote
        cosSum += cos(radians) * vote
        weight += vote
    }

    mutating func reset() {
        sinSum = 0; cosSum = 0; weight = 0
    }

    /// How tightly the samples agree, 0...1. Below about 0.6 the object does
    /// not have a colour worth matching on.
    var tightness: Double {
        guard weight > 0 else { return 0 }
        return (sinSum * sinSum + cosSum * cosSum).squareRoot() / weight
    }

    var confidence: Double {
        min(1, weight / 30) * tightness
    }

    /// The learned hue, or nil while there is not enough consistent evidence.
    var hue: Double? {
        guard weight >= minimumWeight, tightness >= 0.6 else { return nil }
        var degrees = atan2(sinSum, cosSum) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }
}

/// What the app has worked out about the colour of this particular set.
///
/// There used to be a Settings screen for this — pick the disc colour, pick the
/// bottle colour. It was removed because the premise was wrong: the colours are
/// not a property of the app's configuration, they are a property of whatever
/// happens to be on the field tonight, and they change *during* a game as the
/// glow fades or somebody brings out a different disc. A setting that has to be
/// right, can go stale, and nobody will revisit mid-game is worse than no
/// setting at all.
struct LearnedColors {
    var disc = HueTracker()
    var bottle = HueTracker()
    var pole = HueTracker()

    /// Colour matching is only decisive when the disc and the bottles actually
    /// glow *differently*. On a single-colour set both trackers converge on the
    /// same hue, this returns false, and the classifier falls through to
    /// position and motion — which is the right answer, not a degraded one.
    func colorsAreSeparable(tolerance: Double) -> Bool {
        guard let d = disc.hue, let b = bottle.hue else { return false }
        return hueDistance(d, b) > tolerance * 1.5
    }

    var summary: String {
        func text(_ tracker: HueTracker, _ name: String) -> String? {
            guard let hue = tracker.hue else { return nil }
            return "\(name) \(Int(hue))°"
        }
        let parts = [text(disc, "disc"), text(bottle, "bottles"), text(pole, "poles")].compactMap { $0 }
        return parts.isEmpty ? "learning colours" : parts.joined(separator: " · ")
    }
}

/// Decides what each lit blob *is*.
///
/// Two routes, in order of preference:
///   1. Colour — once the app has watched the set long enough to know that the
///      disc and the bottles glow differently, hue matching is decisive and
///      survives crossings and occlusion.
///   2. Geometry and motion — poles come from the detected court, a bottle is
///      only claimed while it sits at its own pole top (a tight radius, which
///      is what stops a disc flying past from being mistaken for it), then
///      tracked loosely as it falls. Whatever is left and moving is the disc.
///
/// Route 2 assumes frame-to-frame continuity, which is exactly what the camera
/// provides at 30fps — and it is also what teaches route 1: every object route
/// 2 identifies confidently becomes a colour sample.
final class GlowClassifier {
    private(set) var colors = LearnedColors()

    var hueTolerance = 32.0
    var minSaturation = 0.22
    var minArea = 0.00015
    var maxArea = 0.09
    var poleAspect = 2.6
    var restRadius = 0.075
    var maxBottleDistance = 0.42
    var colorConfidence = 0.95
    var geometryConfidence = 0.82

    private var memory: [Side: Pt] = [:]
    private var knocked: [Side: Bool] = [.left: false, .right: false]
    private var lastDisc: Pt?

    func reset() {
        memory = [:]
        knocked = [.left: false, .right: false]
        lastDisc = nil
    }

    /// Colours are deliberately *not* cleared on reset — they survive a new
    /// game, a pause, and a re-detected court, because the set on the field did
    /// not change when any of those happened.
    func forgetColors() {
        colors = LearnedColors()
    }

    func classify(blobs: [Blob], court: Court?) -> [Detection] {
        let usable = blobs.filter { $0.area >= minArea && $0.area <= maxArea }

        guard let court else {
            // No court yet. Still emit a best-guess disc so the preview overlay
            // has something to draw and colour learning can begin, but claim
            // nothing about poles or bottles.
            if let disc = pickDisc(usable.filter { !looksLikePole($0, court: nil) }) {
                return [disc]
            }
            return []
        }

        var detections: [Detection] = []

        // Poles always come from the court: they never move, and a lit pole is
        // a long streak that would otherwise swallow the bottle on top.
        for side in [Side.left, .right] {
            let top = court.poleTop(side)
            let base = court.poleBase(side)
            detections.append(Detection(
                label: .pole(side),
                score: geometryConfidence,
                box: Box(x: top.x - 0.012, y: top.y, w: 0.024, h: max(0.02, base.y - top.y))
            ))
        }

        let candidates = usable.filter { !looksLikePole($0, court: court) }
        var used = Set<Int>()

        // --- bottles -------------------------------------------------------
        struct Pair { var side: Side; var index: Int; var cost: Double }
        var pairs: [Pair] = []
        for (index, blob) in candidates.enumerated() {
            if let bottleHue = colors.bottle.hue,
               colors.colorsAreSeparable(tolerance: hueTolerance),
               !matches(blob, bottleHue) { continue }
            for side in [Side.left, .right] {
                let reference = memory[side] ?? court.poleTop(side)
                let radius = (knocked[side] ?? false) ? maxBottleDistance : restRadius
                let cost = distance(blob.box.center, reference)
                if cost <= radius { pairs.append(Pair(side: side, index: index, cost: cost)) }
            }
        }
        pairs.sort { $0.cost < $1.cost }

        var takenSides = Set<Side>()
        for pair in pairs {
            if takenSides.contains(pair.side) || used.contains(pair.index) { continue }
            takenSides.insert(pair.side)
            used.insert(pair.index)
            let blob = candidates[pair.index]

            let onPole = court.isOnPole(pair.side, blob.box)
            // Only a bottle sitting exactly where a bottle sits is trusted
            // enough to define what "bottle colour" means. Once it is knocked
            // and tumbling it could be overlapping anything.
            if onPole { colors.bottle.add(hue: blob.hue, saturation: blob.saturation) }

            memory[pair.side] = onPole ? court.poleTop(pair.side) : blob.box.center
            knocked[pair.side] = !onPole

            detections.append(Detection(
                label: .bottle(pair.side),
                score: colors.bottle.hue != nil ? colorConfidence : geometryConfidence,
                box: blob.box
            ))
        }

        // --- disc ----------------------------------------------------------
        let remaining = candidates.enumerated().filter { !used.contains($0.offset) }.map(\.element)
        if let disc = pickDisc(remaining) {
            detections.append(disc)
        }

        return detections
    }

    // MARK: - Helpers

    private func matches(_ blob: Blob, _ target: Double) -> Bool {
        guard blob.saturation >= minSaturation else { return false }
        return hueDistance(blob.hue, target) <= hueTolerance
    }

    private func looksLikePole(_ blob: Blob, court: Court?) -> Bool {
        let tall = blob.box.aspect >= poleAspect
        if let poleHue = colors.pole.hue, matches(blob, poleHue), tall { return true }
        guard tall else { return false }
        guard let court else { return true }
        let c = blob.box.center
        let nearPole = min(abs(c.x - court.leftTop.x), abs(c.x - court.rightTop.x))
        if nearPole < 0.06 {
            colors.pole.add(hue: blob.hue, saturation: blob.saturation)
            return true
        }
        return false
    }

    private func pickDisc(_ remaining: [Blob]) -> Detection? {
        guard !remaining.isEmpty else { return nil }

        // Colour route: only once the two objects are known to look different.
        if let target = colors.disc.hue, colors.colorsAreSeparable(tolerance: hueTolerance),
           let matched = remaining.filter({ matches($0, target) }).max(by: { $0.brightness < $1.brightness }) {
            lastDisc = matched.box.center
            colors.disc.add(hue: matched.hue, saturation: matched.saturation)
            return Detection(label: .disc, score: colorConfidence, box: matched.box)
        }

        // Geometry route: prefer the blob nearest where the disc was last
        // frame, then the roundest one. Whatever wins teaches the colour
        // tracker, which is how the colour route eventually becomes available.
        guard let best = remaining.min(by: { cost($0) < cost($1) }) else { return nil }
        lastDisc = best.box.center
        colors.disc.add(hue: best.hue, saturation: best.saturation)
        return Detection(label: .disc, score: geometryConfidence, box: best.box)
    }

    private func cost(_ blob: Blob) -> Double {
        let continuity = lastDisc.map { distance(blob.box.center, $0) } ?? 1
        let roundness = abs(1 - blob.box.w / max(blob.box.h, 1e-6))
        return continuity * 2 + roundness
    }
}
