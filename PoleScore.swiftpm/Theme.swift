import SwiftUI

/// Built for a phone propped in a backyard after dark: near-black surfaces so
/// the camera preview is the brightest thing on screen, one high-visibility
/// accent, and score numerals that dwarf everything else.
enum Theme {
    static let field = Color(red: 0.047, green: 0.071, blue: 0.055)
    static let panel = Color(red: 0.086, green: 0.129, blue: 0.102)
    static let edge = Color(red: 0.173, green: 0.227, blue: 0.192)
    static let chalk = Color(red: 0.957, green: 0.969, blue: 0.933)
    static let muted = Color(red: 0.576, green: 0.639, blue: 0.600)
    static let disc = Color(red: 1.0, green: 0.831, blue: 0.0)
    static let glass = Color(red: 0.310, green: 0.820, blue: 0.647)
    static let flag = Color(red: 1.0, green: 0.420, blue: 0.173)
    static let alert = Color(red: 1.0, green: 0.302, blue: 0.302)

    static func teamColor(_ team: TeamId) -> Color { team == .A ? disc : glass }
}

struct PanelCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.panel)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.edge, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.bold))
            .kerning(1.6)
            .foregroundStyle(Theme.muted)
    }
}

struct BigButton: View {
    let title: String
    var tone: Tone = .secondary
    var action: () -> Void

    enum Tone { case primary, secondary, danger }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .background(tone == .primary ? Theme.disc : Color.clear)
        .foregroundStyle(tone == .primary ? Theme.field : (tone == .danger ? Theme.flag : Theme.chalk))
        .overlay(
            Capsule().stroke(tone == .primary ? Theme.disc : (tone == .danger ? Theme.flag : Theme.edge), lineWidth: 1.5)
        )
        .clipShape(Capsule())
    }
}
