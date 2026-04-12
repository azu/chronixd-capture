import AppKit

// MARK: - AppDelegate

// NOTE: To hide from Dock, add LSUIElement = true to Info.plist
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var captureManager: CaptureManager?
    private var statusMenuItem: NSMenuItem?
    private var dataDirMenuItem: NSMenuItem?

    /// Whether capture was running before sleep (used to auto-resume on wake).
    private var wasCapturingBeforeSleep = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        registerSleepWakeNotifications()
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

        let changeDirItem = NSMenuItem(title: "Change Data Directory…", action: #selector(changeDataDir), keyEquivalent: "")
        changeDirItem.target = self
        menu.addItem(changeDirItem)

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
            } catch let error as CaptureManagerError {
                NSLog("[chronixd-capture] Permission error: %@", "\(error)")
                handlePermissionError(error)
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

    // MARK: - Permissions

    private var permissionCheckTimer: Timer?

    private func handlePermissionError(_ error: CaptureManagerError) {
        let settingsURL: String?
        let permissionName: String

        switch error {
        case .accessibilityPermissionDenied:
            permissionName = "Accessibility"
            settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecordingPermissionDenied:
            permissionName = "Screen Recording"
            settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .cameraPermissionDenied:
            permissionName = "Camera"
            settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        default:
            // Non-permission errors (speechNotAvailable, unsupportedLocale, etc.)
            let alert = NSAlert()
            alert.messageText = "Failed to start capture"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        // Open System Settings
        if let urlString = settingsURL, let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }

        updateIcon(for: .stopped)
        statusMenuItem?.title = "Waiting for \(permissionName) permission…"

        // Show alert with retry option
        let alert = NSAlert()
        alert.messageText = "\(permissionName) permission required"
        alert.informativeText = "Grant \(permissionName) permission in System Settings, then click Retry."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            captureManager = nil
            startCapture()
        } else {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Data Directory

    @objc private func changeDataDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Select a data directory for capture storage"

        if let current = UserDefaults.standard.string(forKey: "dataDir") {
            panel.directoryURL = URL(fileURLWithPath: NSString(string: current).expandingTildeInPath)
        }

        // Bring the app to front so the panel is visible
        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let newPath = url.path
        UserDefaults.standard.set(newPath, forKey: "dataDir")

        // Restart capture with new data directory
        captureManager?.stop()
        captureManager = nil
        startCapture()
    }

    // MARK: - Sleep/Wake

    private func registerSleepWakeNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self, selector: #selector(handleSleep),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    @objc private func handleSleep(_ notification: Notification) {
        guard captureManager != nil else { return }
        wasCapturingBeforeSleep = true
        captureManager?.stop()
        captureManager = nil
        updateIcon(for: .stopped)
        statusMenuItem?.title = "Sleeping"
        NSLog("[chronixd-capture] Stopped capture for sleep")
    }

    @objc private func handleWake(_ notification: Notification) {
        guard wasCapturingBeforeSleep else { return }
        wasCapturingBeforeSleep = false
        NSLog("[chronixd-capture] Resuming capture after wake")
        startCapture()
    }

    // MARK: - Actions

    @objc private func quitApp() {
        captureManager?.stop()
        NSApp.terminate(nil)
    }
}
