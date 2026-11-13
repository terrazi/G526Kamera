import SwiftUI

@main
struct G526CameraDriveApp: App {
    @StateObject private var environment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(environment.session)
                .environmentObject(environment.settings)
                .environmentObject(environment.settingsModel)
                .onOpenURL { environment.session.handleURL($0) }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { environment.appBecameActive() }
                }
        }
    }
}
