import Foundation
import SwiftUI

enum ScoringMode: String, Codable, CaseIterable {
    case auto, assist, manual

    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .assist: return "Ask first"
        case .manual: return "Tap only"
        }
    }

    var detail: String {
        switch self {
        case .auto:
            return "Hands off. Every play is called and scored on its own — no prompts, no pauses, "
                 + "nothing to confirm, and no waiting for anyone to put a bottle back before it "
                 + "will carry on watching."
        case .assist:
            return "Every call waits for a tap. Nothing moves the score by itself, and what you tap "
                 + "becomes training data."
        case .manual:
            return "Detection runs for the overlay only. You score with the pad."
        }
    }
}

struct PlayRecord: Identifiable, Codable {
    var id: String
    var banner: String
    var confidence: Double
    var applied: Bool
    var events: [ScoreEvent]
    var thrower: TeamId
    var reasons: [String]
    var at: Date
}

/// Single source of truth for the app. Persists to UserDefaults as JSON, which
/// is plenty for a scoreboard and keeps the whole thing dependency-free.
@MainActor
final class GameStore: ObservableObject {
    @Published var scores = Scores()
    @Published var thrower: TeamId = .A
    @Published var plays: [PlayRecord] = []
    @Published var winner: TeamId?
    @Published var pending: PlayOutcome?
    @Published var undoUntil: Date?
    /// The play awaiting a correction, if you rejected a suggestion.
    @Published var correcting: PlayOutcome?

    @Published var mode: ScoringMode = .auto { didSet { save() } }
    @Published var rules: RuleSet = .beersbee { didSet { save() } }
    @Published var confidence: Double = 0.85 { didSet { save() } }
    @Published var teamAName = "Team A" { didSet { save() } }
    @Published var teamBName = "Team B" { didSet { save() } }
    @Published var showDebug = false { didSet { save() } }
    /// Draw the model's boxes over the live preview.
    @Published var showDetectionOverlay = false { didSet { save() } }
    @Published var tuning = TunableConfig() { didSet { save() } }

    /// Set by the app so corrections become training examples.
    var learning: LearningStore?

    private let defaults = UserDefaults.standard

    init() {
        load()
    }

    func name(_ team: TeamId) -> String { team == .A ? teamAName : teamBName }

    // MARK: - Scoring

    /// Blends the rule-based confidence with the learned model, weighted by how
    /// much evidence the model has actually earned. With no examples the model
    /// has no say at all, so learning can never make day one worse.
    func adjustedConfidence(for outcome: PlayOutcome) -> Double {
        guard let learning, learning.trust > 0 else { return outcome.confidence }
        let modelProbability = learning.model.probability(of: outcome.primaryClass, given: outcome.features)
        let t = learning.trust
        return outcome.confidence * (1 - t) + modelProbability * t
    }

    func handle(outcome: PlayOutcome) {
        var outcome = outcome
        outcome.confidence = adjustedConfidence(for: outcome)
        outcome.needsReview = outcome.confidence < confidence || outcome.events.contains(.deadThrow)

        switch mode {
        case .auto:
            // The whole point of this mode: it does not ask. A low-confidence
            // call is not a reason to stop the game and interrogate somebody
            // standing twenty feet away holding a disc — it is a reason to make
            // the call, leave the undo window open, and get on with it.
            apply(outcome: outcome)

        case .assist:
            pending = outcome

        case .manual:
            break
        }
    }

    /// Confirming a call is agreement, and agreement is a training example just
    /// as much as a correction is.
    func confirm(outcome: PlayOutcome) {
        learning?.record(features: outcome.features, label: outcome.primaryClass, ruleCall: outcome.primaryClass)
        apply(outcome: outcome)
    }

    /// Rejecting opens the correction pad; whatever you tap becomes the label.
    func reject(outcome: PlayOutcome) {
        correcting = outcome
        pending = nil
    }

    func correct(to event: ScoreEvent) {
        guard let outcome = correcting else { return }
        let label = PlayClass.from(event)
        learning?.record(features: outcome.features, label: label, ruleCall: outcome.primaryClass)
        correcting = nil
        if event != .deadThrow {
            var corrected = outcome
            corrected.events = [event]
            apply(outcome: corrected)
        }
    }

    func cancelCorrection() {
        correcting = nil
    }

    func apply(outcome: PlayOutcome) {
        var record = PlayRecord(
            id: outcome.id,
            banner: "",
            confidence: outcome.confidence,
            applied: true,
            events: outcome.events,
            thrower: outcome.thrower,
            reasons: outcome.reasons,
            at: Date()
        )
        record.banner = banner(for: record)
        plays.append(record)
        recompute()
        pending = nil
        undoUntil = Date().addingTimeInterval(8)
        thrower = thrower.other
    }

    func scoreManually(_ event: ScoreEvent) {
        var record = PlayRecord(
            id: "manual_\(UUID().uuidString)",
            banner: "",
            confidence: 1,
            applied: true,
            events: [event],
            thrower: thrower,
            reasons: ["Scored by tap"],
            at: Date()
        )
        record.banner = banner(for: record)
        plays.append(record)
        recompute()
        undoUntil = Date().addingTimeInterval(8)
        thrower = thrower.other
    }

    func discardPending() {
        pending = nil
    }

    func undoLast() {
        guard let last = plays.lastIndex(where: { $0.applied }) else { return }
        plays[last].applied = false
        plays[last].banner += " (undone)"
        recompute()
        undoUntil = nil
        thrower = thrower.other
    }

    func newGame() {
        scores = Scores()
        plays = []
        winner = nil
        pending = nil
        correcting = nil
        undoUntil = nil
        thrower = .A
    }

    private func banner(for record: PlayRecord) -> String {
        RulesEngine.apply(record.events, thrower: record.thrower, to: Scores(), rules: rules).banner
    }

    /// Replay every applied play through the rules. The play list is the record
    /// of what happened; the score is derived from it, never edited directly.
    private func recompute() {
        var running = Scores()
        var champion: TeamId?
        for play in plays where play.applied {
            let result = RulesEngine.apply(play.events, thrower: play.thrower, to: running, rules: rules)
            running = result.scores
            if champion == nil { champion = result.winner }
        }
        scores = running
        winner = champion
    }

    // MARK: - Persistence

    private struct Saved: Codable {
        var mode: ScoringMode
        var rulesId: String
        var confidence: Double
        var teamAName: String
        var teamBName: String
        var showDebug: Bool
        var showDetectionOverlay: Bool?
        var tuning: TunableConfig?
    }

    func save() {
        let saved = Saved(
            mode: mode,
            rulesId: rules.id,
            confidence: confidence,
            teamAName: teamAName,
            teamBName: teamBName,
            showDebug: showDebug,
            showDetectionOverlay: showDetectionOverlay,
            tuning: tuning
        )
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: "polescore.state")
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: "polescore.state"),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        mode = saved.mode
        rules = RuleSet.presets.first { $0.id == saved.rulesId } ?? .beersbee
        confidence = saved.confidence
        teamAName = saved.teamAName
        teamBName = saved.teamBName
        showDebug = saved.showDebug
        showDetectionOverlay = saved.showDetectionOverlay ?? false
        tuning = saved.tuning ?? TunableConfig()
    }
}
