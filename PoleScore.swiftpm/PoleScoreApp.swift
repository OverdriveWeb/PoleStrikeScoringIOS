import SwiftUI

@main
struct PoleScoreApp: App {
    @StateObject private var store = GameStore()
    @StateObject private var camera = CameraController()
    @StateObject private var learning = LearningStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .environmentObject(camera)
                .environmentObject(learning)
                .onAppear {
                    store.learning = learning
                    learning.autoSync(force: true)
                }
                .preferredColorScheme(.dark)
                .tint(Theme.disc)
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var store: GameStore
    @EnvironmentObject var camera: CameraController

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prop the phone.").font(.largeTitle.weight(.bold))
                        Text("Throw the disc.").font(.largeTitle.weight(.bold))
                        Text("It keeps score.").font(.largeTitle.weight(.bold)).foregroundStyle(Theme.disc)
                    }
                    .padding(.vertical, 8)

                    if !CameraController.hasCameraUsageDescription {
                        PanelCard {
                            SectionLabel(text: "Setup needed")
                            Text("Camera capability is missing")
                                .font(.headline).foregroundStyle(Theme.flag)
                            Text("In Swift Playgrounds, open App Settings, add the Camera capability with a "
                                 + "description, then run again. Tap-only scoring works without it.")
                                .font(.subheadline).foregroundStyle(Theme.muted)
                        }
                    }

                    PanelCard {
                        SectionLabel(text: "Mode")
                        Text(store.mode.title).font(.headline)
                        Text(store.mode.detail).font(.subheadline).foregroundStyle(Theme.muted)
                    }

                    PanelCard {
                        SectionLabel(text: "Rules")
                        Text(store.rules.name).font(.headline)
                        Text(store.rules.detail).font(.subheadline).foregroundStyle(Theme.muted)
                    }

                    // There is no court setup step any more. The app reads the
                    // court off the field while you are getting ready to throw,
                    // so this card is a status line rather than a task.
                    PanelCard {
                        SectionLabel(text: "Court")
                        Text(camera.courtReady ? "Found it" : "Reads itself when the game starts")
                            .font(.headline)
                        Text(camera.courtReady
                             ? "\(camera.courtSummary). It re-reads itself if the phone moves or you zoom."
                             : "Point the phone so both poles are in shot and press start. It works out "
                               + "where the poles and the ground line are by watching, then keeps "
                               + "checking. Nothing to tap.")
                            .font(.subheadline).foregroundStyle(Theme.muted)
                    }

                    NavigationLink {
                        LiveGameView()
                    } label: {
                        Text("Start game")
                            .font(.headline)
                            .foregroundStyle(Theme.field)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Capsule().fill(Theme.disc))
                    }
                    .buttonStyle(.plain)

                    HStack {
                        NavigationLink("Settings") { SettingsView() }
                        Spacer()
                        NavigationLink("Coach") { CoachView() }
                        Spacer()
                        NavigationLink("History") { HistoryView() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 4)
                }
                .padding(20)
            }
            .background(Theme.field)
            .navigationTitle("PoleScore")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            await camera.requestAccess()
        }
    }
}
