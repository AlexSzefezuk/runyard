import Darwin
import Foundation

struct PortOwner {
    let pid: pid_t
    let name: String
}

enum PortGuard {
    static func owners(of port: Int) -> [PortOwner] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            print("Falha ao executar lsof: \(error.localizedDescription)")
            return []
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let pids = Set(output.split(whereSeparator: \.isNewline).compactMap { pid_t($0) })
        return pids.sorted().map { PortOwner(pid: $0, name: name(of: $0)) }
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "processo" }
        return String(cString: buffer)
    }
}
