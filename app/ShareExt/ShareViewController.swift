import AppKit
import UniformTypeIdentifiers

/// Share-sheet UI: an optional message, a destination picker, and nothing else
/// in the way. Return sends and dismisses immediately; the actual delivery is
/// done out-of-process by the relay LaunchAgent (this extension is sandboxed
/// and cannot reach the network or exec CLIs itself).
///
/// Keys:  ⏎ send · ⎋ cancel · ⌘1 Telegram · ⌘2 ytq · ⇥ into the buttons
final class ShareViewController: NSViewController {

    private enum Destination: Int {
        case telegram = 0, ytq = 1
        var jobValue: String { self == .ytq ? "ytq" : "telegram" }
    }

    // Inside the sandbox, NSHomeDirectory() is the container's Data dir.
    private let queueDir = NSHomeDirectory() + "/queue"

    private let summaryLabel = NSTextField(labelWithString: "Reading shared item…")
    private let messageField = NSTextField()
    private let destPicker = NSSegmentedControl(
        labels: ["Telegram", "ytq"], trackingMode: .selectOne, target: nil, action: nil)
    private let hintLabel = NSTextField(labelWithString: "⏎ send · ⎋ cancel")
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private var texts: [String] = []
    private var files: [String] = []
    private var loaded = false
    private var sendPending = false
    private var keyMonitor: Any?
    private var destinationTouched = false
    private var stageDir: String?

    private var destination: Destination {
        Destination(rawValue: destPicker.selectedSegment) ?? .telegram
    }

    // MARK: - UI

