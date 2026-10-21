import Foundation
import Darwin

enum PortBarVersion {
    static let current = "1.1.0"
}

struct AutomationError: Error {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

struct AutomationRequest: Codable {
    var version = 1
    var id = UUID().uuidString
    var command: String
    var options: [String: String] = [:]
    var payload: Data? = nil
}

enum AutomationJSON {
    static func data(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
    }
    static func object<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }
    static func failure(_ error: Error, requestId: String? = nil) -> [String: Any] {
        let failure = error as? AutomationError ?? AutomationError("INTERNAL_ERROR", "操作失败，请查看 PortBar。")
        return ["ok": false, "requestId": requestId ?? "", "error": ["code": failure.code, "message": failure.message]]
    }
}

/// One newline-delimited JSON request per connection. The application owns all state.
enum LocalIPC {
    static let maxMessageBytes = 1_048_576
    static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["PORTBAR_SOCKET"] { return override }
        return "/tmp/portbar-\(getuid())/control.sock"
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw AutomationError("INVALID_SOCKET_PATH", "本地 socket 路径过长。")
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { target in target.copyBytes(from: bytes) }
        return addr
    }

    static func configure(_ fd: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    static func read(_ fd: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while result.count <= maxMessageBytes {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw AutomationError("IPC_ERROR", "本地连接中断或超时。") }
            result.append(contentsOf: buffer.prefix(count))
            if let newline = result.firstIndex(of: 10) {
                guard newline <= maxMessageBytes else { break }
                return result.prefix(upTo: newline)
            }
        }
        throw AutomationError("PAYLOAD_TOO_LARGE", "请求或响应超过 1 MiB 限制。")
    }

    static func write(_ data: Data, to fd: Int32) throws {
        // JSONEncoder emits a single line. Pretty printed JSON is not valid framing.
        guard data.count <= maxMessageBytes else { throw AutomationError("PAYLOAD_TOO_LARGE", "消息超过 1 MiB 限制。") }
        var framed = data
        framed.append(10)
        try framed.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw AutomationError("IPC_ERROR", "无法写入本地连接。") }
                sent += count
            }
        }
    }

    static func call(_ request: AutomationRequest) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AutomationError("IPC_ERROR", "无法创建本地连接。") }
        defer { close(fd) }
        configure(fd)
        var addr = try address(socketPath)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw AutomationError("APP_NOT_RUNNING", "无法连接 PortBar。请先打开应用，再在设置中启用 CLI。")
        }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == getuid() else {
            throw AutomationError("PERMISSION_DENIED", "socket 不属于当前用户。")
        }
        try write(JSONEncoder().encode(request), to: fd)
        guard let response = try JSONSerialization.jsonObject(with: read(fd)) as? [String: Any],
              response["requestId"] as? String == request.id else {
            throw AutomationError("IPC_ERROR", "本地响应格式无效。")
        }
        return response
    }
}

final class AutomationServer {
    private var fd: Int32 = -1
    private var lockFD: Int32 = -1
    private let path: String
    private let service: AutomationService
    init(service: AutomationService = .shared, path: String = LocalIPC.socketPath) {
        self.service = service
        self.path = path
    }

    func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        if mkdir(directory, 0o700) != 0 && errno != EEXIST {
            throw AutomationError("IPC_ERROR", "无法创建 CLI 目录。")
        }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o077) == 0 else {
            throw AutomationError("PERMISSION_DENIED", "CLI 目录必须由当前用户持有，且权限为 0700。")
        }
        // A lifetime lock prevents two simultaneous launches from unlinking each other's socket.
        var started = false
        defer {
            if !started {
                if fd >= 0 { close(fd); fd = -1 }
                if lockFD >= 0 { close(lockFD); lockFD = -1 }
            }
        }
        lockFD = open(directory + "/controller.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, fstat(lockFD, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == S_IFREG, (info.st_mode & 0o077) == 0 else {
            throw AutomationError("PERMISSION_DENIED", "无法取得 CLI 服务锁。")
        }
        _ = fcntl(lockFD, F_SETFD, FD_CLOEXEC)
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw AutomationError("ALREADY_RUNNING", "PortBar CLI 服务已运行。")
        }
        var addr = try LocalIPC.address(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AutomationError("IPC_ERROR", "无法创建 CLI socket。") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // Never unlink an active instance's socket.
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        let active = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        close(probe)
        guard !active else { close(fd); fd = -1; throw AutomationError("ALREADY_RUNNING", "PortBar CLI 服务已运行。") }
        if lstat(path, &info) == 0 {
            guard info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK else {
                close(fd); fd = -1
                throw AutomationError("PERMISSION_DENIED", "CLI 路径存在非 socket 文件。")
            }
            unlink(path)
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd); fd = -1
            throw AutomationError("IPC_ERROR", "无法监听 CLI socket。")
        }
        started = true
        let listeningFD = fd
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let client = accept(listeningFD, nil, nil)
                if client < 0 { if errno == EINTR { continue }; break }
                LocalIPC.configure(client)
                // A bounded serial worker prevents an unbounded queue of local requests.
                handle(client)
                close(client)
            }
        }
    }

    func stop() {
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd); fd = -1; unlink(path) }
        if lockFD >= 0 { close(lockFD); lockFD = -1 }
    }

    private func handle(_ client: Int32) {
        var requestId: String?
        do {
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                throw AutomationError("PERMISSION_DENIED", "仅当前用户可以调用 CLI。")
            }
            let bytes = try LocalIPC.read(client)
            let request: AutomationRequest
            do { request = try JSONDecoder().decode(AutomationRequest.self, from: bytes) }
            catch { throw AutomationError("INVALID_ARGUMENT", "CLI 请求格式无效。") }
            requestId = request.id
            let response: [String: Any] = DispatchQueue.main.sync { service.handle(request) }
            try LocalIPC.write(JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]), to: client)
        } catch {
            let response = AutomationJSON.failure(error, requestId: requestId)
            if let data = try? JSONSerialization.data(withJSONObject: response) { try? LocalIPC.write(data, to: client) }
        }
    }
}
