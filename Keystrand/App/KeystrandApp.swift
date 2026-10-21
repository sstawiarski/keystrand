import AppShell
import SwiftUI

@main
struct KeystrandApp: App {
    @NSApplicationDelegateAdaptor(AppShellDelegate.self) private var appDelegate

    var body: some Scene {
        RootScene()
    }
}
