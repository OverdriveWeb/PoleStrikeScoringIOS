import Foundation

/// One tracked object across frames. Identity is the whole point: the scoring
/// machine reasons over a track's history, never over a single frame.
struct Track: Identifiable {
    var id: Int
    var label: Label
    var box: Box
    var score: Double
    var vx: Double = 0
    var vy: Double = 0
    var hits: Int = 1
    var missed: Int = 0
    var lastSeen: Double
    var history: [(t: Double, c: Pt)] = []

    var speed: Double { (vx * vx + vy * vy).squareRoot() }

    /// Average speed over the last `window` seconds — steadier than the
    /// instantaneous estimate, which matters when deciding "has it stopped".
    func meanSpeed(window: Double) -> Double {
        guard history.count >= 2, let last = history.last else { return speed }
        var first = history[0]
        for sample in history.reversed() where last.t - sample.t > window {
            first = sample
            break
        }
        let dt = last.t - first.t
        guard dt > 0 else { return speed }
        return distance(last.c, first.c) / dt
    }
}

/// SORT-style tracker: constant-velocity prediction, greedy IoU-then-distance
/// matching, alpha-beta velocity smoothing. Cheap enough to run every frame on
/// the handful of objects a beersbee court contains.
final class Tracker {
    var iouThreshold = 0.15
    var maxDistance = 0.16
    var maxMissed = 10
    var historyLength = 120
    var velocityAlpha = 0.55

    private(set) var tracks: [Track] = []
    private var nextId = 1
    private var lastTimestamp: Double?

    func reset() {
        tracks = []
        nextId = 1
        lastTimestamp = nil
    }

    func best(_ label: Label) -> Track? {
        tracks.filter { $0.label == label }
            .max { ($0.hits, $0.score) < ($1.hits, $1.score) }
    }

    func all(_ label: Label) -> [Track] {
        tracks.filter { $0.label == label }
    }

    @discardableResult
    func update(_ detections: [Detection], timestamp: Double) -> [Track] {
        let dt = lastTimestamp.map { max(0, timestamp - $0) } ?? 0
        lastTimestamp = timestamp

        // Predict forward so a fast disc still matches its own detection.
        let predicted = tracks.map { t -> Box in
            dt <= 0 ? t.box : Box(x: t.box.x + t.vx * dt, y: t.box.y + t.vy * dt, w: t.box.w, h: t.box.h)
        }

        struct Pair { var ti: Int; var di: Int; var cost: Double }
        var pairs: [Pair] = []

        for (ti, track) in tracks.enumerated() {
            for (di, det) in detections.enumerated() where det.label == track.label {
                let overlap = iou(predicted[ti], det.box)
                let dist = distance(predicted[ti].center, det.box.center)
                if overlap >= iouThreshold {
                    pairs.append(Pair(ti: ti, di: di, cost: 1 - overlap))
                } else if dist <= maxDistance {
                    // Distance matches always rank below any real overlap.
                    pairs.append(Pair(ti: ti, di: di, cost: 1 + dist))
                }
            }
        }
        pairs.sort { $0.cost < $1.cost }

        var usedTracks = Set<Int>()
        var usedDets = Set<Int>()
        for pair in pairs {
            if usedTracks.contains(pair.ti) || usedDets.contains(pair.di) { continue }
            usedTracks.insert(pair.ti)
            usedDets.insert(pair.di)
            apply(match: detections[pair.di], to: &tracks[pair.ti], timestamp: timestamp, dt: dt)
        }

        for ti in tracks.indices where !usedTracks.contains(ti) {
            tracks[ti].missed += 1
            // Coast on the motion model so a briefly hidden bottle keeps its id.
            if dt > 0 {
                tracks[ti].box.x += tracks[ti].vx * dt
                tracks[ti].box.y += tracks[ti].vy * dt
            }
        }

        for (di, det) in detections.enumerated() where !usedDets.contains(di) {
            var track = Track(id: nextId, label: det.label, box: det.box, score: det.score, lastSeen: timestamp)
            track.history = [(t: timestamp, c: det.box.center)]
            nextId += 1
            tracks.append(track)
        }

        tracks.removeAll { $0.missed > maxMissed }
        return tracks
    }

    private func apply(match det: Detection, to track: inout Track, timestamp: Double, dt: Double) {
        let prev = track.box.center
        let next = det.box.center
        if dt > 0 {
            track.vx = velocityAlpha * ((next.x - prev.x) / dt) + (1 - velocityAlpha) * track.vx
            track.vy = velocityAlpha * ((next.y - prev.y) / dt) + (1 - velocityAlpha) * track.vy
        }
        track.box = det.box
        track.score = det.score
        track.hits += 1
        track.missed = 0
        track.lastSeen = timestamp
        track.history.append((t: timestamp, c: next))
        if track.history.count > historyLength { track.history.removeFirst() }
    }
}
