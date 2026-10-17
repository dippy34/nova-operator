import SwiftUI

/// Nova is portrait, except while Matthew drives the Mac, which rotates to landscape.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientations: UIInterfaceOrientationMask = .portrait
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask { Self.orientations }
    @MainActor static func landscape(_ on: Bool) {
        orientations = on ? .landscape : .portrait
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: on ? .landscapeRight : .portrait)) { _ in }
    }
}

@main
struct NovaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var nova = NovaModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some Scene {
        WindowGroup {
            Group {
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-nova-design=") }) {
                    NovaDesignReview()
                } else {
                    appContent
                }
#else
                appContent
#endif
            }
            .transaction { transaction in
                if reduceMotion { transaction.animation = nil; transaction.disablesAnimations = true }
            }
            .tint(.blue)
            .preferredColorScheme(.dark)
        }
    }
    private var appContent: some View {
        Group {
                if ProcessInfo.processInfo.arguments.contains("-nova-phases") {
                    FacePhasesView()
                } else {
                    ContentView(nova: nova).environmentObject(nova)
                        .onOpenURL { url in
                            _ = nova.applyPairingLink(url.absoluteString)
                        }
                }
        }
    }
}
