import SwiftUI

/// Entry point for the Backglance menu bar app.
///
/// The app is an agent (`LSUIElement`): it owns no windows at launch, and the real UI
/// hangs off the status item that `AppDelegate` installs. The `Settings` scene is here
/// so `App` has a scene to declare and so ⌘, has somewhere to go; the real settings
/// screens land in Phase 3.
@main
struct BackglanceApp: App {
    // MARK: Internal

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }

    // MARK: Private

    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate
}
