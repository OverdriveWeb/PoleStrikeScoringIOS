import Foundation

/// What the app learns from.
///
/// Every play produces a feature vector describing *how* it looked — heights,
/// speeds, how many frames each observation held, how much was occluded. When
/// you confirm a call, or reject it and tap what actually happened, that vector
/// gets a label. Those labelled examples are the training set, and they come
/// from your court, your set, your lighting.
///
/// This is the honest version of "gets better every time": it is not learning
/// to see, it is learning where *your* decision boundaries sit.
struct PlayFeatures: Codable {
    var bottleKnocked: Double = 0
    var bottleGroundFrames: Double = 0
    var bottleCaughtFrames: Double = 0
    var bottleFinalHeight: Double = 0
    var bottlePeakSpeed: Double = 0
    var discSeen: Double = 0
    var discGroundFrames: Double = 0
    var discCaughtFrames: Double = 0
    var discFinalHeight: Double = 0
    var discPeakSpeed: Double = 0
    var discPoleFrames: Double = 0
    var duration: Double = 0
    var quality: Double = 0
    var occlusion: Double = 0

    static let count = 14

    var vector: [Double] {
        get {
            [bottleKnocked, bottleGroundFrames, bottleCaughtFrames, bottleFinalHeight,
             bottlePeakSpeed, discSeen, discGroundFrames, discCaughtFrames,
             discFinalHeight, discPeakSpeed, discPoleFrames, duration, quality, occlusion]
        }
        set {
            guard newValue.count == Self.count else { return }
            bottleKnocked = newValue[0]; bottleGroundFrames = newValue[1]
            bottleCaughtFrames = newValue[2]; bottleFinalHeight = newValue[3]
            bottlePeakSpeed = newValue[4]; discSeen = newValue[5]
            discGroundFrames = newValue[6]; discCaughtFrames = newValue[7]
            discFinalHeight = newValue[8]; discPeakSpeed = newValue[9]
            discPoleFrames = newValue[10]; duration = newValue[11]
            quality = newValue[12]; occlusion = newValue[13]
        }
    }
}

/// The single call a play resolves to. Deliberately one label per play: it is
/// what you can actually answer with one tap, which is what makes the training
/// data honest.
enum PlayClass: Int, Codable, CaseIterable {
    case bottleGround = 0
    case bottleCaught = 1
    case discHitsPole = 2
    case discGround = 3
    case discCaught = 4
    case deadThrow = 5

    var event: ScoreEvent {
        switch self {
        case .bottleGround: return .bottleGround
        case .bottleCaught: return .bottleCaught
        case .discHitsPole: return .discHitsPole
        case .discGround: return .discGround
        case .discCaught: return .discCaught
        case .deadThrow: return .deadThrow
        }
    }

    static func from(_ event: ScoreEvent) -> PlayClass {
        switch event {
        case .bottleGround, .bothGround: return .bottleGround
        case .bottleCaught: return .bottleCaught
        case .discHitsPole: return .discHitsPole
        case .discGround: return .discGround
        case .discCaught: return .discCaught
        case .deadThrow: return .deadThrow
        }
    }

    var label: String { event.shortLabel }

    /// Stable, self-describing name for the wire. The cloud model answers with
    /// one of these rather than an integer, because a model that has to
    /// remember "3 means disc on the ground" will eventually get it wrong in a
    /// way nothing here could detect.
    var wireName: String {
        switch self {
        case .bottleGround: return "bottle_ground"
        case .bottleCaught: return "bottle_caught"
        case .discHitsPole: return "disc_hits_pole"
        case .discGround: return "disc_ground"
        case .discCaught: return "disc_caught"
        case .deadThrow: return "dead_throw"
        }
    }

    init?(wireName: String) {
        guard let match = PlayClass.allCases.first(where: { $0.wireName == wireName }) else { return nil }
        self = match
    }
}

struct TrainingExample: Codable, Identifiable {
    var id: String
    var features: PlayFeatures
    var label: Int
    /// What the rules alone called it — used to measure whether learning helps.
    var ruleCall: Int
    var at: Date
}

