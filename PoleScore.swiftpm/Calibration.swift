import Foundation

enum Side: String, Codable {
    case left, right

    var opposite: Side { self == .left ? .right : .left }
}

enum TeamId: String, Codable {
    case A, B

    var other: TeamId { self == .A ? .B : .A }
}

/// The court, as worked out by `CourtDetector` and `DetectionBridge`. Every scoring
/// decision is measured against these positions, which is why the ground line
/// matters so much: it is the line that separates a caught bottle from one on
/// the grass.
///
/// There is no placeholder value on purpose. An earlier version defaulted to a
/// plausible-looking court and gated scoring on a separate "is it calibrated"
/// flag, which meant every code path had to remember to check the flag before
/// trusting the numbers. Now the court is simply optional until it is real, and
/// the compiler enforces what the flag used to ask politely.
struct Court: Codable, Equatable {
    var leftTop: Pt
    var rightTop: Pt
    var leftBase: Pt
    var rightBase: Pt
    var leftBottle: Box
    var rightBottle: Box
    var groundA: Pt
    var groundB: Pt
    var teamASide: Side = .left

    func poleTop(_ side: Side) -> Pt { side == .left ? leftTop : rightTop }
    func poleBase(_ side: Side) -> Pt { side == .left ? leftBase : rightBase }
    func bottleBox(_ side: Side) -> Box { side == .left ? leftBottle : rightBottle }

    /// Generous box around a bottle's resting position on its pole.
    func restZone(_ side: Side) -> Box {
        bottleBox(side).expanded(by: 1.9, pad: 0.012)
    }

    func isOnPole(_ side: Side, _ box: Box) -> Bool {
        restZone(side).contains(box.center)
    }

    /// Positive above the ground line, negative below it.
    func heightAboveGround(_ p: Pt) -> Double {
        lineY(a: groundA, b: groundB, x: p.x) - p.y
    }

    func isAtGround(_ p: Pt, tolerance: Double = 0.035) -> Bool {
        heightAboveGround(p) <= tolerance
    }

    func team(for side: Side) -> TeamId {
        teamASide == side ? .A : .B
    }
}
