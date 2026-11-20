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
    private static let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    private var installing = false
    private var process: Process?
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var stateLabel: NSTextField!
    private var messageLabel: NSTextField!
    private var statusDot: NSView!
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
        let destination = homeApplications.appendingPathComponent("ExpertDock Helper.app", isDirectory: true)

        // 已在正式目录：清隔离属性、重注册、删旧副本，再逐条清理历史失效记录。
        // 自动更新只替换 bundle，不会修复 LaunchServices；老用户升级后要靠这些
        // 步骤自行恢复，不能假设点一次链接就能被系统分发到新进程。
        if current.deletingLastPathComponent() == homeApplications || current.deletingLastPathComponent() == systemApplications {
            stripQuarantine(at: current)
            registerBundle(at: current)
            removeStaleCopies(excluding: current)
            purgeDeadRegistrationsOnce()
            return false
        }

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

            // copyItem 会把 com.apple.quarantine 一并复制到 ~/Applications。带隔离标记的
            // app 每次启动都会被 App Translocation 到临时只读路径，LaunchServices 随之
            // 堆积同 bundle id 的失效记录，最终 expertdock:// 分发失败（-609）。
            // 因此迁移完成后必须清掉隔离属性，并重新注册正式路径。
            stripQuarantine(at: destination)
            registerBundle(at: destination)
            removeStaleCopies(excluding: destination)

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

    /// 递归清除隔离属性。只对 bundle 根清理不够：可执行文件自身带
    /// com.apple.quarantine 时，Gatekeeper 仍会触发 App Translocation。
    private func stripQuarantine(at url: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? task.run()
        task.waitUntilExit()
    }

    /// 把正式路径写回 LaunchServices，覆盖旧副本和临时路径留下的记录。
    private func registerBundle(at url: URL) {
        runLsregister(["-f", url.path])
    }

    /// 逐条注销已不存在路径的注册记录。
    /// 新版 macOS 上 `lsregister -r -domain user` 是空操作（实测 0.017s 返回、
    /// 一条记录都不清），只能从 -dump 里取死路径再逐条 -u。
    @discardableResult
    private func purgeDeadRegistrations(excluding keep: URL) -> Bool {
        guard let paths = registeredAppPaths() else { return false }
        let keepPath = keep.standardizedFileURL.path
        for path in paths where path != keepPath {
            guard !FileManager.default.fileExists(atPath: path) else { continue }
            runLsregister(["-u", path])
        }
        return true
    }

    /// 只清一次：dump 全库约 25MB / 4 秒 CPU，每次启动都跑代价太大。
    /// 0.9.7 起隔离属性会被清除，不会再产生新的 translocation 记录；
    /// 需要再次清理时走窗口里的“修复唤起”。
    private func purgeDeadRegistrationsOnce() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ExpertDock", isDirectory: true)
        let marker = support.appendingPathComponent(".ls-purge-v1")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let current = Bundle.main.bundleURL.standardizedFileURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let purged = self.purgeDeadRegistrations(excluding: current)
            self.registerBundle(at: current)
            // dump 失败（取不到路径）时不落标记，下次启动重试。
            if purged { try? Data().write(to: marker) }
        }
    }

    /// 从 lsregister -dump 提取本 app 的所有注册路径。
    /// dump 输出约 25MB，重定向到临时文件再解析，避免 Pipe 写满导致死锁。
    /// 返回 nil 表示 dump 失败，调用方不应落“已清理”标记。
    private func registeredAppPaths() -> [String]? {
        let dumpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("expertdock-ls-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: dumpURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: dumpURL) else { return nil }
        defer { try? FileManager.default.removeItem(at: dumpURL) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: Self.lsregisterPath)
        task.arguments = ["-dump"]
        task.standardOutput = handle
        do {
            try task.run()
        } catch {
            try? handle.close()
            return nil
        }
        task.waitUntilExit()
        try? handle.close()

        guard let text = try? String(contentsOf: dumpURL, encoding: .utf8) else { return nil }
        var paths = Set<String>()
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("path:") else { continue }
            var value = String(line.dropFirst("path:".count)).trimmingCharacters(in: .whitespaces)
            if let range = value.range(of: " (0x", options: .backwards) {
                value = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            guard value.hasSuffix("/ExpertDock Helper.app") else { continue }
            paths.insert(value)
        }
        return Array(paths)
    }

    private func runLsregister(_ arguments: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: Self.lsregisterPath)
        task.arguments = arguments
        try? task.run()
        task.waitUntilExit()
    }

    /// 删除下载目录里的旧副本。同 bundle id 的第二份真实副本会让
    /// expertdock:// 的默认处理者解析出现歧义。
    private func removeStaleCopies(excluding destination: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let running = Bundle.main.bundleURL.standardizedFileURL
        let candidates = ["Downloads", "Desktop"].map {
            home.appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent("ExpertDock Helper.app", isDirectory: true)
        }
        for candidate in candidates {
            let path = candidate.standardizedFileURL
            guard path != destination.standardizedFileURL, path != running else { continue }
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            try? FileManager.default.removeItem(at: path)
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
                          styleMask: [.titled, .closable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "ExpertDock Helper"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.moveToActiveSpace]
        // 多显示器环境下 center() 可能把窗口放到副屏甚至屏幕外，
        // 显式放到主屏可见区域的中央。
        if let screen = NSScreen.screens.first {
            let visible = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                          y: visible.midY - size.height / 2))
        }

        let versionText = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let symbol = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: "ExpertDock Helper")?
            .withSymbolConfiguration(symbol)
        icon.contentTintColor = .controlAccentColor

        let title = NSTextField(labelWithString: "ExpertDock Helper")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "菜单栏常驻 · 版本 \(versionText)")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        let titleStack = NSStackView(views: [title, subtitle])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2

        let header = NSStackView(views: [icon, titleStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        statusDot = NSView()
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 10).isActive = true

        stateLabel = NSTextField(labelWithString: "已就绪")
        stateLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        let stateRow = NSStackView(views: [statusDot, stateLabel])
        stateRow.orientation = .horizontal
        stateRow.alignment = .centerY
        stateRow.spacing = 8

        messageLabel = NSTextField(wrappingLabelWithString: "等待安装请求")
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 3
        messageLabel.preferredMaxLayoutWidth = 412

        let statusStack = NSStackView(views: [stateRow, messageLabel])
        statusStack.orientation = .vertical
        statusStack.alignment = .leading
        statusStack.spacing = 6

        let update = NSButton(title: "检查更新", target: self, action: #selector(checkUpdates))
        update.bezelStyle = .rounded
        update.keyEquivalent = "\r"
        let repair = NSButton(title: "修复唤起", target: self, action: #selector(repairLaunchServices))
        repair.bezelStyle = .rounded
        let cleanup = NSButton(title: "清理旧版本", target: self, action: #selector(cleanupOldVersions))
        cleanup.bezelStyle = .rounded
        let quit = NSButton(title: "退出", target: self, action: #selector(quitApp))
        quit.bezelStyle = .inline

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let buttons = NSStackView(views: [update, repair, cleanup, spacer, quit])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let separator = NSBox()
        separator.boxType = .separator

        // 让按钮固定在窗口底部，窗口高度变化时只拉伸中间留白。
        let bodySpacer = NSView()
        bodySpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        bodySpacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)

        let stack = NSStackView(views: [header, separator, statusStack, bodySpacer, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 48),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
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

    @objc private func repairLaunchServices() {
        let alert = NSAlert()
        alert.messageText = "修复 expertdock:// 唤起？"
        alert.informativeText = "将逐条清理旧版本被隔离运行时留下的失效注册记录，并重新注册当前应用。"
        alert.addButton(withTitle: "修复")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        messageLabel.stringValue = "正在清理失效记录…"
        let current = Bundle.main.bundleURL.standardizedFileURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.purgeDeadRegistrations(excluding: current)
            self.registerBundle(at: current)
            DispatchQueue.main.async {
                self.messageLabel.stringValue = "失效记录已清理并重新注册，请回到分享页重新点击安装"
            }
        }
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
        case "installing":
            stateLabel.stringValue = "正在安装"
            statusDot?.layer?.backgroundColor = NSColor.systemBlue.cgColor
        case "failed":
            stateLabel.stringValue = "最近安装失败"
            statusDot?.layer?.backgroundColor = NSColor.systemRed.cgColor
        default:
            stateLabel.stringValue = "已就绪"
            statusDot?.layer?.backgroundColor = NSColor.systemGreen.cgColor
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
