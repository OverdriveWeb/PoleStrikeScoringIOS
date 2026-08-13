import Foundation

enum Label: String, Codable, CaseIterable {
    case disc
    case leftPole
    case rightPole
    case leftBottle
    case rightBottle
    case player

    var isBottle: Bool { self == .leftBottle || self == .rightBottle }

    var side: Side? {
        switch self {
        case .leftBottle, .leftPole: return .left
        case .rightBottle, .rightPole: return .right
        default: return nil
        }
    }

    static func bottle(_ side: Side) -> Label { side == .left ? .leftBottle : .rightBottle }
    static func pole(_ side: Side) -> Label { side == .left ? .leftPole : .rightPole }
}

struct Detection {
    var label: Label
    var score: Double
    var box: Box
}

struct Frame {
    var timestamp: Double      // seconds
    var quality: Double        // 0...1
    var detections: [Detection]
}
