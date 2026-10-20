import AppKit
import ServiceManagement

final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, key: String = "", enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        isEnabled = enabled
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    required init(coder: NSCoder) {
        fatalError()
    }

    @objc private func run() {
        handler()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let manager = ProcessManager.shared
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = menuBarIcon()
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        manager.onChange = { [weak self] in self?.updateButton() }
        updateButton()
        print("Runyard iniciado")
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.signalAll(SIGTERM)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        manager.reload()
        build(menu)
    }

    private func menuBarIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Runyard")
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Runyard"
        return image
    }

    private func updateButton() {
        let count = manager.runningCount
        statusItem.button?.title = count > 0 ? " \(count)" : ""
    }

    private func build(_ menu: NSMenu) {
        menu.removeAllItems()

        let count = manager.runningCount
        let header = NSMenuItem(title: count > 0 ? "\(count) serviço(s) rodando" : "Nenhum serviço rodando", action: nil, keyEquivalent: "")
        header.image = dot(color(for: manager.projects))
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for error in manager.configErrors {
            let item = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            item.isEnabled = false
            menu.addItem(item)
        }

        if manager.projects.isEmpty {
            let empty = NSMenuItem(title: "Nenhum projeto registrado", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        for project in manager.projects {
            let item = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
            item.image = dot(color(for: [project]))
            item.submenu = projectMenu(project)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(ActionItem("Abrir pasta de registros", symbol: "square.and.pencil") {
            NSWorkspace.shared.open(ConfigStore.projectsDirectory)
        })
        menu.addItem(ActionItem("Abrir pasta de logs", symbol: "folder") {
            try? FileManager.default.createDirectory(at: ConfigStore.logsDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(ConfigStore.logsDirectory)
        })
        let login = ActionItem("Abrir no login", symbol: "person.crop.circle") { [weak self] in
            self?.toggleLaunchAtLogin()
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(ActionItem("Parar tudo e sair", symbol: "power", key: "q") { [weak self] in
            self?.manager.quit()
        })
    }

    private func projectMenu(_ project: Project) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let anyActive = project.services.contains { manager.isActive(manager.key(project, $0)) }

        menu.addItem(ActionItem("Subir todos", symbol: "play.fill") { [weak self] in
            self?.manager.startAll(project)
        })
        menu.addItem(ActionItem("Parar todos", symbol: "stop.fill", enabled: anyActive) { [weak self] in
            self?.manager.stopAll(project)
        })
        menu.addItem(.separator())

        for service in project.services {
            let key = manager.key(project, service)
            let item = NSMenuItem(title: service.name, action: nil, keyEquivalent: "")
            item.image = dot(color(for: manager.status(key)))
            if #available(macOS 14.4, *) {
                item.subtitle = service.command
            }
            item.submenu = serviceMenu(project, service)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(ActionItem("Abrir pasta do projeto", symbol: "folder") {
            NSWorkspace.shared.open(URL(fileURLWithPath: project.expandedPath))
        })
        menu.addItem(ActionItem("Editar registro", symbol: "square.and.pencil") {
            NSWorkspace.shared.open(project.file)
        })
        return menu
    }

    private func serviceMenu(_ project: Project, _ service: ServiceConfig) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let key = manager.key(project, service)
        let active = manager.isActive(key)

        let status = NSMenuItem(title: label(for: manager.status(key)), action: nil, keyEquivalent: "")
        status.image = dot(color(for: manager.status(key)))
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        if active {
            menu.addItem(ActionItem("Reiniciar", symbol: "arrow.clockwise") { [weak self] in
                self?.manager.restart(project, service)
            })
            menu.addItem(ActionItem("Parar", symbol: "stop.fill") { [weak self] in
                self?.manager.stop(key)
            })
        } else {
            menu.addItem(ActionItem("Subir", symbol: "play.fill") { [weak self] in
                self?.manager.start(project, service)
            })
        }
        menu.addItem(ActionItem("Ver log", symbol: "doc.text", enabled: active || manager.hasLog(key)) { [weak self] in
            self?.manager.openLog(key)
        })
        return menu
    }

    private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("Erro ao alterar abertura no login: \(error)")
        }
    }

    private func color(for projects: [Project]) -> NSColor {
        let statuses = projects.flatMap { project in project.services.map { manager.status(manager.key(project, $0)) } }
        if statuses.contains(where: { if case .exited(let code) = $0 { code != 0 } else { false } }) {
            return .systemRed
        }
        if statuses.contains(where: { $0 == .running || $0 == .stopping }) {
            return .systemGreen
        }
        return .systemGray
    }

    private func color(for status: ServiceStatus) -> NSColor {
        switch status {
        case .running: .systemGreen
        case .stopping: .systemYellow
        case .exited(let code) where code != 0: .systemRed
        default: .systemGray
        }
    }

    private func label(for status: ServiceStatus) -> String {
        switch status {
        case .running: "Rodando"
        case .stopping: "Parando"
        case .stopped: "Parado"
        case .exited(let code): "Encerrado com código \(code)"
        }
    }

    private func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}
