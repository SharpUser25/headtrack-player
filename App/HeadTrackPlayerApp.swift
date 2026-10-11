import SwiftUI

@main
struct HeadTrackPlayerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("HeadTrack Player", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 520, minHeight: 640)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.openFile() }
                    .keyboardShortcut("o")
            }
        }
    }
}
