import AppKit
import Foundation

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var installing = false
    private var process: Process?
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var stateLabel: NSTextField!
    private var messageLabel: NSTextField!
    private var timer: Timer?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        buildWindow()
        refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshStatus() }
        showWindow()
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "ED"
        statusItem.button?.toolTip = "ExpertDock Helper"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(showWindow)
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ExpertDock Helper"
        window.center()

        let title = NSTextField(labelWithString: "ExpertDock Helper")
        title.font = .boldSystemFont(ofSize: 24)
        stateLabel = NSTextField(labelWithString: "已就绪")
        stateLabel.font = .boldSystemFont(ofSize: 16)
        messageLabel = NSTextField(wrappingLabelWithString: "等待安装请求")
        messageLabel.textColor = .secondaryLabelColor
        let version = NSTextField(labelWithString: "版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")")
        version.textColor = .secondaryLabelColor

        let update = NSButton(title: "检查更新", target: self, action: #selector(checkUpdates))
        let quit = NSButton(title: "退出", target: self, action: #selector(quitApp))
        let buttons = NSStackView(views: [update, quit])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [title, stateLabel, messageLabel, version, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 30),
        ])
    }

    @objc private func showWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func checkUpdates() {
        NSWorkspace.shared.open(URL(string: "https://ed.lorne.top/helper")!)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func refreshStatus() {
        guard let data = try? Data(contentsOf: statusURL()),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        switch status["state"] {
        case "installing": stateLabel.stringValue = "正在安装"
        case "failed": stateLabel.stringValue = "最近安装失败"
        default: stateLabel.stringValue = "已就绪"
        }
        messageLabel.stringValue = status["message"]?.isEmpty == false ? status["message"]! : "等待安装请求"
    }

    private func statusURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ExpertDock/status.json")
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard !installing,
              let rawURL = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              rawURL.hasPrefix("expertdock://install?") else { return }
        installing = true
        showWindow()
        let core = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/expertdock-core")
        let task = Process()
        task.executableURL = core
        task.arguments = [rawURL]
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.installing = false
                self?.process = nil
                self?.refreshStatus()
            }
        }
        do {
            process = task
            try task.run()
        } catch {
            installing = false
            process = nil
            messageLabel?.stringValue = error.localizedDescription
            stateLabel?.stringValue = "启动失败"
        }
    }
}
