import AppKit
import RunyardCore

@MainActor
final class LogWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = LogWindowController()

    private enum Entry {
        case project(Project)
        case service(Project, ServiceConfig)
    }

    private let manager = ProcessManager.shared
    private let table = NSTableView()
    private let textView: NSTextView
    private let scrollView: NSScrollView
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let actions = NSStackView()
    private var entries: [Entry] = []
    private var selected: ServiceKey?
    private var offset: UInt64 = 0
    private var timer: Timer?
    private let initialBytes: UInt64 = 512 * 1024
    private let maxCharacters = 2_000_000
    private let selectedKey = "logWindowSelection"

    private init() {
        scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as! NSTextView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Logs"
        window.minSize = NSSize(width: 600, height: 300)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("RunyardLogWindow")
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    func show(_ key: ServiceKey? = nil) {
        reloadEntries()
        if let key {
            select(key)
        } else if selected == nil {
            select(savedSelection() ?? firstService())
        }
        startFollowing()
        if window?.isVisible != true {
            window?.center()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        guard window?.isVisible == true else { return }
        reloadEntries()
        updateHeader()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        NSApp.setActivationPolicy(.accessory)
    }

    private func build() {
        guard let content = window?.contentView else { return }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("service"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = .default
        table.dataSource = self
        table.delegate = self
        let sidebar = NSScrollView()
        sidebar.documentView = table
        sidebar.hasVerticalScroller = true
        sidebar.drawsBackground = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        scrollView.hasVerticalScroller = true

        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actions.spacing = 2

        let header = NSStackView(views: [titleLabel, statusLabel, NSView(), actions])
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 8)
        header.setHuggingPriority(.defaultHigh, for: .vertical)

        let detail = NSStackView(views: [header, scrollView])
        detail.orientation = .vertical
        detail.spacing = 0
        detail.alignment = .leading
        header.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        scrollView.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(detail)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        split.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
        split.setPosition(220, ofDividerAt: 0)
    }

    private func reloadEntries() {
        entries = manager.projects.flatMap { project in
            [Entry.project(project)] + project.services.map { Entry.service(project, $0) }
        }
        table.reloadData()
        if let selected, let row = row(for: selected) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
    }

    private func row(for key: ServiceKey) -> Int? {
        entries.firstIndex {
            if case .service(let project, let service) = $0 { manager.key(project, service) == key } else { false }
        }
    }

    private func firstService() -> ServiceKey? {
        for entry in entries {
            if case .service(let project, let service) = entry { return manager.key(project, service) }
        }
        return nil
    }

    private func savedSelection() -> ServiceKey? {
        guard let data = UserDefaults.standard.data(forKey: selectedKey),
              let key = try? JSONDecoder().decode(ServiceKey.self, from: data),
              row(for: key) != nil else { return nil }
        return key
    }

    private func select(_ key: ServiceKey?) {
        guard let key else { return }
        if let row = row(for: key) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        guard key != selected else { return }
        selected = key
        if let data = try? JSONEncoder().encode(key) {
            UserDefaults.standard.set(data, forKey: selectedKey)
        }
        loadLog()
        updateHeader()
    }

    private func loadLog() {
        guard let selected else { return }
        let url = manager.logURL(selected)
        let size = LogReader.size(url)
        let start = size > initialBytes ? size - initialBytes : 0
        let result = LogReader.read(url, from: start, to: size)
        offset = result.end
        textView.string = result.text
        scrollToBottom()
    }

    private func follow() {
        guard let selected else { return }
        let url = manager.logURL(selected)
        let size = LogReader.size(url)
        if size < offset {
            loadLog()
            return
        }
        guard size > offset else { return }
        let atBottom = isAtBottom()
        let result = LogReader.read(url, from: offset, to: size)
        offset = result.end
        guard !result.text.isEmpty, let storage = textView.textStorage else { return }
        storage.append(NSAttributedString(string: result.text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]))
        if storage.length > maxCharacters {
            storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - maxCharacters))
        }
        if atBottom {
            scrollToBottom()
        }
    }

    private func isAtBottom() -> Bool {
        let visible = scrollView.contentView.documentVisibleRect
        return visible.maxY >= textView.bounds.maxY - 40
    }

    private func scrollToBottom() {
        textView.scrollToEndOfDocument(nil)
    }

    private func startFollowing() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func updateHeader() {
        guard let selected,
              let project = manager.projects.first(where: { $0.name == selected.project }),
              let service = project.services.first(where: { $0.name == selected.service }) else {
            titleLabel.stringValue = ""
            statusLabel.stringValue = ""
            actions.setViews([], in: .trailing)
            return
        }
        let status = manager.status(selected)
        let active = manager.isActive(selected)
        titleLabel.stringValue = "\(project.name) / \(service.name)"
        statusLabel.stringValue = "\(StatusStyle.label(status)) · \(service.command)"

        var views: [NSView] = []
        if active {
            views.append(ClosureButton(symbol: "arrow.clockwise", tooltip: "Reiniciar") { [weak manager] in manager?.restart(project, service) })
            views.append(ClosureButton(symbol: "stop.fill", tooltip: "Parar") { [weak manager] in manager?.stop(selected) })
        } else {
            views.append(ClosureButton(symbol: "play.fill", tooltip: "Subir") { [weak manager] in manager?.start(project, service) })
        }
        views.append(ClosureButton(symbol: "trash", tooltip: "Limpar a tela") { [weak self] in self?.textView.string = "" })
        views.append(ClosureButton(symbol: "arrow.down.to.line", tooltip: "Ir para o fim") { [weak self] in self?.scrollToBottom() })
        views.append(ClosureButton(symbol: "arrow.up.forward.app", tooltip: "Abrir no Console") { [weak manager] in manager?.openLog(selected) })
        actions.setViews(views, in: .trailing)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .project = entries[row] { true } else { false }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .service = entries[row] { true } else { false }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch entries[row] {
        case .project(let project):
            let field = NSTextField(labelWithString: project.name)
            field.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            field.textColor = .secondaryLabelColor
            return field
        case .service(let project, let service):
            let key = manager.key(project, service)
            let dot = NSImageView(image: StatusStyle.dot(StatusStyle.color(manager.status(key))))
            let name = NSTextField(labelWithString: service.name)
            name.lineBreakMode = .byTruncatingTail
            let cell = NSStackView(views: [dot, name])
            cell.spacing = 6
            cell.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, case .service(let project, let service) = entries[row] else { return }
        select(manager.key(project, service))
    }
}
