import AppKit

/// Host app for the Send to My Bot share extension: shows whether the sender
/// is configured, sends a test, and points at the logs. The real work happens
/// in the share extension and the relay LaunchAgent.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let statusLabel = NSTextField(wrappingLabelWithString: "Checking…")

    private let support = NSHomeDirectory() + "/Library/Application Support/SendToMyBot"
    private let logPath = NSHomeDirectory() + "/Library/Logs/SendToMyBot.log"

    private var script: String { support + "/bot_send.py" }

    /// uv is not on a GUI app's PATH; look where it actually installs.
    private var uv: String? {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
            NSHomeDirectory() + "/.cargo/bin/uv",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let width: CGFloat = 520
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 232))

        let title = NSTextField(labelWithString: "Send to My Bot")
        title.font = .boldSystemFont(ofSize: 17)
        title.frame = NSRect(x: 20, y: 192, width: width - 40, height: 24)
        content.addSubview(title)

        let help = NSTextField(wrappingLabelWithString:
            "Share URLs, text, images and PDFs from any app's share menu — to your Telegram "
            + "chat (as you, not a bot) or straight into the ytq video queue.\n\n"
            + "First-time setup, in Terminal:   send-to-my-bot login")
        help.font = .systemFont(ofSize: 12)
        help.frame = NSRect(x: 20, y: 108, width: width - 40, height: 78)
        content.addSubview(help)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.frame = NSRect(x: 20, y: 56, width: width - 40, height: 40)
        content.addSubview(statusLabel)

        var x: CGFloat = 16
        for (label, action) in [("Refresh", #selector(refreshStatus)),
                                ("Send Test", #selector(sendTest)),
                                ("Open Log", #selector(openLog)),
                                ("Extension Settings", #selector(openExtensionSettings))] {
            let button = NSButton(title: label, target: self, action: action)
            button.bezelStyle = .rounded
            button.sizeToFit()
            button.frame = NSRect(x: x, y: 12, width: max(button.frame.width + 16, 84), height: 32)
            content.addSubview(button)
            x += button.frame.width + 8
        }

        window = NSWindow(contentRect: content.frame,
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Send to My Bot"
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        refreshStatus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc private func refreshStatus() {
        statusLabel.stringValue = "Checking…"
        runSender(["status"]) { ok, output in
            self.statusLabel.stringValue = (ok ? "✅ " : "⚠️ ") + output
        }
    }

    @objc private func sendTest() {
        statusLabel.stringValue = "Sending test message…"
        runSender(["send", "--text", "Test message from the Send to My Bot app"]) { ok, output in
            self.statusLabel.stringValue = (ok ? "✅ " : "⚠️ ") + output
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    @objc private func openExtensionSettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.ExtensionsPreferences")!)
    }

    private func runSender(_ args: [String], completion: @escaping (Bool, String) -> Void) {
        guard let uv else {
            completion(false, "uv not found — install uv (astral.sh/uv)")
            return
        }
        guard FileManager.default.fileExists(atPath: script) else {
            completion(false, "sender not installed — re-run install.sh")
            return
        }
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: uv)
            process.arguments = ["run", self.script] + args
            process.environment = [
                "HOME": NSHomeDirectory(),
                "PATH": NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var ok = false
            var output = ""
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                ok = process.terminationStatus == 0
            } catch {
                output = error.localizedDescription
            }
            let last = output.split(separator: "\n").last.map(String.init) ?? output
            DispatchQueue.main.async { completion(ok, last.isEmpty ? "done" : last) }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