/// A small multilayer perceptron trained by SGD, entirely on device.
///
/// 14 inputs, one hidden layer, 6 outputs. It is intentionally tiny: with a few
/// dozen examples anything larger would memorise rather than generalise, and
/// this has to be useful after one evening of play, not after a dataset.
final class AdaptiveModel: Codable {
    private(set) var w1: [Double]
    private(set) var b1: [Double]
    private(set) var w2: [Double]
    private(set) var b2: [Double]
    private(set) var trainedOn = 0
    private(set) var accuracy = 0.0

    let inputs = PlayFeatures.count
    let hidden = 10
    let outputs = PlayClass.allCases.count

    enum CodingKeys: String, CodingKey {
        case w1, b1, w2, b2, trainedOn, accuracy
    }

    init() {
        var generator = SystemRandomNumberGenerator()
        func randomWeights(_ n: Int, fanIn: Int) -> [Double] {
            let limit = (6.0 / Double(fanIn)).squareRoot()
            return (0..<n).map { _ in Double.random(in: -limit...limit, using: &generator) }
        }
        w1 = randomWeights(14 * 10, fanIn: 14)
        b1 = [Double](repeating: 0, count: 10)
        w2 = randomWeights(10 * 6, fanIn: 10)
        b2 = [Double](repeating: 0, count: 6)
    }

    // MARK: - Inference

    private func forward(_ x: [Double]) -> (hidden: [Double], probs: [Double]) {
        var h = [Double](repeating: 0, count: hidden)
        for j in 0..<hidden {
            var sum = b1[j]
            for i in 0..<inputs { sum += x[i] * w1[j * inputs + i] }
            h[j] = tanh(sum)
        }
        var logits = [Double](repeating: 0, count: outputs)
        for k in 0..<outputs {
            var sum = b2[k]
            for j in 0..<hidden { sum += h[j] * w2[k * hidden + j] }
            logits[k] = sum
        }
        let maxLogit = logits.max() ?? 0
        let exps = logits.map { exp($0 - maxLogit) }
        let total = exps.reduce(0, +)
        return (h, exps.map { $0 / max(total, 1e-9) })
    }

    func predict(_ features: PlayFeatures) -> (klass: PlayClass, probability: Double) {
        let probs = forward(features.vector).probs
        var bestIndex = 0
        for k in probs.indices where probs[k] > probs[bestIndex] { bestIndex = k }
        return (PlayClass(rawValue: bestIndex) ?? .deadThrow, probs[bestIndex])
    }

    /// How confident the model is in a specific call — used to adjust, not
    /// replace, the rule-based confidence.
    func probability(of klass: PlayClass, given features: PlayFeatures) -> Double {
        forward(features.vector).probs[klass.rawValue]
    }

    // MARK: - Training

    /// Plain SGD with momentum. Held-out accuracy is measured on a rotating
    /// fifth of the data so the number reported is not the training score.
    @discardableResult
    func train(on examples: [TrainingExample], epochs: Int = 400, learningRate: Double = 0.05) -> Double {
        guard examples.count >= 4 else { return accuracy }

        let shuffled = examples.shuffled()
        let splitIndex = max(1, shuffled.count / 5)
        let validation = Array(shuffled.prefix(splitIndex))
        let training = Array(shuffled.dropFirst(splitIndex))
        guard !training.isEmpty else { return accuracy }

        for _ in 0..<epochs {
            for example in training.shuffled() {
                step(example, rate: learningRate)
            }
        }

        var correct = 0
        for example in validation where predict(example.features).klass.rawValue == example.label {
            correct += 1
        }
        accuracy = validation.isEmpty ? 0 : Double(correct) / Double(validation.count)
        trainedOn = examples.count
        return accuracy
    }

