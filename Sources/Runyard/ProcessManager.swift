import AppKit
import Foundation
import RunyardCore

enum ServiceStatus: Equatable {
    case stopped
    case running
    case stopping
    case exited(Int32)
}

struct ServiceKey: Hashable, Codable {
    let project: String
    let service: String
}

struct RunningEntry: Codable {
    let key: ServiceKey
    let pid: pid_t
}

@MainActor
final class ProcessManager {
    static let shared = ProcessManager()

    private(set) var projects: [Project] = []
    private(set) var configErrors: [String] = []
    private(set) var statuses: [ServiceKey: ServiceStatus] = [:] {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?
    var onCrash: ((ServiceKey, ServiceStatus, String?) -> Void)?
    var onPortConflict: ((Project, ServiceConfig, Int, [PortOwner]) -> Void)?

    private var pids: [ServiceKey: pid_t] = [:] {
        didSet { saveState() }
    }
    private var watchers: [ServiceKey: DispatchSourceProcess] = [:]
    private var pendingRestart: Set<ServiceKey> = []
    private var detectedURLs: [ServiceKey: URL] = [:]
    private var scannedSizes: [ServiceKey: UInt64] = [:]
    private var crashTimes: [ServiceKey: [Date]] = [:]
    private var scheduledRestarts: Set<ServiceKey> = []
    private let restartDelay: TimeInterval = 2
    private let restartWindow: TimeInterval = 60
    private let maxRestarts = 5
    private let killTimeout: TimeInterval = 15

    init() {
        reload()
        adopt()
    }

    var runningCount: Int {
        statuses.values.filter { $0 == .running || $0 == .stopping }.count
    }

    func reload() {
        let loaded = ConfigStore.load()
        projects = loaded.projects
        configErrors = loaded.errors
        loaded.errors.forEach { print("Erro no registro \($0)") }
    }

    func key(_ project: Project, _ service: ServiceConfig) -> ServiceKey {
        ServiceKey(project: project.name, service: service.name)
    }

    func status(_ key: ServiceKey) -> ServiceStatus {
        statuses[key] ?? .stopped
    }

    func isActive(_ key: ServiceKey) -> Bool {
        pids[key] != nil
    }

    func logURL(_ key: ServiceKey) -> URL {
        ConfigStore.logURL(project: key.project, service: key.service)
    }

    func pid(_ key: ServiceKey) -> pid_t? {
        pids[key]
    }

    func serviceURL(_ project: Project, _ service: ServiceConfig) -> URL? {
        let key = key(project, service)
        guard pids[key] != nil else { return nil }
        if let configured = service.url {
            return URL(string: configured)
        }
        if let url = detectedURLs[key] {
            return url
        }
        let url = logURL(key)
        let size = LogReader.size(url)
        guard scannedSizes[key] != size else { return nil }
        scannedSizes[key] = size
        detectedURLs[key] = LogReader.localURL(in: url, currentRunOnly: true)
        return detectedURLs[key]
    }

    func hasLog(_ key: ServiceKey) -> Bool {
        FileManager.default.fileExists(atPath: logURL(key).path)
    }

    func port(_ project: Project, _ service: ServiceConfig) -> Int? {
        if let port = service.port {
            return port
        }
        if let value = service.env?["PORT"], let port = Int(value) {
            return port
        }
        if let configured = service.url, let port = URL(string: configured)?.port {
            return port
        }
        return LogReader.localURL(in: logURL(key(project, service)), currentRunOnly: true)?.port
    }

    func service(owning pid: pid_t) -> ServiceKey? {
        let group = getpgid(pid)
        return pids.first { $0.value == pid || $0.value == group }?.key
    }

    func describe(_ owner: PortOwner) -> String {
        let label = service(owning: owner.pid).map { " — \($0.project)/\($0.service)" } ?? ""
        return "\(owner.name) (pid \(owner.pid))\(label)"
    }

    func start(_ project: Project, _ service: ServiceConfig, interactive: Bool = false) {
        let key = key(project, service)
        guard pids[key] == nil else { return }
        if let port = port(project, service) {
            let owners = PortGuard.owners(of: port)
            if !owners.isEmpty {
                print("Porta \(port) de \(key.project)/\(key.service) em uso: \(owners.map(describe).joined(separator: ", "))")
                if interactive, let onPortConflict {
                    onPortConflict(project, service, port, owners)
                    return
                }
                append(logURL(key), "\n===== aviso: porta \(port) em uso por \(owners.map(describe).joined(separator: ", ")) =====\n")
            }
        }
        launch(project, service)
    }

    func freePort(_ port: Int, owners: [PortOwner], then next: @escaping () -> Void) {
        for owner in owners {
            if let key = service(owning: owner.pid) {
                stop(key)
            } else {
                kill(owner.pid, SIGTERM)
            }
        }
        print("Liberando porta \(port)")
        let deadline = Date().addingTimeInterval(5)
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            MainActor.assumeIsolated {
                let remaining = PortGuard.owners(of: port)
                guard remaining.isEmpty || Date() > deadline else { return }
                timer.invalidate()
                remaining.filter { self.service(owning: $0.pid) == nil }.forEach { kill($0.pid, SIGKILL) }
                next()
            }
        }
    }

