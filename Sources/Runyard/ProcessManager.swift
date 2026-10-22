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
    var onCrash: ((ServiceKey, ServiceStatus) -> Void)?

    private var pids: [ServiceKey: pid_t] = [:] {
        didSet { saveState() }
    }
    private var watchers: [ServiceKey: DispatchSourceProcess] = [:]
    private var pendingRestart: Set<ServiceKey> = []
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

    func hasLog(_ key: ServiceKey) -> Bool {
        FileManager.default.fileExists(atPath: logURL(key).path)
    }

    func start(_ project: Project, _ service: ServiceConfig) {
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

    func restart(_ project: Project, _ service: ServiceConfig) {
        let key = key(project, service)
        if pids[key] != nil {
            pendingRestart.insert(key)
            stop(key)
        } else {
            start(project, service)
        }
    }

    func startAll(_ project: Project) {
        project.services.forEach { start(project, $0) }
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
        if !wasStopping && code != 0 {
            onCrash?(key, status(key))
        }

        if pendingRestart.remove(key) != nil,
           let project = projects.first(where: { $0.name == key.project }),
           let service = project.services.first(where: { $0.name == key.service }) {
            start(project, service)
        }
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
