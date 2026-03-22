import AppKit

// MARK: - AppDelegate

// NOTE: To hide from Dock, add LSUIElement = true to Info.plist
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var captureManager: CaptureManager?
    private var statusMenuItem: NSMenuItem?
    private var dataDirMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon programmatically
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        startCapture()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon(for: .stopped)

        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Starting...", action: nil, keyEquivalent: "")
        statusMenuItem?.isEnabled = false
        menu.addItem(statusMenuItem!)

        dataDirMenuItem = NSMenuItem(title: "Data: (none)", action: nil, keyEquivalent: "")
        dataDirMenuItem?.isEnabled = false
        menu.addItem(dataDirMenuItem!)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    private func resolveDataDir() -> String? {
        // 1. Environment variable
        if let envDir = ProcessInfo.processInfo.environment["CHRONIXD_CAPTURE_DATA_DIR"], !envDir.isEmpty {
            return envDir
        }

        // 2. Command line args: --data-dir <path>
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "--data-dir"), idx + 1 < args.count {
            return args[idx + 1]
        }

        // 3. UserDefaults
        if let saved = UserDefaults.standard.string(forKey: "dataDir"), !saved.isEmpty {
            return saved
        }

        return nil
    }

    private func startCapture() {
        guard let dataDir = resolveDataDir() else {
            showDataDirAlert()
            return
        }

        let expandedDir = NSString(string: dataDir).expandingTildeInPath

        dataDirMenuItem?.title = "Data: \(expandedDir)"

        let config = CaptureManager.Config(
            dataDir: expandedDir
        )

        let manager = CaptureManager(config: config)
        self.captureManager = manager

        manager.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.updateIcon(for: state)
                self?.updateStatusText(for: state, interval: config.interval)
            }
        }

        Task { @MainActor in
            do {
                try await manager.start()
            } catch {
                NSLog("[chronixd-capture] Failed to start: %@", "\(error)")
                let alert = NSAlert()
                alert.messageText = "Failed to start capture"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.addButton(withTitle: "Quit")
                alert.runModal()
                NSApp.terminate(nil)
            }
        }
    }

    private func showDataDirAlert() {
        let alert = NSAlert()
        alert.messageText = "No data directory configured"
        alert.informativeText = "Set the CHRONIXD_CAPTURE_DATA_DIR environment variable, pass --data-dir <path>, or enter a path below."
        alert.alertStyle = .warning

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = NSString(string: "~/chronixd-data").expandingTildeInPath
        alert.accessoryView = input

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let path = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                NSApp.terminate(nil)
                return
            }
            UserDefaults.standard.set(path, forKey: "dataDir")
            startCapture()
        } else {
            NSApp.terminate(nil)
        }
    }

    private func updateIcon(for state: CaptureManager.State) {
        let symbolName: String
        switch state {
        case .capturing:
            symbolName = "mic.fill"
        case .muted:
            symbolName = "mic.slash.fill"
        case .stopped:
            symbolName = "stop.fill"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }

    private func updateStatusText(for state: CaptureManager.State, interval: Int) {
        switch state {
        case .capturing:
            statusMenuItem?.title = "Capturing (\(interval)s interval)"
        case .muted:
            statusMenuItem?.title = "Muted (media playing)"
        case .stopped:
            statusMenuItem?.title = "Stopped"
        }
    }

    @objc private func quitApp() {
        captureManager?.stop()
        NSApp.terminate(nil)
    }
}
