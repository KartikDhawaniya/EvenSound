import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current }
        if let existing = others.first {
            existing.activate()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { onTerminate?() }
}

private struct MenuBarIcon: View {
    @ObservedObject var controller: AudioController

    var body: some View {
        Image(systemName: controller.isActive ? "waveform" : "waveform.slash")
    }
}

@main
struct EvenSoundApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Deliberately not observed here: if the app scene re-renders on every meter update, the window's
    // TabView is rebuilt 10 times a second and SwiftUI keeps the discarded tab items, so memory grows without bound.
    @State private var controller = AudioController()

    var body: some Scene {
        Window("EvenSound", id: "main") {
            MainView()
                .environmentObject(controller)
                .onAppear { appDelegate.onTerminate = { [controller] in MainActor.assumeIsolated { controller.shutdown() } } }
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarView().environmentObject(controller)
        } label: {
            MenuBarIcon(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}