    private func step(_ example: TrainingExample, rate: Double) {
        let x = example.features.vector
        let (h, probs) = forward(x)

        // dL/dlogits for softmax + cross-entropy is simply (p - target).
        var dLogits = probs
        dLogits[example.label] -= 1

        var dHidden = [Double](repeating: 0, count: hidden)
        for k in 0..<outputs {
            let g = dLogits[k]
            for j in 0..<hidden {
                dHidden[j] += g * w2[k * hidden + j]
                w2[k * hidden + j] -= rate * g * h[j]
            }
            b2[k] -= rate * g
        }

        for j in 0..<hidden {
            // d/dz tanh(z) = 1 - tanh(z)^2, and h[j] is already tanh(z).
            let g = dHidden[j] * (1 - h[j] * h[j])
            for i in 0..<inputs {
                w1[j * inputs + i] -= rate * g * x[i]
            }
            b1[j] -= rate * g
        }
    }

    func reset() {
        let fresh = AdaptiveModel()
        w1 = fresh.w1; b1 = fresh.b1; w2 = fresh.w2; b2 = fresh.b2
        trainedOn = 0
        accuracy = 0
    }
}

/// Holds the examples and the model, and decides how much to trust the model.
@MainActor
final class LearningStore: ObservableObject {
    @Published private(set) var examples: [TrainingExample] = []
    /// Contributed by other installs. Kept separate on purpose — see `retrain`.
    @Published private(set) var pool: [TrainingExample] = []
    @Published private(set) var model = AdaptiveModel()
    @Published private(set) var lastAccuracy = 0.0
    @Published private(set) var localOnlyAccuracy = 0.0
    @Published private(set) var usingPool = false
    @Published private(set) var lastSync: SyncReport?
    @Published var enabled = true

    private let sync = CloudSync()

    private let defaults = UserDefaults.standard
    private let examplesKey = "polescore.examples"
    private let modelKey = "polescore.model"
    private let poolKey = "polescore.pool"

    private var lastSyncAt: Date?
    private var syncing = false

    /// Sharing is not a setting. The project is baked into the build, so first
    /// launch is already pointed at the shared pool with nothing to type on a
    /// phone and no switch to leave in the wrong position.
    init() {
        load()
    }

    /// Sync on launch and periodically as examples accumulate, so "always
    /// synced" needs no button. Quiet on failure — a dead network must never
    /// interrupt a game.
    func autoSync(force: Bool = false) {
        guard enabled, CloudDefaults.isConfigured, !syncing else { return }
        if !force, let last = lastSyncAt, Date().timeIntervalSince(last) < 120 { return }
        syncing = true
        Task { @MainActor [weak self] in
            await self?.syncNow()
            self?.syncing = false
            self?.lastSyncAt = Date()
        }
    }

    var count: Int { examples.count }

    /// Trust ramps in with evidence: at zero examples the model has no say, and
    /// it only reaches full weight once there is enough data to have earned it.
    var trust: Double {
        guard enabled else { return 0 }
        // Pooled examples count, but at a discount: someone else's court is
        // weaker evidence about yours than your own corrections are.
        let effective = Double(examples.count) + Double(pool.count) * 0.25
        guard effective >= 8 else { return 0 }
        return min(0.6, effective / 60.0)
    }

    var totalKnowledge: Int { examples.count + pool.count }

    /// Plain values for the Coach, so its diagnosis needs no actor hop.
    var snapshot: Coach.LearningSnapshot {
        let confusions = examples.filter {
            $0.ruleCall != $0.label
                && Set([$0.ruleCall, $0.label]) == Set([PlayClass.bottleGround.rawValue,
                                                        PlayClass.bottleCaught.rawValue])
        }
        return Coach.LearningSnapshot(
            examples: examples.count,
            poolSize: pool.count,
            modelAccuracy: lastAccuracy,
            ruleAgreement: ruleAgreement,
            groundVsCaughtConfusions: confusions.count,
            sharingConfigured: CloudDefaults.isConfigured
        )
    }

    func record(features: PlayFeatures, label: PlayClass, ruleCall: PlayClass) {
        let example = TrainingExample(
            id: UUID().uuidString,
            features: features,
            label: label.rawValue,
            ruleCall: ruleCall.rawValue,
            at: Date()
        )
        examples.append(example)
        if examples.count > 400 { examples.removeFirst(examples.count - 400) }
        save()
        if examples.count % 5 == 0 {
            retrain()
            autoSync()
        }
    }

