import AppKit
import RunyardCore

enum StatusStyle {
    static func color(_ status: ServiceStatus) -> NSColor {
        switch status {
        case .running: .systemGreen
        case .stopping: .systemYellow
        case .exited(let code) where code != 0: .systemRed
        default: .systemGray
        }
    }

    static func color(_ statuses: [ServiceStatus]) -> NSColor {
        if statuses.contains(where: { if case .exited(let code) = $0 { code != 0 } else { false } }) {
            return .systemRed
        }
        if statuses.contains(where: { $0 == .running || $0 == .stopping }) {
            return .systemGreen
        }
        return .systemGray
    }

    static func label(_ status: ServiceStatus) -> String {
        switch status {
        case .running: "Rodando"
        case .stopping: "Parando"
        case .stopped: "Parado"
        case .exited(-1): "Encerrado (código desconhecido)"
        case .exited(let code): "Encerrado com código \(code)"
        }
    }

    static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

final class ClosureButton: NSButton {
    private var handler: () -> Void = {}

    convenience init(symbol: String, tooltip: String, enabled: Bool = true, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.handler = handler
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        imagePosition = .imageOnly
        isBordered = false
        toolTip = tooltip
        isEnabled = enabled
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(run)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    @objc private func run() {
        handler()
    }
}

class HoverRowView: NSView {
    static let width: CGFloat = 360
    private static weak var hovered: HoverRowView?

    private var hovering = false {
        didSet { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        if let previous = Self.hovered, previous !== self {
            previous.hovering = false
        }
        Self.hovered = self
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            clearHover()
        }
    }

    private func clearHover() {
        if Self.hovered === self {
            Self.hovered = nil
        }
        hovering = false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
    }

    func label(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    func layout(leading: NSView, leadingInset: CGFloat, text: NSView, buttons: NSStackView, rowHeight: CGFloat? = nil) {
        [leading, text, buttons].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        let center = { (view: NSView) in
            rowHeight.map { view.centerYAnchor.constraint(equalTo: self.topAnchor, constant: $0 / 2) } ?? view.centerYAnchor.constraint(equalTo: self.centerYAnchor)
        }
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            center(leading),
            center(text),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            center(buttons),
            text.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8)
        ])
    }
}

@MainActor
final class ProjectHeaderView: HoverRowView {
    private let project: Project
    private let manager: ProcessManager
    private let onToggle: () -> Void
    private let dot = NSImageView()
    private let buttons = NSStackView()

    init(project: Project, manager: ProcessManager, expanded: Bool, onToggle: @escaping () -> Void) {
        self.project = project
        self.manager = manager
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 30))

        let chevron = NSImageView(image: NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil) ?? NSImage())
        chevron.contentTintColor = .secondaryLabelColor
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)

        let name = label(project.name, font: .boldSystemFont(ofSize: NSFont.systemFontSize))
        let title = NSStackView(views: [dot, name])
        title.spacing = 8
        buttons.spacing = 0

        layout(leading: chevron, leadingInset: 14, text: title, buttons: buttons)
        title.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 8).isActive = true
        chevron.widthAnchor.constraint(equalToConstant: 10).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func mouseUp(with event: NSEvent) {
        onToggle()
    }

    func refresh() {
        let keys = project.services.map { manager.key(project, $0) }
        dot.image = StatusStyle.dot(StatusStyle.color(keys.map { manager.status($0) }))
        let anyActive = keys.contains { manager.isActive($0) }
        let project = project
        buttons.setViews([
            ClosureButton(symbol: "play.fill", tooltip: "Subir todos") { [weak manager] in manager?.startAll(project) },
            ClosureButton(symbol: "stop.fill", tooltip: "Parar todos", enabled: anyActive) { [weak manager] in manager?.stopAll(project) },
            ClosureButton(symbol: "square.and.pencil", tooltip: "Editar registro") { NSWorkspace.shared.open(project.file) }
        ], in: .trailing)
    }
}

