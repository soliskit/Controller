import SwiftUI

@main
struct MyApp: App {
    @State private var monitor = ControllerMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(monitor)
        }
    }
}
