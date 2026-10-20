import Foundation

struct ServiceConfig: Codable, Hashable {
    var name: String
    var command: String
    var env: [String: String]?
}

struct ProjectFile: Codable {
    var name: String?
    var path: String
    var services: [ServiceConfig]
}

struct Project {
    let name: String
    let path: String
    let services: [ServiceConfig]
    let file: URL

    var expandedPath: String { (path as NSString).expandingTildeInPath }
}

enum ConfigStore {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let directory = home.appendingPathComponent(".config/runyard")
    static let projectsDirectory = directory.appendingPathComponent("projects")
    static let logsDirectory = home.appendingPathComponent("Library/Logs/runyard")

    static func load() -> (projects: [Project], errors: [String]) {
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
