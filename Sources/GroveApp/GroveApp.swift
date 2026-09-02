import SwiftUI

@main
struct GroveApp: App {
    @StateObject private var store = GroveStore()

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1260, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("새 회의") {
                    store.isPresentingNewMeeting = true
                }
                .keyboardShortcut("n")

                Button("파일 가져오기…") {
                    store.isPresentingImporter = true
                }
                .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView(store: store)
                .frame(width: 520, height: 360)
        }
    }
}
