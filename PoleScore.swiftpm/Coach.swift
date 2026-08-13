import Foundation

/// In-app assistant.
///
/// Deliberately not a chatbot. The only model in this app is a YOLO detector
/// pointed at the camera, which answers "what objects are in this frame" and
/// nothing else — a question it can actually answer. This reads what the app
/// measured instead: detector state, object counts, the court estimate, the
/// calls it made, where you disagreed. Every suggestion below is tied to a
/// number the app can see.
struct CoachNote: Identifiable {
    enum Level { case good, warn, bad }
    var id = UUID()
    var level: Level
    var title: String
    var detail: String
}

enum Coach {

    /// Plain snapshot of the learning state. Taking a copy on the main actor and
    /// passing values keeps this function free of any actor isolation.
    struct LearningSnapshot {
        var examples: Int
        var poolSize: Int
        var modelAccuracy: Double
        var ruleAgreement: Double
        var groundVsCaughtConfusions: Int
        var sharingConfigured: Bool
    }

    struct SceneSnapshot {
        var blobCount: Int
        var fps: Double
        var courtReady: Bool
        var courtConfidence: Double
        var courtSummary: String
        var colorSummary: String
        var detectorStatus: DetectorStatus
        var detectionCount: Int
    }

    static func diagnose(scene: SceneSnapshot,
                         mode: ScoringMode,
                         plays: [PlayRecord],
                         learning: LearningSnapshot) -> [CoachNote] {
        var notes: [CoachNote] = []

        // --- the court ------------------------------------------------------
        if !scene.courtReady {
            notes.append(CoachNote(level: .warn, title: "Still reading the court",
                                   detail: "Both poles need to be in shot and lit. It works this out by "
                                         + "watching which bright things stay put, so give it a few "
                                         + "seconds of a still frame — and keep the phone steady."))
        } else if scene.courtConfidence < 0.65 {
            notes.append(CoachNote(level: .warn, title: "Court found, but the ground line is a guess",
                                   detail: "It has the poles but nothing has told it where the grass is yet. "
                                         + "That resolves itself after a couple of throws — whatever "
                                         + "lands and stays put defines the floor. Until then, caught "
                                         + "and grounded bottles may be confused."))
        } else {
            notes.append(CoachNote(level: .good, title: "Court set — \(scene.courtSummary)",
                                   detail: "Confidence \(Int(scene.courtConfidence * 100))%. It re-reads "
                                         + "itself if the phone is bumped or you zoom."))
        }

        // --- what the camera sees -------------------------------------------
        switch scene.blobCount {
        case 0:
            notes.append(CoachNote(level: .bad, title: "Nothing lit is visible",
                                   detail: "Check the set is actually glowing and in frame. The brightness "
                                         + "cut-off adapts on its own, so there is nothing to turn down — "
                                         + "if it sees nothing, there is nothing bright enough to see."))
        case 1...2:
            notes.append(CoachNote(level: .warn, title: "Only \(scene.blobCount) lit object found",
                                   detail: "Expect at least 3 — two bottles and a disc. Move back, or pinch "
                                         + "to zoom out, until both poles are in frame."))
        case 3...8:
            notes.append(CoachNote(level: .good, title: "\(scene.blobCount) lit objects tracked",
                                   detail: "That is the right range for a two-pole court. Colours: \(scene.colorSummary)."))
        default:
            notes.append(CoachNote(level: .warn, title: "\(scene.blobCount) lit objects — too many",
                                   detail: "Stray lights are being picked up. Get porch lights and phone "
                                         + "screens out of frame; zooming in on the court also helps."))
        }

        if scene.fps > 0 && scene.fps < 12 {
            notes.append(CoachNote(level: .warn, title: "Analysing at only \(Int(scene.fps)) fps",
                                   detail: "Low light makes the camera itself slow down. Fast throws may be "
                                         + "missed between frames."))
        }

        switch scene.detectorStatus {
        case .ready:
            notes.append(CoachNote(level: .good, title: "YOLO detector running",
                                   detail: "Objects are recognised directly rather than inferred from "
                                         + "brightness, which is what makes the ground line trustworthy: "
                                         + "the model reports the whole pole, and the bottom of a pole is "
                                         + "the ground. Seeing \(scene.detectionCount) object(s) right now."))
        case .modelMissing:
            notes.append(CoachNote(level: .warn, title: "No YOLO model in the bundle",
                                   detail: "Scoring is running on the glow-brightness detector, which works "
                                         + "but needs the set to be lit and the poles to stay still. Add "
                                         + "GameDetector.mlpackage to the app to switch the model on."))
        case .pausedThermal:
            notes.append(CoachNote(level: .bad, title: "AI paused: device too hot",
                                   detail: "Inference is suspended until the device cools. Scoring carries "
                                         + "on with the glow detector. Get the phone out of direct sun and "
                                         + "off the charger."))
        case .loading:
            notes.append(CoachNote(level: .warn, title: "Detector still loading",
                                   detail: "First launch compiles the model, which takes a few seconds. It "
                                         + "is cached afterwards."))
        case .failed(let reason):
            notes.append(CoachNote(level: .bad, title: "Detector failed",
                                   detail: "\(reason). Scoring has fallen back to the glow detector."))
        case .idle, .pausedBackground:
            notes.append(CoachNote(level: .warn, title: "Detector idle",
                                   detail: "Open the game screen to start inference."))
        }

        // --- what the calls look like ---------------------------------------
        let recent = plays.suffix(20)
        if recent.count >= 5 {
            let dead = recent.filter { $0.events.contains(.deadThrow) }.count
            if Double(dead) / Double(recent.count) > 0.4 {
                notes.append(CoachNote(level: .warn, title: "Many plays resolving as dead throws",
                                       detail: "Usually the disc is not being tracked. If the disc and the "
                                             + "bottles glow the same colour there is nothing to tell them "
                                             + "apart but position — a differently coloured disc is the "
                                             + "single biggest accuracy win available."))
            }
        }

        // --- learning --------------------------------------------------------
        if learning.examples == 0 {
            notes.append(CoachNote(level: .warn, title: "It has not learned anything yet",
                                   detail: "In Automatic mode the cloud review supplies the labels, so this "
                                         + "fills up on its own as you play. In Ask-first mode every "
                                         + "confirmation or correction becomes an example."))
        } else if learning.examples < 8 {
            notes.append(CoachNote(level: .warn, title: "\(learning.examples) examples so far",
                                   detail: "Needs about 8 before the model starts influencing calls, and "
                                         + "around 40 before it carries real weight."))
        } else {
            let rules = Int(learning.ruleAgreement * 100)
            let model = Int(learning.modelAccuracy * 100)
            notes.append(CoachNote(level: model >= rules ? .good : .warn,
                                   title: "Learned model: \(model)% vs rules \(rules)%",
                                   detail: model >= rules
                                   ? "The model now matches the confirmed calls at least as well as the "
                                     + "fixed rules, and is being blended in."
                                   : "The fixed rules still agree more often. Keep playing — or run Tune "
                                     + "thresholds, which often helps faster than the model."))
        }

        // --- the mode you are in ---------------------------------------------
        switch mode {
        case .auto where learning.examples < 15:
            notes.append(CoachNote(level: .warn, title: "Automatic mode with little history",
                                   detail: "It will score on its own before it has learned this court. "
                                         + "Automatic mode never asks you anything, so it also never "
                                         + "collects a correction — play a game in Ask-first if you "
                                         + "want it to learn your calls."))
        case .auto:
            notes.append(CoachNote(level: .good, title: "Automatic mode",
                                   detail: "Nothing will interrupt you. Calls apply on their own with an "
                                         + "undo window, and no play ever waits on a tap."))
        case .assist:
            notes.append(CoachNote(level: .good, title: "Ask-first mode",
                                   detail: "Every call waits for a tap, and every tap is a training example. "
                                         + "This is the fastest way to teach it your court."))
        case .manual:
            notes.append(CoachNote(level: .warn, title: "Tap-only mode",
                                   detail: "The camera is running for the overlay but is not scoring. Switch "
                                         + "to Automatic or Ask-first to use any of it."))
        }

        // --- the disagreements that matter ------------------------------------
        if learning.groundVsCaughtConfusions >= 3 {
            notes.append(CoachNote(level: .bad, title: "Confusing caught bottles with grounded ones",
                                   detail: "That is almost always the ground line sitting too high. It "
                                         + "corrects itself as more throws land, but tapping Re-read the "
                                         + "court with the poles clearly in shot fixes it faster — it is "
                                         + "the measurement worth exactly one point per play."))
        }

        return notes
    }