    func launch(_ project: Project, _ service: ServiceConfig) {
        let key = key(project, service)
        guard pids[key] == nil else { return }

        let url = logURL(key)
        let directory = project.directory(for: service)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        append(url, "\n===== iniciando `\(service.command)` em \(directory) — \(timestamp()) =====\n")

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let rc = shell.hasSuffix("zsh") ? "[ -f ~/.zshrc ] && source ~/.zshrc >/dev/null 2>&1; " : ""
        let script = rc + "cd \(shellQuote(directory)) && \(service.command)"

        var env = ProcessInfo.processInfo.environment
        env["FORCE_COLOR"] = env["FORCE_COLOR"] ?? "1"
        env["CLICOLOR_FORCE"] = env["CLICOLOR_FORCE"] ?? "1"
        service.env?.forEach { env[$0.key] = $0.value }

        let pid: pid_t
        do {
            pid = try spawn(shell, ["-l", "-c", script], env: env, logPath: url.path)
        } catch {
            append(url, "===== falha ao iniciar: \(error.localizedDescription) =====\n")
            statuses[key] = .exited(-1)
            print("Falha ao iniciar \(key.project)/\(key.service): \(error)")
            return
        }

        pids[key] = pid
        detectedURLs[key] = nil
        scannedSizes[key] = nil
        statuses[key] = .running
        print("Serviço \(key.project)/\(key.service) iniciado com pid \(pid)")

        DispatchQueue.global().async {
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) == -1 && errno == EINTR {}
            let signal = raw & 0x7f
            let code = signal == 0 ? (raw >> 8) & 0xff : 128 + signal
            DispatchQueue.main.async {
                self.handleExit(key, pid: pid, code: code)
            }
        }
    }

    func stop(_ key: ServiceKey) {
        scheduledRestarts.remove(key)
        crashTimes[key] = nil
        guard let pid = pids[key] else { return }
        statuses[key] = .stopping
        kill(-pid, SIGTERM)
        print("Enviando SIGTERM para \(key.project)/\(key.service)")
        DispatchQueue.main.asyncAfter(deadline: .now() + killTimeout) {
            if self.pids[key] == pid {
                kill(-pid, SIGKILL)
                print("Forçando SIGKILL em \(key.project)/\(key.service)")
            }
        }
    }

    func restart(_ project: Project, _ service: ServiceConfig, interactive: Bool = false) {
        let key = key(project, service)
        if pids[key] != nil {
            pendingRestart.insert(key)
            stop(key)
        } else {
            start(project, service, interactive: interactive)
        }
    }

    func startAll(_ project: Project, interactive: Bool = false) {
        project.services.forEach { start(project, $0, interactive: interactive) }
    }

    func stopAll(_ project: Project) {
        project.services.forEach { stop(key(project, $0)) }
    }

    func openLog(_ key: ServiceKey) {
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open([logURL(key)], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
    }

    func signalAll(_ signal: Int32) {
        pids.values.forEach { kill(-$0, signal) }
    }

    func quit() {
        pendingRestart.removeAll()
        scheduledRestarts.removeAll()
        pids.keys.forEach { stop($0) }
        let deadline = Date().addingTimeInterval(killTimeout)
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            MainActor.assumeIsolated {
                if self.pids.isEmpty || Date() > deadline {
                    timer.invalidate()
                    self.signalAll(SIGKILL)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func handleExit(_ key: ServiceKey, pid: pid_t, code: Int32) {
        guard pids[key] == pid else { return }
        kill(-pid, SIGTERM)
        pids[key] = nil
        watchers.removeValue(forKey: key)?.cancel()
        let wasStopping = statuses[key] == .stopping
        statuses[key] = wasStopping ? .stopped : .exited(code)
        append(logURL(key), "\n===== encerrado com código \(code) — \(timestamp()) =====\n")
        print("Serviço \(key.project)/\(key.service) encerrado com código \(code)")
        let found = projects.first(where: { $0.name == key.project }).flatMap { project in
            project.services.first(where: { $0.name == key.service }).map { (project, $0) }
        }
        if !wasStopping && code != 0 {
            onCrash?(key, status(key), found?.1.restart == true ? scheduleRestart(key) : nil)
        }

        if pendingRestart.remove(key) != nil, let (project, service) = found {
            start(project, service)
        }
    }

    private func scheduleRestart(_ key: ServiceKey) -> String {
        let now = Date()
        let recent = (crashTimes[key] ?? []).filter { now.timeIntervalSince($0) < restartWindow } + [now]
        crashTimes[key] = recent
        guard recent.count <= maxRestarts else {
            append(logURL(key), "===== reinício automático suspenso após \(maxRestarts) quedas em 1 minuto =====\n")
            print("Reinício automático de \(key.project)/\(key.service) suspenso")
            return "Reinício automático suspenso após \(maxRestarts) quedas em 1 minuto"
        }
        scheduledRestarts.insert(key)
        append(logURL(key), "===== reiniciando automaticamente em \(Int(restartDelay))s (tentativa \(recent.count) de \(maxRestarts)) =====\n")
        DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay) {
            guard self.scheduledRestarts.remove(key) != nil, self.pids[key] == nil,
                  let project = self.projects.first(where: { $0.name == key.project }),
                  let service = project.services.first(where: { $0.name == key.service }) else { return }
            print("Reiniciando automaticamente \(key.project)/\(key.service)")
            self.start(project, service)
        }
        return "Reiniciando em \(Int(restartDelay))s (tentativa \(recent.count) de \(maxRestarts))"
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    private func saveState() {
        let entries = pids.map { RunningEntry(key: $0.key, pid: $0.value) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: ConfigStore.stateFile)
    }

    private func adopt() {
        guard let data = try? Data(contentsOf: ConfigStore.stateFile),
              let entries = try? JSONDecoder().decode([RunningEntry].self, from: data) else { return }
        for entry in entries where getpgid(entry.pid) == entry.pid && kill(entry.pid, 0) == 0 {
            pids[entry.key] = entry.pid
            statuses[entry.key] = .running
            watch(entry.key, pid: entry.pid)
            print("Serviço \(entry.key.project)/\(entry.key.service) retomado com pid \(entry.pid)")
        }
        saveState()
    }

    private func watch(_ key: ServiceKey, pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            self?.handleExit(key, pid: pid, code: -1)
        }
        watchers[key] = source
        source.resume()
        if kill(pid, 0) != 0 {
            handleExit(key, pid: pid, code: -1)
        }
    }

    private func append(_ url: URL, _ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func spawn(_ path: String, _ args: [String], env: [String: String], logPath: String) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attr, argv, envp)
        if result != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(result))
        }
        return pid
    }
}
