import Foundation

public struct ServiceConfig: Codable, Hashable, Sendable {
    public var name: String
    public var command: String
    public var path: String?
    public var env: [String: String]?
}

struct ProjectFile: Codable {
    var name: String?
    var path: String
    var services: [ServiceConfig]
}

public struct Project: Sendable {
    public let name: String
    public let path: String
    public let services: [ServiceConfig]
    public let file: URL

    public var expandedPath: String { (path as NSString).expandingTildeInPath }

    public func directory(for service: ServiceConfig) -> String {
        guard let servicePath = service.path else { return expandedPath }
        let expanded = (servicePath as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return (expandedPath as NSString).appendingPathComponent(expanded)
    }
}

public enum ConfigStore {
    public static let home = FileManager.default.homeDirectoryForCurrentUser
    public static let directory = home.appendingPathComponent(".config/runyard")
    public static let projectsDirectory = directory.appendingPathComponent("projects")
    public static let logsDirectory = home.appendingPathComponent("Library/Logs/runyard")
    public static let stateFile = directory.appendingPathComponent("state.json")
    public static let socketPath = directory.appendingPathComponent("runyard.sock").path

    public static func logURL(project: String, service: String) -> URL {
        logsDirectory
            .appendingPathComponent(sanitize(project))
            .appendingPathComponent(sanitize(service) + ".log")
    }

    private static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
    }

    public static func load() -> (projects: [Project], errors: [String]) {
        let manager = FileManager.default
        try? manager.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        let files = ((try? manager.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var projects: [Project] = []
        var errors: [String] = []
        for file in files {
            do {
                let data = try Data(contentsOf: file)
                let parsed = try JSONDecoder().decode(ProjectFile.self, from: data)
                projects.append(Project(
                    name: parsed.name ?? file.deletingPathExtension().lastPathComponent,
                    path: parsed.path,
                    services: parsed.services,
                    file: file
                ))
            } catch {
                errors.append("\(file.lastPathComponent): \(describe(error))")
            }
        }
        return (projects, errors)
    }

    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "campo obrigatório ausente: \(fieldPath(context.codingPath + [key]))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "tipo inválido em \(fieldPath(context.codingPath))"
        case .dataCorrupted:
            return "JSON inválido"
        @unknown default:
            return "erro de leitura"
        }
    }

    private static func fieldPath(_ path: [CodingKey]) -> String {
        path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }
}
