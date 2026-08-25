import AppKit
import UniformTypeIdentifiers

/// Share-sheet UI: an optional message, a destination picker built from the
/// user's configured destinations, and nothing else in the way. Return sends
/// and dismisses immediately; delivery is done out of process by the relay
/// LaunchAgent (this extension is sandboxed — no network, no exec).
///
/// Keys:  ⏎ send · ⎋ cancel · ⌘1…⌘9 pick a destination
final class ShareViewController: NSViewController {

    /// Mirror of one entry in destinations.json, published by `share-to-claw sync`.
    private struct Destination {
        let id: String
        let label: String
        let accepts: Set<String>
        let autoForHosts: [String]
        let handlesFiles: Bool
        let isDefault: Bool

        init?(_ dict: [String: Any]) {
            guard let id = dict["id"] as? String else { return nil }
            self.id = id
            label = dict["label"] as? String ?? id
            accepts = Set(dict["accepts"] as? [String] ?? ["text", "url", "file", "image"])
            autoForHosts = dict["auto_for_hosts"] as? [String] ?? []
            handlesFiles = dict["handles_files"] as? Bool ?? true
            isDefault = dict["default"] as? Bool ?? false
        }
    }

    // Inside the sandbox, NSHomeDirectory() is the container's Data dir.
    private let queueDir = NSHomeDirectory() + "/queue"
    private var destsFile: String { NSHomeDirectory() + "/destinations.json" }

    private let summaryLabel = NSTextField(labelWithString: "Reading shared item…")
    private let messageField = NSTextField()
    private let hintLabel = NSTextField(labelWithString: "⏎ send · ⎋ cancel")
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var picker: NSSegmentedControl?
    private var popup: NSPopUpButton?

    private var destinations: [Destination] = []
    private var selection = 0
    private var destinationTouched = false

    private var texts: [String] = []
    private var files: [String] = []
    private var loaded = false
    private var sendPending = false
    private var keyMonitor: Any?
    private var stageDir: String?

    private var current: Destination? {
        destinations.indices.contains(selection) ? destinations[selection] : nil
    }

    // MARK: - UI