    override func loadView() {
        let width: CGFloat = 440
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 156))

        summaryLabel.frame = NSRect(x: 20, y: 118, width: width - 40, height: 18)
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingMiddle
        root.addSubview(summaryLabel)

        messageField.frame = NSRect(x: 20, y: 76, width: width - 40, height: 26)
        messageField.placeholderString = "Message (optional)"
        messageField.font = .systemFont(ofSize: 13)
        messageField.bezelStyle = .roundedBezel
        messageField.focusRingType = .default
        messageField.target = self
        messageField.action = #selector(send)
        root.addSubview(messageField)

        destPicker.frame = NSRect(x: 20, y: 20, width: 168, height: 26)
        destPicker.selectedSegment = 0
        destPicker.target = self
        destPicker.action = #selector(destinationChanged)
        destPicker.setToolTip("⌘1", forSegment: 0)
        destPicker.setToolTip("⌘2", forSegment: 1)
        root.addSubview(destPicker)

        hintLabel.frame = NSRect(x: 20, y: 2, width: width - 40, height: 14)
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor
        root.addSubview(hintLabel)

        cancelButton.frame = NSRect(x: width - 196, y: 16, width: 84, height: 32)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        root.addSubview(cancelButton)

        sendButton.frame = NSRect(x: width - 108, y: 16, width: 88, height: 32)
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.target = self
        sendButton.action = #selector(send)
        root.addSubview(sendButton)

        view = root
        preferredContentSize = root.frame.size
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectItems()  // starts while the user is still reading/typing
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(messageField)
        view.window?.defaultButtonCell = sendButton.cell as? NSButtonCell
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command) else { return event }
            switch event.charactersIgnoringModifiers {
            case "1": self.selectDestination(.telegram); return nil
            case "2": self.selectDestination(.ytq); return nil
            default: return event
            }
        }
    }

    private func selectDestination(_ dest: Destination) {
        destinationTouched = true
        destPicker.selectedSegment = dest.rawValue
        refreshForDestination()
    }

    @objc private func destinationChanged() {
        destinationTouched = true
        refreshForDestination()
    }

    private func refreshForDestination() {
        messageField.placeholderString = destination == .ytq
            ? "Message (Telegram only — ignored for ytq)"
            : "Message (optional)"
        sendButton.title = destination == .ytq ? "Queue" : "Send"
    }

    // MARK: - Collect shared items

    private func collectItems() {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            finishLoading(summary: "Nothing to share")
            return
        }

        let stageDir = queueDir + "/.staging/" + UUID().uuidString
        self.stageDir = stageDir
        try? FileManager.default.createDirectory(atPath: stageDir, withIntermediateDirectories: true)

        let lock = NSLock()
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            loadBest(from: provider, spoolDir: stageDir, index: index) { text, file in
                lock.lock()
                if let text { self.texts.append(text) }
                if let file { self.files.append(file) }
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.finishLoading(summary: self.describeItems())
        }
    }

    private func finishLoading(summary: String) {
        loaded = true
        summaryLabel.stringValue = summary
        if !destinationTouched, files.isEmpty, !texts.isEmpty,
           texts.allSatisfy({ Self.looksLikeVideoURL($0) }) {
            destPicker.selectedSegment = Destination.ytq.rawValue  // auto-pick, still overridable
            refreshForDestination()
        }
        if sendPending { writeJobAndDismiss() }
    }

    private func describeItems() -> String {
        var parts: [String] = []
        if !texts.isEmpty {
            let joined = texts.joined(separator: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            parts.append(joined.count > 90 ? String(joined.prefix(90)) + "…" : joined)
        }
        if !files.isEmpty {
            let names = files.map { ($0 as NSString).lastPathComponent }
            parts.append(names.count <= 2 ? names.joined(separator: ", ") : "\(names.count) files")
        }
        return parts.isEmpty ? "Nothing usable in the shared items" : parts.joined(separator: " · ")
    }

    /// Video hosts that ytq knows how to fetch.
    private static func looksLikeVideoURL(_ text: String) -> Bool {
        guard let host = URL(string: text.trimmingCharacters(in: .whitespaces))?.host?.lowercased()
        else { return false }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return ["youtube.com", "m.youtube.com", "youtu.be", "x.com", "twitter.com",
                "mobile.twitter.com"].contains(bare)
    }

    /// Pick the single richest representation a provider offers.
    private func loadBest(from provider: NSItemProvider, spoolDir: String, index: Int,
                          completion: @escaping (String?, String?) -> Void) {
        let fileURLType = UTType.fileURL.identifier
        let urlType = UTType.url.identifier
        let textType = UTType.plainText.identifier
        let imageType = UTType.image.identifier

        if provider.hasItemConformingToTypeIdentifier(fileURLType) {
            provider.loadItem(forTypeIdentifier: fileURLType) { item, _ in
                if let url = self.asURL(item), url.isFileURL {
                    completion(nil, self.spool(url, into: spoolDir))
                } else {
                    completion(nil, nil)
                }
            }
        } else if provider.hasItemConformingToTypeIdentifier(urlType) {
            provider.loadItem(forTypeIdentifier: urlType) { item, _ in
                if let url = self.asURL(item) {
                    url.isFileURL ? completion(nil, self.spool(url, into: spoolDir))
                                  : completion(url.absoluteString, nil)
                } else {
                    completion(nil, nil)
                }
            }
        } else if provider.hasItemConformingToTypeIdentifier(imageType) {
            provider.loadItem(forTypeIdentifier: imageType) { item, _ in
                completion(nil, self.spoolImage(item, into: spoolDir, index: index))
            }
        } else if provider.hasItemConformingToTypeIdentifier(textType) {
            provider.loadItem(forTypeIdentifier: textType) { item, _ in
                if let s = item as? String {
                    completion(s, nil)
                } else if let d = item as? Data, let s = String(data: d, encoding: .utf8) {
                    completion(s, nil)
                } else {
                    completion(nil, nil)
                }
            }
        } else {
            completion(nil, nil)
        }
    }

    private func asURL(_ item: (any NSSecureCoding)?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let s = item as? String { return URL(string: s) }
        return nil
    }

    private func spool(_ src: URL, into dir: String) -> String? {
        let needsAccess = src.startAccessingSecurityScopedResource()
        defer { if needsAccess { src.stopAccessingSecurityScopedResource() } }
        var dest = URL(fileURLWithPath: dir).appendingPathComponent(src.lastPathComponent)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = URL(fileURLWithPath: dir).appendingPathComponent("\(n)-\(src.lastPathComponent)")
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: src, to: dest)
            return dest.path
        } catch {
            return nil
        }
    }

    private func spoolImage(_ item: (any NSSecureCoding)?, into dir: String, index: Int) -> String? {
        if let url = asURL(item), url.isFileURL { return spool(url, into: dir) }
        var data: Data?
        if let d = item as? Data { data = d }
        if let image = item as? NSImage,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            data = rep.representation(using: .png, properties: [:])
        }
        guard let data else { return nil }
        let dest = URL(fileURLWithPath: dir).appendingPathComponent("shared-\(index).png")
        try? data.write(to: dest)
        return dest.path
    }

    // MARK: - Send

    @objc private func send() {
        guard !sendPending else { return }
        if destination == .ytq && loaded && !texts.contains(where: { $0.contains("://") }) {
            flash("ytq needs a URL — switch to Telegram (⌘1)")
            return
        }
        if !loaded {  // user was faster than the item loader; go as soon as it lands
            sendPending = true
            sendButton.isEnabled = false
            summaryLabel.stringValue = "Preparing…"
            return
        }
        writeJobAndDismiss()
    }

    private func writeJobAndDismiss() {
        let message = messageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !files.isEmpty || !message.isEmpty else {
            flash("Nothing to send")
            sendPending = false
            sendButton.isEnabled = true
            return
        }

        let job: [String: Any] = ["dest": destination.jobValue, "message": message,
                                  "text": text, "files": files]
        let jobDir = queueDir + "/" + UUID().uuidString
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: jobDir, withIntermediateDirectories: true)
            // Relocate staged files so the job dir is self-contained, then write
            // job.json last — the relay only picks up a dir once that file exists.
            var moved: [String] = []
            for path in files {
                let dest = jobDir + "/" + (path as NSString).lastPathComponent
                try? fm.moveItem(atPath: path, toPath: dest)
                moved.append(fm.fileExists(atPath: dest) ? dest : path)
            }
            var finalJob = job
            finalJob["files"] = moved
            let data = try JSONSerialization.data(withJSONObject: finalJob, options: [.prettyPrinted])
            try data.write(to: URL(fileURLWithPath: jobDir + "/job.json.tmp"))
            try fm.moveItem(atPath: jobDir + "/job.json.tmp", toPath: jobDir + "/job.json")
        } catch {
            flash("Could not queue: \(error.localizedDescription)")
            sendPending = false
            sendButton.isEnabled = true
            return
        }

        if let stageDir { try? fm.removeItem(atPath: stageDir) }
        cleanUp()
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    @objc private func cancel() {
        cleanUp()
        if let stageDir { try? FileManager.default.removeItem(atPath: stageDir) }
        extensionContext?.cancelRequest(withError: NSError(
            domain: "SendToMyBot", code: NSUserCancelledError,
            userInfo: [NSLocalizedDescriptionKey: "Cancelled"]))
    }

    private func flash(_ message: String) {
        summaryLabel.stringValue = "⚠️ " + message
        NSSound.beep()
    }

    private func cleanUp() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
