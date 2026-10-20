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
    private var header: NSMenuItem?
    private var refreshers: [() -> Void] = []
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
        manager.onChange = { [weak self] in self?.refresh() }
        refresh()
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

    private func refresh() {
        let count = manager.runningCount
        statusItem.button?.title = count > 0 ? " \(count)" : ""
        header?.title = count > 0 ? "\(count) serviço(s) rodando" : "Nenhum serviço rodando"
        header?.image = StatusStyle.dot(StatusStyle.color(allStatuses()))
        refreshers.forEach { $0() }
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

    private func build(_ menu: NSMenu) {
        menu.removeAllItems()
        refreshers = []

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
                let row = ServiceRowView(project: project, service: service, manager: manager)
                add(row, to: menu)
                refreshers.append(row.refresh)
            }
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
        refresh()
    }

    private func add(_ view: NSView, to menu: NSMenu) {
        let item = NSMenuItem()
        item.view = view
        menu.addItem(item)
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
