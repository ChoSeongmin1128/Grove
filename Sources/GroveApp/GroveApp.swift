import SwiftUI

@main
struct GroveApp: App {
    @StateObject private var store = GroveStore()

    init() {
        GroveTypography.registerFonts()
    }

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
                .disabled(store.isBusy)

                Button("파일 가져오기…") {
                    store.isPresentingImporter = true
                }
                .keyboardShortcut("o")
                .disabled(store.isBusy)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Grove 종료") {
                    Task {
                        if await store.prepareToQuit() { NSApplication.shared.terminate(nil) }
                    }
                }.keyboardShortcut("q")
            }
        }

        Settings {
            SettingsView(store: store)
                .frame(width: 520, height: 460)
        }
    }
}