    override func loadView() {
        destinations = Self.loadDestinations(from: destsFile)

        let width: CGFloat = 460
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
        messageField.target = self
        messageField.action = #selector(send)
        root.addSubview(messageField)

        // Up to four destinations fit as segments; beyond that use a pop-up.
        let pickerWidth = min(CGFloat(destinations.count) * 92 + 8, 250)
        if destinations.count <= 4 {
            let control = NSSegmentedControl(labels: destinations.map(\.label),
                                             trackingMode: .selectOne, target: self,
                                             action: #selector(pickerChanged))
            control.frame = NSRect(x: 20, y: 20, width: pickerWidth, height: 26)
            for (i, _) in destinations.enumerated() { control.setToolTip("⌘\(i + 1)", forSegment: i) }
            root.addSubview(control)
            picker = control
        } else {
            let control = NSPopUpButton(frame: NSRect(x: 20, y: 20, width: 200, height: 26))
            control.addItems(withTitles: destinations.map(\.label))
            control.target = self
            control.action = #selector(pickerChanged)
            root.addSubview(control)
            popup = control
        }

        hintLabel.frame = NSRect(x: 20, y: 2, width: width - 40, height: 14)
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.stringValue = destinations.count > 1
            ? "⏎ send · ⎋ cancel · ⌘1–⌘\(min(destinations.count, 9)) destination"
            : "⏎ send · ⎋ cancel"
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

        selection = destinations.firstIndex(where: \.isDefault) ?? 0
        syncPicker()
    }

    private static func loadDestinations(from path: String) -> [Destination] {
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["destinations"] as? [[String: Any]]
        else {
            // No published config yet — a single Telegram destination is the
            // historical default and keeps the panel usable.
            return [Destination(["id": "telegram", "label": "Telegram", "default": true])].compactMap { $0 }
        }
        return list.compactMap(Destination.init)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectItems()  // runs while the user is still reading/typing
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(messageField)
        view.window?.defaultButtonCell = sendButton.cell as? NSButtonCell
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command),
                  let chars = event.charactersIgnoringModifiers,
                  let digit = Int(chars), digit >= 1, digit <= self.destinations.count
            else { return event }
            self.select(index: digit - 1)
            return nil
        }
    }

    // MARK: - Destination selection

    @objc private func pickerChanged() {
        select(index: picker?.selectedSegment ?? popup?.indexOfSelectedItem ?? 0)
    }

    private func select(index: Int) {
        guard destinations.indices.contains(index) else { return }
        destinationTouched = true
        selection = index
        syncPicker()
    }

    private func syncPicker() {
        picker?.selectedSegment = selection
        popup?.selectItem(at: selection)
        guard let dest = current else { return }
        sendButton.title = dest.accepts.contains("url") && dest.accepts.count == 1 ? "Queue" : "Send"
        messageField.placeholderString = dest.accepts.contains("url") && dest.accepts.count == 1
            ? "Message (ignored by \(dest.label))"
            : "Message (optional)"
        if loaded { validate() }
    }

    /// Grey out the send button when the payload doesn't suit the destination.
    private func validate() {
        guard let dest = current else { return }
        let kinds = payloadKinds()
        let hasFiles = !files.isEmpty
        let fileOK = !hasFiles || dest.handlesFiles
        let needsURL = dest.accepts == ["url"]
        let hasURL = texts.contains { $0.contains("://") }
        let ok = fileOK && (!needsURL || hasURL)
        sendButton.isEnabled = ok
        if !ok {
            summaryLabel.stringValue = needsURL && !hasURL
                ? "⚠️ \(dest.label) needs a URL"
                : "⚠️ \(dest.label) can't take files"
        } else if summaryLabel.stringValue.hasPrefix("⚠️") {
            summaryLabel.stringValue = describeItems()
        }
        _ = kinds
    }

    private func payloadKinds() -> Set<String> {
        var kinds = Set<String>()
        if texts.contains(where: { $0.contains("://") }) { kinds.insert("url") }
        if texts.contains(where: { !$0.contains("://") }) { kinds.insert("text") }
        for f in files {
            let ext = (f as NSString).pathExtension.lowercased()
            kinds.insert(["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff"].contains(ext)
                         ? "image" : "file")
        }
        return kinds
    }

    // MARK: - Collect shared items

    private func collectItems() {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            finishLoading(summary: "Nothing to share")
            return
        }

        let stage = queueDir + "/.staging/" + UUID().uuidString
        stageDir = stage
        try? FileManager.default.createDirectory(atPath: stage, withIntermediateDirectories: true)

        let lock = NSLock()
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            loadBest(from: provider, spoolDir: stage, index: index) { text, file in
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
        autoSelectDestination()
        validate()
        if sendPending { writeJobAndDismiss() }
    }

    /// A YouTube/X link picks the ytq-style destination that claims that host.
    private func autoSelectDestination() {
        guard !destinationTouched, files.isEmpty, !texts.isEmpty else { return }
        let hosts = texts.compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces))?.host?.lowercased() }
            .map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        guard hosts.count == texts.count, !hosts.isEmpty else { return }
        if let index = destinations.firstIndex(where: { dest in
            !dest.autoForHosts.isEmpty && hosts.allSatisfy { dest.autoForHosts.contains($0) }
        }) {
            selection = index
            syncPicker()
        }
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
        guard !sendPending, sendButton.isEnabled else { return }
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
            return
        }

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
            let job: [String: Any] = ["dest": current?.id ?? "", "message": message,
                                      "text": text, "files": moved]
            let data = try JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted])
            try data.write(to: URL(fileURLWithPath: jobDir + "/job.json.tmp"))
            try fm.moveItem(atPath: jobDir + "/job.json.tmp", toPath: jobDir + "/job.json")
        } catch {
            flash("Could not queue: \(error.localizedDescription)")
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
            domain: "ShareToClaw", code: NSUserCancelledError,
            userInfo: [NSLocalizedDescriptionKey: "Cancelled"]))
    }

    private func flash(_ message: String) {
        summaryLabel.stringValue = "⚠️ " + message
        sendPending = false
        sendButton.isEnabled = true
        NSSound.beep()
    }

    private func cleanUp() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
