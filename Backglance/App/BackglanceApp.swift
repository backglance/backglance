import SwiftUI

/// Entry point for the Backglance menu bar app.
///
/// The app is an agent (`LSUIElement`): it owns no windows at launch and the real
/// UI hangs off the status item, which `AppDelegate` installs. `Settings` is here
/// only so `App` has a scene; it is replaced by the real settings scene in Phase 3.
@main
struct BackglanceApp: App {
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
