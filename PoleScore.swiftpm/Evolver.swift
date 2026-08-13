import Foundation

/// The thresholds that decide a call. These are what evolution tunes.
struct TunableConfig: Codable, Equatable {
    var catchHeightMin = 0.08
    var settleSpeedGate = 0.18
    var bottleDisplacement = 0.05
    var restSpeed = 0.06
    var poleProximity = 0.09
    var confirmFrames = 3.0

    static let bounds: [(ClosedRange<Double>)] = [
        0.02...0.25,   // catchHeightMin
        0.05...0.45,   // settleSpeedGate
        0.02...0.14,   // bottleDisplacement
        0.02...0.16,   // restSpeed
        0.04...0.18,   // poleProximity
        2.0...6.0      // confirmFrames
    ]

    var vector: [Double] {
        get { [catchHeightMin, settleSpeedGate, bottleDisplacement, restSpeed, poleProximity, confirmFrames] }
        set {
            catchHeightMin = newValue[0]
            settleSpeedGate = newValue[1]
            bottleDisplacement = newValue[2]
            restSpeed = newValue[3]
            poleProximity = newValue[4]
            confirmFrames = newValue[5]
        }
    }

    func applied(to config: inout MachineConfig) {
        config.catchHeightMin = catchHeightMin
        config.settleSpeedGate = settleSpeedGate
        config.bottleDisplacement = bottleDisplacement
        config.restSpeed = restSpeed
        config.poleProximity = poleProximity
        config.confirmFrames = Int(confirmFrames.rounded())
    }
}

/// Evolutionary tuning of the scoring thresholds.
///
/// Gradient descent is the wrong tool for these: `confirmFrames` is an integer,
/// the decision rules are full of hard comparisons, and there is no derivative
/// to follow. A small mutation-and-selection loop handles all of that, and with
/// a few dozen labelled plays it converges in well under a second.
///
/// Fitness is how often a threshold set reproduces *your* calls on the plays you
/// have already judged.
enum Evolver {

    struct Result {
        var config: TunableConfig
        var accuracyBefore: Double
        var accuracyAfter: Double
        var generations: Int
    }

    /// Replays a play's features through the same comparisons the state machine
    /// makes, so a threshold set can be scored without storing raw video.
    static func classify(_ f: PlayFeatures, with config: TunableConfig) -> PlayClass {
        let confirm = config.confirmFrames

        if f.bottleKnocked > 0.5 {
            let hitGround = f.bottleGroundFrames >= confirm
            let caught = f.bottleCaughtFrames >= confirm
                && f.bottleFinalHeight >= config.catchHeightMin
                && f.bottlePeakSpeed >= config.settleSpeedGate
            if hitGround && !caught { return .bottleGround }
            if caught { return .bottleCaught }
            // Knocked but unresolved: height is the tiebreak, which is exactly
            // the judgement call these thresholds exist to make.
            return f.bottleFinalHeight >= config.catchHeightMin ? .bottleCaught : .bottleGround
        }

        if f.discPoleFrames >= confirm { return .discHitsPole }
        if f.discSeen > 0.5 {
            if f.discGroundFrames >= confirm { return .discGround }
            if f.discCaughtFrames >= confirm
                && f.discFinalHeight >= config.catchHeightMin
                && f.discPeakSpeed >= config.settleSpeedGate { return .discCaught }
        }
        return .deadThrow
    }

    static func accuracy(of config: TunableConfig, on examples: [TrainingExample]) -> Double {
        guard !examples.isEmpty else { return 0 }
        var correct = 0
        for example in examples {
            if classify(example.features, with: config).rawValue == example.label { correct += 1 }
        }
        return Double(correct) / Double(examples.count)
    }

    static func evolve(from start: TunableConfig,
                       examples: [TrainingExample],
                       populationSize: Int = 40,
                       generations: Int = 60) -> Result {
        let before = accuracy(of: start, on: examples)
        guard examples.count >= 8 else {
            return Result(config: start, accuracyBefore: before, accuracyAfter: before, generations: 0)
        }

        var population: [TunableConfig] = [start]
        for _ in 1..<populationSize {
            population.append(mutate(start, rate: 0.35))
        }

        var best = start
        var bestScore = before

        for _ in 0..<generations {
            let scored = population
                .map { (config: $0, score: accuracy(of: $0, on: examples)) }
                .sorted { $0.score > $1.score }

            if let top = scored.first, top.score > bestScore {
                bestScore = top.score
                best = top.config
            }

            // Keep the top quarter, refill by mutating survivors. Elitism keeps
            // the best candidate intact so a generation can never go backwards.
            let survivors = scored.prefix(max(2, populationSize / 4)).map(\.config)
            var next = survivors
            while next.count < populationSize {
                let parent = survivors.randomElement() ?? start
                next.append(mutate(parent, rate: 0.18))
            }
            population = next
        }

        return Result(config: best, accuracyBefore: before, accuracyAfter: bestScore, generations: generations)
    }

    private static func mutate(_ config: TunableConfig, rate: Double) -> TunableConfig {
        var vector = config.vector
        for i in vector.indices {
            guard Double.random(in: 0...1) < 0.6 else { continue }
            let bounds = TunableConfig.bounds[i]
            let span = bounds.upperBound - bounds.lowerBound
            vector[i] = clamp(vector[i] + Double.random(in: -1...1) * span * rate,
                              bounds.lowerBound, bounds.upperBound)
        }
        var mutated = config
        mutated.vector = vector
        return mutated
    }
}
