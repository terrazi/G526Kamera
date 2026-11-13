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
                .onAppear { model.appActive() }
                .onOpenURL { model.handleIncomingURL($0) }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        model.appActive()
                    case .inactive:
                        model.restoreScreen()
                    default:
                        // Arka plana geçmek (ör. kestirme çalışırken) taramayı durdurmaz
                        break
                    }
                }
        }
    }
}
