import AppKit

@testable import loaf

@main struct UpdateReminderTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let backgroundOnly = Bundle.main.object(forInfoDictionaryKey: "LoafBackgroundOnly") as? Bool == true
        NSApp.setActivationPolicy(backgroundOnly ? .prohibited : .regular)
        Task { @MainActor in
            setbuf(stdout, nil)
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 700, height: 500),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "loaf update reminder fixture"
            if !backgroundOnly {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
            for _ in 0..<30 where !backgroundOnly && !window.isKeyWindow {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard backgroundOnly || window.isKeyWindow else {
                print("FAIL: fixture must be active before checking focus retention")
                exit(1)
            }
            let updates = SoftwareUpdateManager(enabledForTesting: true)
            updates.automaticallyChecksForUpdates = false
            updates.startAfterAgreement()
            updates.checkInBackgroundForTesting()
            for _ in 0..<150 where updates.availableVersion == nil { try? await Task.sleep(for: .milliseconds(100)) }
            guard updates.availableVersion == "99.0" && (backgroundOnly || window.isKeyWindow),
                !NSApp.windows.contains(where: { $0 !== window && $0.isVisible })
            else {
                print(
                    "FAIL: background check must expose a reminder without an alert or stealing focus",
                    updates.availableVersion as Any, NSApp.windows.map { ($0.title, $0.isVisible) })
                exit(1)
            }
            print("CHECK: scheduled update publishes a bottom reminder and retains browser focus")
            updates.automaticallyInstallsUpdates = true
            guard updates.automaticallyChecksForUpdates && UserDefaults.standard.bool(forKey: "SUAutomaticallyUpdate")
            else {
                print("FAIL: automatic installation enables checks and persists")
                exit(1)
            }
            updates.automaticallyChecksForUpdates = false
            guard !updates.automaticallyInstallsUpdates else {
                print("FAIL: disabling checks disables automatic installation")
                exit(1)
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard !updates.automaticallyChecksForUpdates && !updates.automaticallyInstallsUpdates else {
                print("FAIL: queued updater observations must not undo settings toggles")
                exit(1)
            }
            print("CHECK: auto-update settings persist and remain consistent")
            if backgroundOnly {
                print("PASS: background reminder, update settings, and queued preference observations")
                NSApp.terminate(nil)
                return
            }
            for _ in 0..<30 where !updates.canCheckForUpdates { try? await Task.sleep(for: .milliseconds(100)) }
            updates.checkForUpdates()
            for _ in 0..<100 {
                if NSApp.windows.contains(where: { $0 !== window && $0.isVisible && $0.isKeyWindow }) {
                    print("PASS: background reminder, update settings, and explicit update presentation")
                    NSApp.terminate(nil)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            print("FAIL: clicking update reminder must show the update alert")
            exit(1)
        }
        NSApp.run()
    }
}
