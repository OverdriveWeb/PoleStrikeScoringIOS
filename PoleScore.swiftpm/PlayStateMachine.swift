import Foundation

enum PlayState: String {
    case idle, inFlight, interaction, cooldown, resetBottle, cameraMoved
}

enum StatusBadge: String {
    case watching, trackingDisc, scoringPlay, lowConfidence, resetBottle, paused

    var text: String {
        switch self {
        case .watching: return "Watching"
        case .trackingDisc: return "Tracking disc"
        case .scoringPlay: return "Scoring play"
        case .lowConfidence: return "Low confidence"
        case .resetBottle: return "Reset bottle"
        case .paused: return "Paused"
        }
    }
}

struct MachineConfig {
    var throwSpeed = 0.35
    var restSpeed = 0.06
    var confirmFrames = 3
    var poleProximity = 0.09
    var possessionRadius = 0.12
    var bottleDisplacement = 0.05
    var maxPlaySeconds = 6.0
    var cooldownSeconds = 1.5
    var confidenceThreshold = 0.85
    var requireBottleReset = true
    /// Automatic mode sets this. Waiting for a knocked bottle to be put back is
    /// correct — you genuinely cannot throw at an empty pole — but *asking*
    /// about it is not, and neither is refusing to score until someone taps a
    /// button. With this on, the wait clears the moment the bottle is seen back
    /// on the pole, and gives up on its own after `bottleResetTimeout` if the
    /// bottle is out of shot behind a pole or somebody's leg.
    var autoResumeBottleReset = false
    var bottleResetTimeout = 6.0
    /// A bottle track must show this much recent speed before "it's not in
    /// its rest zone" is allowed to mean "it got knocked off." Position alone
    /// isn't evidence of a throw — a lit object that has simply always been
    /// sitting somewhere outside the tiny rest zone reads as displaced from
    /// frame one, with a track speed of ~0 forever, since nothing ever moved
    /// it. Real bottles arrive there by getting hit, which shows up as speed.
    var bottleMotionFloor = 0.10
    /// A catch is motion *followed by* stillness. Without this gate the first
    /// moments of a bottle toppling read as "high up and barely moving", which
    /// is indistinguishable from a catch — and scores 2 instead of 3.
    var settleSpeedGate = 0.18
    /// Height above the ground line that counts as "someone is holding it".
    /// This is what makes catch detection work on a dark field, where there are
    /// no visible players at all.
    var catchHeightMin = 0.08
    /// Resolve a play from the bottle alone when the disc is never tracked.
    var allowMissingDisc = true
}

enum FirstDown: String {
    case disc, bottle
}

struct PlayOutcome {
    var id: String
    var events: [ScoreEvent]
    var thrower: TeamId
    var confidence: Double
    var needsReview: Bool
    var reasons: [String]
    var firstDown: FirstDown?
    /// How the play looked, for the learning store.
    var features: PlayFeatures
    /// The single call this resolves to — one label per play is what you can
    /// answer with one tap.
    var primaryClass: PlayClass
}

struct MachineOutput {
    var state: PlayState
    var status: StatusBadge
    var outcome: PlayOutcome?
    var notice: String?
}

/// Temporal event machine. Nothing fires on a single frame: every observation
/// must hold for `confirmFrames` consecutive frames, and a play must fully
/// resolve before a score is decided. A play that never resolves times out as a
/// dead throw rather than guessing.
final class PlayStateMachine {
    var config = MachineConfig()

    /// Applied by the evolutionary tuner after it learns from your corrections.
    func applyTuning(_ tuning: TunableConfig) {
        tuning.applied(to: &config)
    }

    private(set) var state: PlayState = .idle
    private var playId = 0
    private var startedAt: Double = 0
    private var cooldownUntil: Double = 0
    private var resetStartedAt: Double = 0
    private var throwSide: Side = .left
    private var targetSide: Side?
    private var bottleOffPole: Side?
    private var discSeen = false

    private struct Counter {
        var count = 0
        var best = 0.0
        mutating func hit(_ score: Double) {
            count += 1
            best = max(best, score)
        }
    }

    private var discCaught = Counter()
    private var discGround = Counter()
    private var discPole = Counter()
    private var bottleKnocked = Counter()
    private var bottleCaught = Counter()
    private var bottleGround = Counter()
    private var throwing = Counter()

