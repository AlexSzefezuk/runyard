import Foundation
import RunyardCore

@MainActor
final class ControlServer {
    private let manager: ProcessManager
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?

    init(manager: ProcessManager) {
        self.manager = manager
    }

    func start() {
        let path = ConfigStore.socketPath
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            print("Erro ao criar socket de controle")
            return
        }

        var address = ControlSocket.address()
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 16) == 0 else {
            print("Erro ao escutar em \(path): \(String(cString: strerror(errno)))")
            close(listener)
            return
        }
        chmod(path, 0o600)

        let fd = listener
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            self?.serve(client)
        }
        source.resume()
        self.source = source
        print("Socket de controle escutando em \(path)")
    }

    nonisolated private func serve(_ client: Int32) {
        defer { close(client) }
        let data = ControlSocket.readLine(client)
        let response: ControlResponse
        if let request = try? JSONDecoder().decode(ControlRequest.self, from: data) {
            response = DispatchQueue.main.sync {
                MainActor.assumeIsolated { self.handle(request) }
            }
        } else {
            response = ControlResponse(ok: false, message: "Pedido inválido")
        }
        if let encoded = try? JSONEncoder().encode(response) {
            ControlSocket.write(client, encoded)
        }
    }

    private func handle(_ request: ControlRequest) -> ControlResponse {
        manager.reload()
        print("Pedido da CLI: \(request.action) \(request.project ?? "") \(request.services.joined(separator: " "))")

        if request.action == "status" && request.project == nil {
            return ControlResponse(ok: true, services: manager.projects.flatMap { reports($0, $0.services) })
        }

        guard let name = request.project else {
            return ControlResponse(ok: false, message: "Informe o projeto")
        }
        guard let project = manager.projects.first(where: { $0.name == name }) else {
            let names = manager.projects.map(\.name).joined(separator: ", ")
            return ControlResponse(ok: false, message: "Projeto \(name) não registrado. Projetos: \(names)")
        }

        var services: [ServiceConfig] = []
        for serviceName in request.services {
            guard let service = project.services.first(where: { $0.name == serviceName }) else {
                let names = project.services.map(\.name).joined(separator: ", ")
                return ControlResponse(ok: false, message: "Serviço \(serviceName) não existe em \(name). Serviços: \(names)")
            }
            services.append(service)
        }
        if services.isEmpty {
            services = project.services
        }

        switch request.action {
        case "status":
            break
        case "start":
            services.forEach { manager.start(project, $0) }
        case "stop":
            services.forEach { manager.stop(manager.key(project, $0)) }
        case "restart":
            services.forEach { manager.restart(project, $0) }
        default:
            return ControlResponse(ok: false, message: "Ação desconhecida: \(request.action)")
        }
        return ControlResponse(ok: true, services: reports(project, services))
    }

    private func reports(_ project: Project, _ services: [ServiceConfig]) -> [ServiceReport] {
        services.map { service in
            let key = manager.key(project, service)
            return ServiceReport(
                project: project.name,
                service: service.name,
                status: describe(manager.status(key)),
                pid: manager.pid(key),
                log: manager.logURL(key).path
            )
        }
    }

    private func describe(_ status: ServiceStatus) -> String {
        switch status {
        case .running: "rodando"
        case .stopping: "parando"
        case .stopped: "parado"
        case .exited(0): "encerrado"
        case .exited(-1): "encerrado (código desconhecido)"
        case .exited(let code): "erro (código \(code))"
        }
    }
}