@MainActor
final class ServiceRowView: HoverRowView {
    private let project: Project
    private let service: ServiceConfig
    private let manager: ProcessManager
    private let dot = NSImageView()
    private let buttons = NSStackView()
    private let tail = NSStackView()
    private let onToggleTail: () -> Void
    private var shownURL: URL?
    private let onAction: () -> Void
    private static let rowHeight: CGFloat = 38
    private static let tailLines = 3
    private static let tailLineHeight: CGFloat = 14

    init(project: Project, service: ServiceConfig, manager: ProcessManager, showsTail: Bool, onToggleTail: @escaping () -> Void, onAction: @escaping () -> Void) {
        self.project = project
        self.service = service
        self.manager = manager
        self.onToggleTail = onToggleTail
        self.onAction = onAction
        let height = Self.rowHeight + (showsTail ? CGFloat(Self.tailLines) * Self.tailLineHeight + 6 : 0)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))

        let name = label(service.name, font: .menuFont(ofSize: 0))
        let command = label(service.command, font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)
        let text = NSStackView(views: [name, command])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        toolTip = service.command
        buttons.spacing = 0

        layout(leading: dot, leadingInset: 32, text: text, buttons: buttons, rowHeight: Self.rowHeight)
        text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8).isActive = true

        if showsTail {
            tail.orientation = .vertical
            tail.alignment = .leading
            tail.spacing = 0
            tail.translatesAutoresizingMaskIntoConstraints = false
            for _ in 0..<Self.tailLines {
                let line = label("", font: .monospacedSystemFont(ofSize: 10, weight: .regular), color: .tertiaryLabelColor)
                line.heightAnchor.constraint(equalToConstant: Self.tailLineHeight).isActive = true
                tail.addArrangedSubview(line)
            }
            addSubview(tail)
            NSLayoutConstraint.activate([
                tail.topAnchor.constraint(equalTo: topAnchor, constant: Self.rowHeight - 2),
                tail.leadingAnchor.constraint(equalTo: text.leadingAnchor),
                tail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
            ])
            refreshTail()
        }
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func mouseUp(with event: NSEvent) {
        onToggleTail()
    }

    func refreshURL() {
        if manager.serviceURL(project, service) != shownURL {
            refresh()
        }
    }

    func refreshTail() {
        guard !tail.arrangedSubviews.isEmpty else { return }
        let lines = LogReader.lastLines(manager.logURL(manager.key(project, service)), count: Self.tailLines)
        let padded = Array(repeating: "", count: Self.tailLines - lines.count) + lines
        for (field, line) in zip(tail.arrangedSubviews.compactMap { $0 as? NSTextField }, padded) {
            field.stringValue = line
            field.toolTip = line.isEmpty ? nil : line
        }
    }

    func refresh() {
        let key = manager.key(project, service)
        let status = manager.status(key)
        let active = manager.isActive(key)
        dot.image = StatusStyle.dot(StatusStyle.color(status))
        dot.toolTip = StatusStyle.label(status)

        let project = project
        let service = service
        var views: [NSView] = []
        shownURL = manager.serviceURL(project, service)
        if let url = shownURL {
            views.append(ClosureButton(symbol: "safari", tooltip: "Abrir \(url.absoluteString)") { [weak self] in
                self?.enclosingMenuItem?.menu?.cancelTracking()
                NSWorkspace.shared.open(url)
            })
        }
        if active {
            views.append(ClosureButton(symbol: "arrow.clockwise", tooltip: "Reiniciar") { [weak self, weak manager] in
                manager?.restart(project, service)
                self?.onAction()
            })
            views.append(ClosureButton(symbol: "stop.fill", tooltip: "Parar") { [weak manager] in manager?.stop(key) })
        } else {
            views.append(ClosureButton(symbol: "play.fill", tooltip: "Subir") { [weak self, weak manager] in
                manager?.start(project, service)
                self?.onAction()
            })
        }
        views.append(ClosureButton(symbol: "doc.text", tooltip: "Ver log", enabled: active || manager.hasLog(key)) { [weak self] in
            self?.enclosingMenuItem?.menu?.cancelTracking()
            LogWindowController.shared.show(key)
        })
        buttons.setViews(views, in: .trailing)
    }
}