    private var discPeak = 0.0
    private var bottlePeak: [Side: Double] = [.left: 0, .right: 0]
    private var discFinalHeight = 0.0
    private var bottleFinalHeight = 0.0
    private var discGroundAt: Double?
    private var bottleGroundAt: Double?
    private var qualitySum = 0.0
    private var qualityFrames = 0
    private var occludedFrames = 0
    private var reasons: [String] = []

    func reset() {
        state = .idle
        bottleOffPole = nil
        resetPlay()
    }

    func confirmBottleReset() {
        bottleOffPole = nil
        if state == .resetBottle { state = .idle }
    }

    func update(tracks: [Track], court: Court, timestamp: Double, quality: Double) -> MachineOutput {
        let disc = tracks.first { $0.label == .disc }
        let bottles: [Side: Track?] = [
            .left: tracks.first { $0.label == .leftBottle },
            .right: tracks.first { $0.label == .rightBottle }
        ]
        let players = tracks.filter { $0.label == .player }

        if state == .cooldown {
            if timestamp >= cooldownUntil {
                if bottleOffPole != nil && config.requireBottleReset {
                    state = .resetBottle
                    resetStartedAt = timestamp
                } else {
                    state = .idle
                }
            }
            return MachineOutput(state: state, status: state == .resetBottle ? .resetBottle : .watching, outcome: nil, notice: nil)
        }

        if state == .resetBottle {
            if let side = bottleOffPole, let bottle = bottles[side] ?? nil, court.isOnPole(side, bottle.box) {
                bottleOffPole = nil
                state = .idle
            } else if bottleOffPole == nil {
                state = .idle
            } else if config.autoResumeBottleReset,
                      timestamp - resetStartedAt >= config.bottleResetTimeout {
                // Nobody is going to tap anything in Automatic mode, and a
                // bottle that cannot be seen is not evidence that the game has
                // stopped. Assume it was put back and carry on watching.
                bottleOffPole = nil
                state = .idle
            } else {
                return MachineOutput(state: state, status: .resetBottle, outcome: nil,
                                     notice: config.autoResumeBottleReset
                                         ? "Waiting for the bottle to go back on the pole."
                                         : "Put the bottle back on the pole to start the next throw.")
            }
        }

        qualitySum += quality
        qualityFrames += 1

        switch state {
        case .idle:
            return watchForThrow(disc: disc, bottles: bottles, court: court, timestamp: timestamp)
        case .inFlight, .interaction:
            return observe(disc: disc, bottles: bottles, players: players, court: court, timestamp: timestamp)
        default:
            return MachineOutput(state: state, status: .watching, outcome: nil, notice: nil)
        }
    }

    // MARK: - States

    private func watchForThrow(disc: Track?, bottles: [Side: Track?], court: Court, timestamp: Double) -> MachineOutput {
        // Bottle-triggered start. A glowing disc is not always tracked in
        // flight, but a bottle leaving the top of a pole is unmistakable — and
        // it is the event worth the most points.
        if config.allowMissingDisc {
            for side in [Side.left, .right] {
                guard let bottle = bottles[side] ?? nil else { continue }
                let drift = distance(bottle.box.center, court.poleTop(side))
                guard !court.isOnPole(side, bottle.box),
                      drift >= config.bottleDisplacement,
                      bottle.meanSpeed(window: 0.3) >= config.bottleMotionFloor else { continue }

                throwing.hit(bottle.score)
                if throwing.count < config.confirmFrames {
                    return MachineOutput(state: state, status: .trackingDisc, outcome: nil, notice: nil)
                }
                resetPlay()
                playId += 1
                startedAt = timestamp
                // You throw at the far pole, so the thrower is on the other side.
                throwSide = side.opposite
                targetSide = side
                bottleKnocked.count = config.confirmFrames
                bottleKnocked.best = bottle.score
                state = .interaction
                reasons.append("Bottle left the \(side.rawValue) pole.")
                return MachineOutput(state: state, status: .scoringPlay, outcome: nil, notice: nil)
            }
        }

        guard let disc, disc.hits >= 2, disc.meanSpeed(window: 0.25) >= config.throwSpeed else {
            throwing = Counter()
            return MachineOutput(state: state, status: .watching, outcome: nil, notice: nil)
        }

        throwing.hit(disc.score)
        if throwing.count < config.confirmFrames {
            return MachineOutput(state: state, status: .trackingDisc, outcome: nil, notice: nil)
        }

        let origin = disc.history.first?.c ?? disc.box.center
        resetPlay()
        playId += 1
        startedAt = timestamp
        throwSide = origin.x < 0.5 ? .left : .right
        state = .inFlight
        reasons.append("Throw detected from the \(throwSide.rawValue).")
        return MachineOutput(state: state, status: .trackingDisc, outcome: nil, notice: nil)
    }

