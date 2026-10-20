import Foundation
import RunyardCore

let usage = """
Uso:
  runyard status [projeto]
  runyard start <projeto> [serviço...]
  runyard stop <projeto> [serviço...]
  runyard restart <projeto> [serviço...]
  runyard logs <projeto> <serviço> [-n linhas] [-f] [--path]

Sem serviço, start, stop e restart agem em todos os serviços do projeto.
"""

func fail(_ message: String) -> Never {
    fflush(stdout)
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func connect() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = ControlSocket.address()
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if result == 0 { return fd }
    close(fd)
    return nil
}

func openApp() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", "-b", "local.runyard"]
    try? process.run()
    process.waitUntilExit()
}

func send(_ request: ControlRequest) -> ControlResponse {
    var fd = connect()
    if fd == nil {
        FileHandle.standardError.write("Runyard não está aberto. Abrindo o app...\n".data(using: .utf8)!)
        openApp()
        for _ in 0..<40 where fd == nil {
            usleep(250_000)
            fd = connect()
        }
    }
    guard let fd else { fail("Não foi possível falar com o Runyard em \(ConfigStore.socketPath)") }
    defer { close(fd) }
    ControlSocket.write(fd, try! JSONEncoder().encode(request))
    let data = ControlSocket.readLine(fd)
    guard let response = try? JSONDecoder().decode(ControlResponse.self, from: data) else {
        fail("Resposta inválida do Runyard")
    }
    return response
}

func render(_ reports: [ServiceReport]) {
    let width = reports.map(\.service.count).max() ?? 0
    var current: String?
    for report in reports {
        if report.project != current {
            print(report.project)
            current = report.project
        }
        let name = report.service.padding(toLength: width, withPad: " ", startingAt: 0)
        let status = report.status.padding(toLength: max(report.status.count, 10), withPad: " ", startingAt: 0)
        let pid = report.pid.map { "pid \($0)" } ?? ""
        let line = "  \(name)  \(status)  \(pid)"
        print(line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
    }
}

func settle(_ project: String, _ services: [String]) -> ControlResponse {
    var response = send(ControlRequest(action: "status", project: project, services: services))
    let deadline = Date().addingTimeInterval(20)
    while response.services.contains(where: { $0.status == "parando" }) && Date() < deadline {
        usleep(500_000)
        response = send(ControlRequest(action: "status", project: project, services: services))
    }
    usleep(1_500_000)
    return send(ControlRequest(action: "status", project: project, services: services))
}

func showLogs(_ args: [String]) -> Never {
    var positional: [String] = []
    var lines = "100"
    var follow = false
    var pathOnly = false
    var index = 0
    while index < args.count {
        switch args[index] {
        case "-n":
            index += 1
            guard index < args.count else { fail("Informe o número de linhas depois de -n") }
            lines = args[index]
        case "-f":
            follow = true
        case "--path":
            pathOnly = true
        default:
            positional.append(args[index])
        }
        index += 1
    }
    guard positional.count == 2 else { fail(usage) }

    let url = ConfigStore.logURL(project: positional[0], service: positional[1])
    if pathOnly {
        print(url.path)
        exit(0)
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
        fail("Sem log em \(url.path)")
    }
    var argv = ["tail", "-n", lines]
    if follow { argv.append("-f") }
    argv.append(url.path)
    let cArgs = argv.map { strdup($0) } + [nil]
    execv("/usr/bin/tail", cArgs)
    fail("Falha ao executar tail")
}

let args = Array(CommandLine.arguments.dropFirst())
guard let action = args.first else { fail(usage) }
let rest = Array(args.dropFirst())

switch action {
case "status":
    let response = send(ControlRequest(action: "status", project: rest.first))
    guard response.ok else { fail(response.message ?? "Erro") }
    render(response.services)
case "start", "stop", "restart":
    guard let project = rest.first else { fail(usage) }
    let services = Array(rest.dropFirst())
    let response = send(ControlRequest(action: action, project: project, services: services))
    guard response.ok else { fail(response.message ?? "Erro") }
    let final = settle(project, services)
    render(final.services)
    if action != "stop" && final.services.contains(where: { $0.status != "rodando" }) {
        fail("Algum serviço não ficou rodando. Veja com: runyard logs \(project) <serviço>")
    }
case "logs":
    showLogs(rest)
case "help", "-h", "--help":
    print(usage)
default:
    fail(usage)
}
