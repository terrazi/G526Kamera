import SwiftUI

@main
struct G526CameraDriveApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .onAppear { model.start() }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        model.start()
                    case .background:
                        model.stop()
                    case .inactive:
                        model.restoreScreen()
                    default:
                        break
                    }
                }
        }
    }
}