    private func observe(disc: Track?, bottles: [Side: Track?], players: [Track], court: Court, timestamp: Double) -> MachineOutput {
        if let disc {
            discSeen = true
            discPeak = max(discPeak, disc.meanSpeed(window: 0.15))
            let c = disc.box.center

            let nearest: Side = distance(c, court.leftTop) <= distance(c, court.rightTop) ? .left : .right
            if distance(c, court.poleTop(nearest)) <= config.poleProximity {
                targetSide = targetSide ?? nearest
                discPole.hit(disc.score)
                if state == .inFlight { state = .interaction }
            }

            discFinalHeight = court.heightAboveGround(c)
            let slow = disc.meanSpeed(window: 0.2) <= config.restSpeed && discPeak >= config.settleSpeedGate
            if court.isAtGround(c) {
                discGround.hit(disc.score)
                if discGroundAt == nil && discGround.count >= config.confirmFrames { discGroundAt = timestamp }
            } else if slow && isCatch(c, players: players, court: court) {
                discCaught.hit(disc.score)
            }
        } else {
            occludedFrames += 1
        }

        for side in [Side.left, .right] {
            guard let bottle = bottles[side] ?? nil else { continue }
            let c = bottle.box.center
            bottlePeak[side] = max(bottlePeak[side] ?? 0, bottle.meanSpeed(window: 0.15))

            if !court.isOnPole(side, bottle.box),
               distance(c, court.poleTop(side)) >= config.bottleDisplacement,
               bottle.meanSpeed(window: 0.3) >= config.bottleMotionFloor || bottleKnocked.count > 0 {
                bottleKnocked.hit(bottle.score)
                targetSide = targetSide ?? side
                if state == .inFlight { state = .interaction }
            }

            bottleFinalHeight = court.heightAboveGround(c)
            guard bottleKnocked.count >= config.confirmFrames else { continue }

            if court.isAtGround(c) {
                bottleGround.hit(bottle.score)
                if bottleGroundAt == nil && bottleGround.count >= config.confirmFrames { bottleGroundAt = timestamp }
            } else if bottle.meanSpeed(window: 0.2) <= config.restSpeed,
                      (bottlePeak[side] ?? 0) >= config.settleSpeedGate,
                      isCatch(c, players: players, court: court) {
                bottleCaught.hit(bottle.score)
            }
        }

        let timedOut = timestamp - startedAt >= config.maxPlaySeconds
        if !resolved() && !timedOut {
            return MachineOutput(state: state, status: state == .interaction ? .scoringPlay : .trackingDisc, outcome: nil, notice: nil)
        }
        return decide(timestamp: timestamp, timedOut: timedOut, court: court)
    }

