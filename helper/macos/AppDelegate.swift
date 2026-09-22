import AppKit
import Foundation

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var receivedURL = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard !self.receivedURL else { return }
            let alert = NSAlert()
            alert.messageText = "ExpertDock Helper 已就绪"
            alert.informativeText = "请返回 ExpertDock 分享页面，点击“安装到 WorkBuddy”。"
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let rawURL = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              rawURL.hasPrefix("expertdock://install?") else {
            return
        }
        receivedURL = true
        let core = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/expertdock-core")
        let process = Process()
        process.executableURL = core
        process.arguments = [rawURL]
        process.terminationHandler = { _ in
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
        do {
            try process.run()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }
}
