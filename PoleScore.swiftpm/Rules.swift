import Foundation

enum ScoreEvent: String, Codable, CaseIterable {
    case discCaught
    case discGround
    case discHitsPole
    case bottleCaught
    case bottleGround
    case bothGround
    case deadThrow

    var label: String {
        switch self {
        case .discCaught: return "disc caught"
        case .discGround: return "disc hit the ground"
        case .discHitsPole: return "disc hit the pole"
        case .bottleCaught: return "bottle knocked and caught"
        case .bottleGround: return "bottle hit the ground"
        case .bothGround: return "disc and bottle both down"
        case .deadThrow: return "dead throw"
        }
    }

    var shortLabel: String {
        switch self {
        case .discCaught: return "Disc caught"
        case .discGround: return "Disc down"
        case .discHitsPole: return "Pole hit"
        case .bottleCaught: return "Bottle caught"
        case .bottleGround: return "Bottle down"
        case .bothGround: return "Both down"
        case .deadThrow: return "Dead throw"
        }
    }
}

enum Awardee: String, Codable {
    case thrower, defence, none
}

struct EventRule: Codable {
    var points: Int
    var awardedTo: Awardee
}

struct RuleSet: Codable, Identifiable {
    var id: String
    var name: String
    var detail: String
    var winningScore: Int
    var winByTwo: Bool
    var events: [ScoreEvent: EventRule]

    static let beersbee = RuleSet(
        id: "beersbee",
        name: "Beersbee",
        detail: "1 for a pole hit, 2 for a bottle caught, 3 for a bottle down. First to 21, win by two.",
        winningScore: 21,
        winByTwo: true,
        events: [
            .discHitsPole: EventRule(points: 1, awardedTo: .thrower),
            .bottleCaught: EventRule(points: 2, awardedTo: .thrower),
            .bottleGround: EventRule(points: 3, awardedTo: .thrower),
            .bothGround: EventRule(points: 3, awardedTo: .thrower),
            .discGround: EventRule(points: 0, awardedTo: .none),
            .discCaught: EventRule(points: 0, awardedTo: .none),
            .deadThrow: EventRule(points: 0, awardedTo: .none)
        ]
    )

    static let strikePole = RuleSet(
        id: "strike_pole",
        name: "Strike Pole",
        detail: "Same scoring, straight to 21 with no win-by-two.",
        winningScore: 21,
        winByTwo: false,
        events: beersbee.events
    )

    static let tipsyToss = RuleSet(
        id: "tipsy_toss",
        name: "Tipsy Toss",
        detail: "1 for a caught bottle, 2 for a bottle down. Win by two to 15.",
        winningScore: 15,
        winByTwo: true,
        events: [
            .discHitsPole: EventRule(points: 1, awardedTo: .thrower),
            .bottleCaught: EventRule(points: 1, awardedTo: .thrower),
            .bottleGround: EventRule(points: 2, awardedTo: .thrower),
            .bothGround: EventRule(points: 3, awardedTo: .thrower),
            .discGround: EventRule(points: 1, awardedTo: .thrower),
            .discCaught: EventRule(points: 0, awardedTo: .none),
            .deadThrow: EventRule(points: 0, awardedTo: .none)
        ]
    )

    static let presets: [RuleSet] = [.beersbee, .strikePole, .tipsyToss]
}

struct Scores: Codable, Equatable {
    var A: Int = 0
    var B: Int = 0

    subscript(team: TeamId) -> Int {
        get { team == .A ? A : B }
        set { if team == .A { A = newValue } else { B = newValue } }
    }
}

struct ScoreResult {
    var scores: Scores
    var delta: Scores
    var banner: String
    var winner: TeamId?
}

enum RulesEngine {
    /// "Disc and bottle both down" scores once under its own rule rather than
    /// twice under the two rules it is made of.
    static func collapse(_ events: [ScoreEvent], rules: RuleSet) -> [ScoreEvent] {
        var result = Array(Set(events))
        if rules.events[.bothGround] != nil,
           result.contains(.discGround), result.contains(.bottleGround) {
            result.removeAll { $0 == .discGround || $0 == .bottleGround }
            result.append(.bothGround)
        }
        return result
    }

    static func winner(_ scores: Scores, rules: RuleSet) -> TeamId? {
        let leader: TeamId = scores.A >= scores.B ? .A : .B
        let lead = abs(scores.A - scores.B)
        let top = max(scores.A, scores.B)
        guard top >= rules.winningScore, lead > 0 else { return nil }
        if rules.winByTwo && lead < 2 { return nil }
        return leader
    }

    static func apply(_ events: [ScoreEvent], thrower: TeamId, to scores: Scores, rules: RuleSet) -> ScoreResult {
        var next = scores
        var delta = Scores()
        var reasons: [String] = []

        for event in collapse(events, rules: rules) {
            guard let rule = rules.events[event] else { continue }
            let team: TeamId?
            switch rule.awardedTo {
            case .thrower: team = thrower
            case .defence: team = thrower.other
            case .none: team = nil
            }
            if let team, rule.points != 0 {
                next[team] += rule.points
                delta[team] += rule.points
            }
            reasons.append(event.label)
        }

        var parts: [String] = []
        if delta.A > 0 { parts.append("Team A +\(delta.A)") }
        if delta.B > 0 { parts.append("Team B +\(delta.B)") }
        let reasonText = reasons.joined(separator: " + ")
        let banner = parts.isEmpty
            ? "No score — \(reasonText.isEmpty ? "nothing confirmed" : reasonText)"
            : "\(parts.joined(separator: ", ")) — \(reasonText)"

        return ScoreResult(scores: next, delta: delta, banner: banner, winner: winner(next, rules: rules))
    }
}