    private func decide(timestamp: Double, timedOut: Bool, court: Court) -> MachineOutput {
        var events: [ScoreEvent] = []
        var evidence: [Double] = []

        if confirmed(bottleKnocked) {
            if confirmed(bottleGround) {
                events.append(.bottleGround)
                evidence.append(contentsOf: [bottleGround.best, bottleKnocked.best])
                reasons.append("Bottle left the pole and reached the ground line.")
            } else if confirmed(bottleCaught) {
                events.append(.bottleCaught)
                evidence.append(contentsOf: [bottleCaught.best, bottleKnocked.best])
                reasons.append("Bottle left the pole and stopped above the ground — caught.")
            } else {
                reasons.append("Bottle left the pole but the outcome was never confirmed.")
            }
            bottleOffPole = targetSide
        } else if confirmed(discPole) {
            events.append(.discHitsPole)
            evidence.append(discPole.best)
            reasons.append("Disc passed the pole without moving the bottle.")
        }

        let discUsable = discSeen || !config.allowMissingDisc
        if !discUsable {
            reasons.append("No disc track in this play — scored from the bottle only.")
        } else if confirmed(discGround) {
            events.append(.discGround)
            evidence.append(discGround.best)
            reasons.append("Disc came to rest at the ground line.")
        } else if confirmed(discCaught) {
            events.append(.discCaught)
            evidence.append(discCaught.best)
            reasons.append("Disc stopped above the ground line — caught.")
        }

        if events.isEmpty {
            events.append(.deadThrow)
            reasons.append(timedOut ? "Play timed out with no confirmed outcome." : "No scoring condition confirmed.")
        }

        let features = PlayFeatures(
            bottleKnocked: confirmed(bottleKnocked) ? 1 : 0,
            bottleGroundFrames: Double(bottleGround.count),
            bottleCaughtFrames: Double(bottleCaught.count),
            bottleFinalHeight: bottleFinalHeight,
            bottlePeakSpeed: max(bottlePeak[.left] ?? 0, bottlePeak[.right] ?? 0),
            discSeen: discSeen ? 1 : 0,
            discGroundFrames: Double(discGround.count),
            discCaughtFrames: Double(discCaught.count),
            discFinalHeight: discFinalHeight,
            discPeakSpeed: discPeak,
            discPoleFrames: Double(discPole.count),
            duration: timestamp - startedAt,
            quality: qualityFrames > 0 ? qualitySum / Double(qualityFrames) : 0.5,
            occlusion: Double(occludedFrames) / Double(max(1, qualityFrames))
        )

        let confidence = score(evidence: evidence, timedOut: timedOut)
        let outcome = PlayOutcome(
            id: "play_\(playId)_\(Int(startedAt * 1000))",
            events: events,
            thrower: court.team(for: throwSide),
            confidence: confidence,
            needsReview: confidence < config.confidenceThreshold || events.contains(.deadThrow),
            reasons: reasons,
            firstDown: firstDown(),
            features: features,
            primaryClass: PlayClass.from(events.first ?? .deadThrow)
        )

        cooldownUntil = timestamp + config.cooldownSeconds
        state = .cooldown
        resetPlay()
        return MachineOutput(state: state, status: outcome.needsReview ? .lowConfidence : .scoringPlay, outcome: outcome, notice: nil)
    }

    // MARK: - Helpers

    /// A catch is an object that stopped somewhere it could only be if someone
    /// is holding it: inside a player, or clearly off the ground.
    private func isCatch(_ p: Pt, players: [Track], court: Court) -> Bool {
        for player in players {
            let zone = player.box.expanded(by: 1.15, pad: config.possessionRadius * 0.35)
            if zone.contains(p) || distance(p, player.box.center) <= config.possessionRadius { return true }
        }
        return court.heightAboveGround(p) >= config.catchHeightMin
    }

    private func confirmed(_ counter: Counter) -> Bool { counter.count >= config.confirmFrames }

    private func resolved() -> Bool {
        let discTrackable = discSeen || !config.allowMissingDisc
        let discDone = !discTrackable || confirmed(discGround) || confirmed(discCaught)
        guard confirmed(bottleKnocked) else { return discTrackable && discDone }
        return discDone && (confirmed(bottleGround) || confirmed(bottleCaught))
    }

    /// Which object reached the ground first, when both did. Some house rules
    /// care about the order, so it is recorded rather than inferred later.
    private func firstDown() -> FirstDown? {
        switch (discGroundAt, bottleGroundAt) {
        case (nil, nil): return nil
        case (nil, _): return .bottle
        case (_, nil): return .disc
        case let (d?, b?): return d <= b ? .disc : .bottle
        }
    }

    private func score(evidence: [Double], timedOut: Bool) -> Double {
        guard !evidence.isEmpty else { return 0.2 }
        let meanEvidence = evidence.reduce(0, +) / Double(evidence.count)
        let meanQuality = qualityFrames > 0 ? qualitySum / Double(qualityFrames) : 0.5
        let occlusion = clamp(1 - Double(occludedFrames) / Double(max(1, qualityFrames)), 0.4, 1)
        let timeout = timedOut ? 0.6 : 1.0
        return clamp(meanEvidence * (0.65 + 0.35 * meanQuality) * occlusion * timeout, 0, 1)
    }

    private func resetPlay() {
        discCaught = Counter(); discGround = Counter(); discPole = Counter()
        bottleKnocked = Counter(); bottleCaught = Counter(); bottleGround = Counter()
        throwing = Counter()
        discPeak = 0
        bottlePeak = [.left: 0, .right: 0]
        discGroundAt = nil
        bottleGroundAt = nil
        discFinalHeight = 0
        bottleFinalHeight = 0
        qualitySum = 0
        qualityFrames = 0
        occludedFrames = 0
        reasons = []
        targetSide = nil
        discSeen = false
    }
}