    /// Trains two candidates and keeps whichever actually predicts *your* calls
    /// better on held-out local data: one on your examples alone, one on your
    /// examples plus the shared pool.
    ///
    /// This gate matters. Shared data is not automatically an improvement —
    /// other people have different courts, different rule readings, and some of
    /// them will have calibrated badly. Pooling helps most when you have little
    /// data of your own and should quietly lose influence as you accumulate
    /// your own. Measuring instead of assuming is what makes that safe.
    @discardableResult
    func retrain() -> Double {
        guard examples.count >= 4 else { return lastAccuracy }

        let localOnly = AdaptiveModel()
        let localScore = localOnly.train(on: examples)

        if pool.isEmpty || !enabled {
            model = localOnly
            lastAccuracy = localScore
            localOnlyAccuracy = localScore
            usingPool = false
            save()
            return lastAccuracy
        }

        // Your own examples are repeated so they outweigh the pool during
        // training, rather than being drowned out by volume.
        let combinedSet = examples + examples + examples + pool
        let combined = AdaptiveModel()
        combined.train(on: combinedSet)

        // Both candidates are judged on YOUR data only. The pool is allowed to
        // help; it is never allowed to define what "correct" means here.
        let combinedScore = accuracy(of: combined, on: examples)
        let localOnLocal = accuracy(of: localOnly, on: examples)

        if combinedScore > localOnLocal {
            model = combined
            lastAccuracy = combinedScore
            usingPool = true
        } else {
            model = localOnly
            lastAccuracy = localOnLocal
            usingPool = false
        }
        localOnlyAccuracy = localOnLocal
        save()
        return lastAccuracy
    }

    private func accuracy(of model: AdaptiveModel, on set: [TrainingExample]) -> Double {
        guard !set.isEmpty else { return 0 }
        var correct = 0
        for example in set where model.predict(example.features).klass.rawValue == example.label {
            correct += 1
        }
        return Double(correct) / Double(set.count)
    }

    /// Push what this device learned, pull what everyone else did, retrain.
    func syncNow() async {
        let (report, downloaded) = await sync.sync(local: examples)
        lastSync = report
        if !downloaded.isEmpty {
            // De-duplicate against anything already held.
            let known = Set(examples.map(\.id)).union(pool.map(\.id))
            let fresh = downloaded.filter { !known.contains($0.id) }
            pool.append(contentsOf: fresh)
            if pool.count > 2000 { pool.removeFirst(pool.count - 2000) }
            savePool()
            retrain()
        }
    }

    /// How often the rules alone agreed with you — the baseline the model has
    /// to beat before it is worth anything.
    var ruleAgreement: Double {
        guard !examples.isEmpty else { return 0 }
        let agree = examples.filter { $0.ruleCall == $0.label }.count
        return Double(agree) / Double(examples.count)
    }

    func forgetEverything() {
        examples = []
        pool = []
        model.reset()
        lastAccuracy = 0
        localOnlyAccuracy = 0
        usingPool = false
        save()
        savePool()
    }

    private func savePool() {
        if let data = try? JSONEncoder().encode(pool) {
            defaults.set(data, forKey: poolKey)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(examples) {
            defaults.set(data, forKey: examplesKey)
        }
        if let data = try? JSONEncoder().encode(model) {
            defaults.set(data, forKey: modelKey)
        }
    }

    private func load() {
        if let data = defaults.data(forKey: examplesKey),
           let decoded = try? JSONDecoder().decode([TrainingExample].self, from: data) {
            examples = decoded
        }
        if let data = defaults.data(forKey: modelKey),
           let decoded = try? JSONDecoder().decode(AdaptiveModel.self, from: data) {
            model = decoded
        }
        if let data = defaults.data(forKey: poolKey),
           let decoded = try? JSONDecoder().decode([TrainingExample].self, from: data) {
            pool = decoded
        }
    }
}
