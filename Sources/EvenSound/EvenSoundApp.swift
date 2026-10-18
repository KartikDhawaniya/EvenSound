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

@main
struct EvenSoundApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AudioController()

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
            Image(systemName: controller.isActive ? "waveform" : "waveform.slash")
        }
        .menuBarExtraStyle(.window)
    }
}
