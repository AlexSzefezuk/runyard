import Foundation

public struct ControlRequest: Codable, Sendable {
    public var action: String
    public var project: String?
    public var services: [String]

    public init(action: String, project: String? = nil, services: [String] = []) {
        self.action = action
        self.project = project
        self.services = services
    }
}

public struct ServiceReport: Codable, Sendable {
    public var project: String
    public var service: String
    public var status: String
    public var pid: Int32?
    public var log: String

    public init(project: String, service: String, status: String, pid: Int32?, log: String) {
        self.project = project
        self.service = service
        self.status = status
        self.pid = pid
        self.log = log
    }
}

public struct ControlResponse: Codable, Sendable {
    public var ok: Bool
    public var message: String?
    public var services: [ServiceReport]

    public init(ok: Bool, message: String? = nil, services: [ServiceReport] = []) {
        self.ok = ok
        self.message = message
        self.services = services
    }
}

public enum ControlSocket {
    public static func address() -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(ConfigStore.socketPath.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.prefix(buffer.count - 1).enumerated() {
                buffer[index] = UInt8(bitPattern: byte)
            }
        }
        return address
    }

    public static func readLine(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if buffer[0..<count].contains(UInt8(ascii: "\n")) { break }
        }
        return data
    }

    public static func write(_ fd: Int32, _ data: Data) {
        var payload = data
        payload.append(UInt8(ascii: "\n"))
        payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if sent <= 0 { break }
                offset += sent
            }
        }
    }
}
