import SwiftUI

@main
struct NovaApp: App {
    @StateObject private var nova = NovaModel()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(nova)
                .preferredColorScheme(.dark)
        }
    }
}
