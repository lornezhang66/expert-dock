import AppKit
import Foundation

@main
struct ExpertDockApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var installing = false
    private var process: Process?
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var stateLabel: NSTextField!
    private var messageLabel: NSTextField!
    private var timer: Timer?
    private var pendingURL: String?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if pendingURL == nil {
            pendingURL = CommandLine.arguments.dropFirst().first { $0.hasPrefix("expertdock://install?") }
        }
        if installInApplicationsIfNeeded() { return }
        buildStatusItem()
        buildWindow()
        refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshStatus() }
        showWindow()
        if let rawURL = pendingURL {
            pendingURL = nil
            startInstall(rawURL)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func installInApplicationsIfNeeded() -> Bool {
        let current = Bundle.main.bundleURL.standardizedFileURL
        let homeApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if current.deletingLastPathComponent() == homeApplications || current.deletingLastPathComponent() == systemApplications { return false }

        let destination = homeApplications.appendingPathComponent("ExpertDock Helper.app", isDirectory: true)
        let staged = homeApplications.appendingPathComponent(".expertdock-install-\(UUID().uuidString).app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            try FileManager.default.createDirectory(at: homeApplications, withIntermediateDirectories: true)
            let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            let installedVersion = Bundle(url: destination)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            if !FileManager.default.fileExists(atPath: destination.path) || installedVersion.compare(currentVersion, options: .numeric) == .orderedAscending {
                try FileManager.default.copyItem(at: current, to: staged)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: staged, to: destination)
            }
            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            launcher.arguments = ["-a", destination.path] + (pendingURL.map { [$0] } ?? [])
            try launcher.run()
            NSApplication.shared.terminate(nil)
            return true
        } catch {
            NSLog("ExpertDock automatic installation failed: %@", error.localizedDescription)
            pendingURL = nil
            return false
        }
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "ED"
        statusItem.button?.toolTip = "ExpertDock Helper"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(showWindow)
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 280), styleMask: [.titled, .closable], backing: .buffered, defer: false)
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
        let cleanup = NSButton(title: "清理旧版本", target: self, action: #selector(cleanupOldVersions))
        let quit = NSButton(title: "退出", target: self, action: #selector(quitApp))
        let buttons = NSStackView(views: [update, cleanup, quit])
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
        guard window != nil else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func checkUpdates() {
        NSWorkspace.shared.open(URL(string: "https://ed.lorne.top/helper")!)
    }

    @objc private func cleanupOldVersions() {
        let alert = NSAlert()
        alert.messageText = "清理旧版 Helper？"
        alert.informativeText = "将把当前用户目录中的其他 ExpertDock Helper 应用移到废纸篓。"
        alert.addButton(withTitle: "清理")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        task.arguments = ["kMDItemCFBundleIdentifier == 'com.expertdock.helper'"]
        task.standardOutput = output
        try? task.run()
        task.waitUntilExit()
        let current = Bundle.main.bundleURL.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.path + "/"
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let paths = String(data: data, encoding: .utf8)?.split(separator: "\n").map(String.init) ?? []
        let oldApps = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }.filter {
            $0 != current && $0.path.hasPrefix(home) && Bundle(url: $0)?.bundleIdentifier == "com.expertdock.helper"
        }
        guard !oldApps.isEmpty else {
            messageLabel.stringValue = "没有发现旧版本"
            return
        }
        NSWorkspace.shared.recycle(oldApps) { [weak self] _, error in
            DispatchQueue.main.async {
                self?.messageLabel.stringValue = error == nil ? "已清理 \(oldApps.count) 个旧版本" : "清理失败：\(error!.localizedDescription)"
            }
        }
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
        guard let rawURL = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              rawURL.hasPrefix("expertdock://install?") else { return }
        if window == nil {
            pendingURL = rawURL
        } else {
            startInstall(rawURL)
        }
    }

    private func startInstall(_ rawURL: String) {
        guard !installing else { return }
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
            messageLabel.stringValue = error.localizedDescription
            stateLabel.stringValue = "启动失败"
        }
    }
}
