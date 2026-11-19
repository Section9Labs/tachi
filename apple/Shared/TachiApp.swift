import SwiftUI

@main
struct TachiApp: App {
    var body: some Scene {
        #if os(macOS)
        Window("Tachi", id: "coordinator") {
            CoordinatorView()
        }
        .defaultSize(width: 520, height: 440)
        #else
        WindowGroup {
            CoordinatorView()
        }
        #endif
    }
}
