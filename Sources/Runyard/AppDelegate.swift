import AppKit
import RunyardCore
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
    private lazy var server = ControlServer(manager: manager)
    private var header: NSMenuItem?
    private var refreshers: [() -> Void] = []
    private var tailRefreshers: [() -> Void] = []
    private var tailTimer: Timer?
    private var openTails: Set<ServiceKey> = []
    private let expandedKey = "expandedProjects"

    private var expanded: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: expandedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: expandedKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = menuBarIcon()
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        NSApp.mainMenu = mainMenu()
        manager.onChange = { [weak self] in self?.refresh() }
        manager.onCrash = { key, status, note in Notifier.shared.serviceCrashed(key, status: status, note: note) }
        manager.onPortConflict = { [weak self] project, service, port, owners in
            self?.resolvePortConflict(project, service, port: port, owners: owners)
        }
        Notifier.shared.setup()
        refresh()
        server.start()
        print("Runyard iniciado")
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.signalAll(SIGTERM)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        manager.reload()
        build(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tailRefreshers.forEach { $0() } }
        }
        RunLoop.main.add(timer, forMode: .common)
        tailTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        tailTimer?.invalidate()
        tailTimer = nil
        openTails = []
    }

    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Fechar janela", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Editar")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Selecionar tudo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find: [(String, String, NSEvent.ModifierFlags, NSFindPanelAction)] = [
            ("Buscar", "f", [.command], .showFindPanel),
            ("Buscar próximo", "g", [.command], .next),
            ("Buscar anterior", "g", [.command, .shift], .previous)
        ]
        for (title, key, modifiers, action) in find {
            let item = edit.addItem(withTitle: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = Int(action.rawValue)
        }
        editItem.submenu = edit
        main.addItem(editItem)
        return main
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

    private func refresh() {
        let count = manager.runningCount
        statusItem.button?.title = count > 0 ? " \(count)" : ""
        header?.title = count > 0 ? "\(count) serviço(s) rodando" : "Nenhum serviço rodando"
        header?.image = StatusStyle.dot(StatusStyle.color(allStatuses()))
        refreshers.forEach { $0() }
        LogWindowController.shared.refresh()
    }

    private func allStatuses() -> [ServiceStatus] {
        manager.projects.flatMap { project in project.services.map { manager.status(manager.key(project, $0)) } }
    }

    private func toggle(_ project: Project) {
        var current = expanded
        if current.remove(project.name) == nil {
            current.insert(project.name)
        }
        expanded = current
        DispatchQueue.main.async {
            self.build(self.menu)
        }
    }

    private func setTail(_ key: ServiceKey, open: Bool?) {
        let isOpen = openTails.contains(key)
        let target = open ?? !isOpen
        guard target != isOpen else { return }
        if target {
            openTails.insert(key)
        } else {
            openTails.remove(key)
        }
        DispatchQueue.main.async {
            self.build(self.menu)
        }
    }

    private func build(_ menu: NSMenu) {
        menu.removeAllItems()
        refreshers = []
        tailRefreshers = []

        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        self.header = header
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

        let open = expanded
        for project in manager.projects {
            let isOpen = open.contains(project.name)
            let headerView = ProjectHeaderView(project: project, manager: manager, expanded: isOpen) { [weak self] in
                self?.toggle(project)
            }
            add(headerView, to: menu)
            refreshers.append(headerView.refresh)

            guard isOpen else { continue }
            for service in project.services {
                let key = manager.key(project, service)
                let row = ServiceRowView(
                    project: project,
                    service: service,
                    manager: manager,
                    showsTail: openTails.contains(key),
                    onToggleTail: { [weak self] in self?.setTail(key, open: nil) },
                    onAction: { [weak self] in self?.setTail(key, open: true) }
                )
                add(row, to: menu)
                refreshers.append(row.refresh)
                tailRefreshers.append {
                    row.refreshTail()
                    row.refreshURL()
                }
            }
        }

        menu.addItem(.separator())
        menu.addItem(ActionItem("Janela de logs", symbol: "text.alignleft", key: "l") {
            LogWindowController.shared.show()
        })
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
        refresh()
    }

    private func add(_ view: NSView, to menu: NSMenu) {
        let item = NSMenuItem()
        item.view = view
        menu.addItem(item)
    }

    private func resolvePortConflict(_ project: Project, _ service: ServiceConfig, port: Int, owners: [PortOwner]) {
        menu.cancelTracking()
        DispatchQueue.main.async { [manager] in
            let alert = NSAlert()
            alert.messageText = "A porta \(port) já está em uso"
            alert.informativeText = "\(project.name)/\(service.name) usa a porta \(port), que está ocupada por:\n" + owners.map(manager.describe).joined(separator: "\n")
            alert.addButton(withTitle: "Encerrar e subir")
            alert.addButton(withTitle: "Subir mesmo assim")
            alert.addButton(withTitle: "Cancelar")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                manager.freePort(port, owners: owners) { manager.launch(project, service) }
            case .alertSecondButtonReturn:
                manager.launch(project, service)
            default:
                print("Início de \(project.name)/\(service.name) cancelado por porta ocupada")
            }
        }
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
}