    /// Plain-language explanation of a single call, from the evidence recorded
    /// at the time — not a guess after the fact.
    static func explain(_ play: PlayRecord) -> String {
        var lines = ["Called: \(play.banner)", "Confidence: \(Int(play.confidence * 100))%"]
        lines.append(contentsOf: play.reasons.map { "· \($0)" })
        if !play.applied {
            lines.append("This one did not change the score.")
        }
        return lines.joined(separator: "\n")
    }

    struct Question: Identifiable {
        var id: String { question }
        let question: String
        let answer: String
    }

    static let questions: [Question] = [
        Question(question: "Do I have to set the court up?",
                 answer: "No. With the YOLO model loaded it recognises the poles directly and takes "
                       + "the ground line from where they meet the grass — one frame, no waiting. "
                       + "Without the model it falls back to watching which bright things stay still "
                       + "and where thrown objects come to rest. Move the phone or zoom and it starts "
                       + "over by itself."),
        Question(question: "What is the difference between the modes?",
                 answer: "Automatic never interrupts you: it calls every play, scores it, and if the cloud "
                       + "review disagrees it silently corrects the call inside the undo window. Ask-first "
                       + "waits for a tap on every play and turns your answer into training data. Tap-only "
                       + "ignores the camera for scoring and gives you buttons."),
        Question(question: "Why did it score 2 instead of 3?",
                 answer: "It decided the bottle was caught rather than grounded. A catch means the bottle "
                       + "stopped moving above the detected ground line. If that keeps being wrong the "
                       + "ground line is too high — Re-read the court, or play a few more throws so it can "
                       + "learn the floor from where things land."),
        Question(question: "Can I zoom in?",
                 answer: "Pinch anywhere on the game screen, exactly like the camera app; double-tap snaps "
                       + "between 1× and 2×. Zooming changes every measurement in the frame, so the court "
                       + "is re-read automatically straight afterwards."),
        Question(question: "Does any of this cost money, or need a network?",
                 answer: "No to both. Object detection is a YOLO model running on this device's neural "
                       + "engine, and scoring is local. Nothing is uploaded, no AI service is called, and "
                       + "it works in a field with no signal. The only network traffic is the "
                       + "shared-learning pool, which sends fourteen numbers per play and nothing else."),
        Question(question: "It missed the throw entirely.",
                 answer: "A play can start two ways: the disc being tracked at speed, or a bottle leaving a "
                       + "pole top. If neither registered, the disc is probably not being detected — check "
                       + "the lit count on the game screen while holding the disc up.")
    ]
}
