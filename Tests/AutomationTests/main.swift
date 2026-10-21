import Foundation
import Darwin

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

func spin(until condition: () -> Bool, seconds: Double = 3) {
    let end = Date().addingTimeInterval(seconds)
    while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}

func unusedPort() -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { check(bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0, "bind ephemeral port") }
    }
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafeMutablePointer(to: &addr) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &size) } }
    return Int(UInt16(bigEndian: addr.sin_port))
}

// Controlled SSH replacement: listen locally without connecting to any real host.
if CommandLine.arguments.dropFirst().first == "--fake-ssh" {
    let args = CommandLine.arguments
    if args.contains(where: { $0.hasSuffix("@auth-failure.test") }) {
        fputs("Permission denied (publickey).\n", stderr)
        exit(255)
    }
    var ports: [Int] = []
    for index in args.indices where args[index] == "-L" || args[index] == "-D" {
        if index + 1 < args.count, let port = Int(args[index + 1].components(separatedBy: ":")[1]) { ports.append(port) }
    }
    if args.contains(where: { $0.hasSuffix("@partial.test") }) { ports = Array(ports.prefix(1)) }
    if args.contains(where: { $0.hasSuffix("@slow.test") }) { Thread.sleep(forTimeInterval: 2) }
    var sockets: [Int32] = []
    for port in ports {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if bound != 0 || listen(fd, 64) != 0 { fputs("Address already in use\n", stderr); exit(255) }
        sockets.append(fd)
    }
    while true {
        var pollFDs = sockets.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
        if poll(&pollFDs, nfds_t(pollFDs.count), 1000) > 0 {
            for item in pollFDs where item.revents & Int16(POLLIN) != 0 {
                let client = accept(item.fd, nil, nil)
                if client >= 0 { close(client) }
            }
        }
    }
}

let testDirectory: URL
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--serve" {
    testDirectory = URL(fileURLWithPath: CommandLine.arguments[2])
} else {
    testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("portbar-tests-\(UUID().uuidString)")
}
try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
let store = ConfigStore(directory: testDirectory, seedDemo: false)
let suite = "portbar-tests-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let fakeSSH = testDirectory.appendingPathComponent("fake-ssh")
let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path.replacingOccurrences(of: "'", with: "'\\''")
try "#!/bin/sh\nexec '\(executable)' --fake-ssh \"$@\"\n".write(to: fakeSSH, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
let manager = SSHTunnelManager(store: store, sshExecutable: fakeSSH)
let service = AutomationService(store: store, manager: manager, defaults: defaults)

if CommandLine.arguments.dropFirst().first == "--serve" {
    defaults.set(3, forKey: "portbar_cli_access")
    let server = AutomationServer(service: service)
    do { try server.start() }
    catch { fputs("SERVER_ERROR: \((error as? AutomationError)?.code ?? "UNKNOWN")\n", stderr); exit(1) }
    print("READY")
    fflush(stdout)
    RunLoop.main.run()
    exit(0)
}
defer { manager.stopAll(); try? FileManager.default.removeItem(at: testDirectory) }

func call(_ command: String, _ options: [String: String] = [:], payload: [String: Any]? = nil) -> [String: Any] {
    let bytes = payload.map { try! JSONSerialization.data(withJSONObject: $0) }
    return service.handle(AutomationRequest(command: command, options: options, payload: bytes))
}
func code(_ response: [String: Any]) -> String { (response["error"] as? [String: Any])?["code"] as? String ?? "" }
func data(_ response: [String: Any]) -> [String: Any] { response["data"] as? [String: Any] ?? [:] }

check(code(call("hosts.list")) == "PERMISSION_DENIED", "disabled access denied")
check(call("capabilities")["ok"] as? Bool == true, "capabilities available while disabled")
defaults.set(1, forKey: "portbar_cli_access")
check(call("hosts.list")["ok"] as? Bool == true, "read access")
check(code(call("hosts.create", payload: ["host": "localhost"])) == "PERMISSION_DENIED", "read cannot edit")
defaults.set(2, forKey: "portbar_cli_access")
check(code(call("mappings.create", payload: ["name": "test"])) == "PERMISSION_DENIED", "control cannot edit")
defaults.set(3, forKey: "portbar_cli_access")

let revision = store.revision
let preview = call("hosts.create", ["dry-run": "true"], payload: ["host": "localhost", "name": "local"])
check(preview["ok"] as? Bool == true && store.hosts.isEmpty && store.revision == revision, "dry run never saves")
let created = call("hosts.create", ["if-revision": revision], payload: ["host": "localhost", "name": "local", "username": "ubuntu"])
let hostID = (data(created)["after"] as! [String: Any])["id"] as! String
check(store.hosts.count == 1 && store.revision != revision, "committed host published")
check(code(call("hosts.update", ["host-id": hostID, "if-revision": revision], payload: ["name": "stale"])) == "REVISION_CONFLICT", "stale revision rejected")
check(code(call("hosts.create", payload: ["host": "localhost", "password": "secret"])) == "INVALID_ARGUMENT", "credential input rejected")
check(code(call("hosts.create", payload: ["host": "-oProxyCommand=bad"])) == "INVALID_ARGUMENT", "SSH argument injection rejected")
check(code(call("hosts.create", payload: ["host": "localhost", "port": 65536])) == "INVALID_ARGUMENT", "bad SSH port")
check(code(call("hosts.list", ["limit": "0"])) == "INVALID_ARGUMENT", "invalid limit")
check(code(call("hosts.list", ["file": "secret"])) == "INVALID_ARGUMENT", "unexpected option")
check(code(call("hosts.get", ["host-id": "not-a-uuid"])) == "INVALID_ARGUMENT", "invalid UUID")

var credentialHost = store.hosts[0]
credentialHost.password = "sensitive-test-password"
credentialHost.notes = "sensitive-test-password"
try store.commit(PortBarData(hosts: [credentialHost], mappings: []))
let hostOutput = try AutomationJSON.data(call("hosts.get", ["host-id": hostID]))
check(!String(decoding: hostOutput, as: UTF8.self).contains("sensitive-test-password"), "password and notes redacted")
check((data(call("hosts.get", ["host-id": hostID]))["hasCredential"] as? Bool) == true, "credential existence available")
credentialHost.password = ""
try store.commit(PortBarData(hosts: [credentialHost], mappings: []))

let p1 = unusedPort()
var p2 = unusedPort()
while p1 == p2 { p2 = unusedPort() }
let mappingPayload: [String: Any] = ["hostId": hostID, "name": "db", "portRules": [
    ["localPort": p1, "remotePort": 3306], ["localPort": p2, "remotePort": 6379]
]]
let mappingResponse = call("mappings.create", payload: mappingPayload)
check(mappingResponse["ok"] as? Bool == true, "create multiport mapping")
let mappingID = (data(mappingResponse)["after"] as! [String: Any])["id"] as! String
let mappingUUID = UUID(uuidString: mappingID)!
let mappingOptions = ["mapping-id": mappingID]
check(code(call("mappings.update", mappingOptions, payload: ["portRules": [["localPort": 0, "remotePort": 22]]])) == "INVALID_ARGUMENT", "bad local port rejected")
check(code(call("mappings.update", mappingOptions, payload: ["portRules": [["localPort": p1, "remotePort": 22], ["localPort": p1, "remotePort": 23]]])) == "INVALID_ARGUMENT", "duplicate port rejected")
check(code(call("mappings.update", mappingOptions, payload: ["portRules": [["localPort": p1, "remotePort": 22, "unknown": true]]])) == "INVALID_ARGUMENT", "nested unknown fields rejected")
check(code(call("hosts.delete", ["host-id": hostID])) == "HAS_DEPENDENCIES", "cascade requires explicit flag")

_ = call("tunnels.start", mappingOptions)
spin(until: { manager.status(for: mappingUUID).isConnected })
check(manager.status(for: mappingUUID).isConnected, "all local listeners ready")
let operationID = manager.operationIDs[mappingUUID]
_ = call("tunnels.start", mappingOptions)
check(manager.operationIDs[mappingUUID] == operationID, "start is idempotent")
check(code(call("mappings.update", mappingOptions, payload: ["name": "running"])) == "RESOURCE_BUSY", "running mapping cannot be edited")
check(code(call("hosts.delete", ["host-id": hostID, "cascade": "true"])) == "RESOURCE_BUSY", "running host cannot be deleted")
check(data(call("tunnels.diagnose", mappingOptions))["remoteServiceReachability"] as? String == "not_tested", "diagnosis doesn't claim remote health")
_ = call("tunnels.stop", mappingOptions)
spin(until: { manager.status(for: mappingUUID) == .disconnected })
check(manager.status(for: mappingUUID) == .disconnected && !manager.isManaged(mappingUUID), "stop completes")
let stopOperationID = manager.operationIDs[mappingUUID]
_ = call("tunnels.stop", mappingOptions)
check(manager.operationIDs[mappingUUID] == stopOperationID, "stop is idempotent")

_ = call("hosts.update", ["host-id": hostID], payload: ["host": "auth-failure.test"])
_ = call("tunnels.start", mappingOptions)
spin(until: { if case .error = manager.status(for: mappingUUID) { return true }; return false })
check(manager.failureCodes[mappingUUID] == "AUTH_FAILED", "authentication error classified")
_ = call("tunnels.stop", mappingOptions)
_ = call("hosts.update", ["host-id": hostID], payload: ["host": "partial.test"])
_ = call("tunnels.start", mappingOptions)
spin(until: { NetworkDetector.shared.isLocalPortListening(port: p1) })
spin(until: { manager.status(for: mappingUUID).isConnected }, seconds: 0.5)
check(!manager.status(for: mappingUUID).isConnected, "one listener does not imply multiport readiness")
_ = call("tunnels.stop", mappingOptions)
spin(until: { !manager.isManaged(mappingUUID) })

_ = call("hosts.update", ["host-id": hostID], payload: ["host": "auth-failure.test"])
_ = call("mappings.update", mappingOptions, payload: ["autoReconnect": true])
_ = call("tunnels.start", mappingOptions)
spin(until: { if case .error = manager.status(for: mappingUUID) { return true }; return false })
check(manager.isManaged(mappingUUID), "pending reconnect is managed")
check(code(call("mappings.delete", mappingOptions)) == "RESOURCE_BUSY", "pending reconnect protects configuration")
manager.stopAll()
check(!manager.isManaged(mappingUUID), "stopAll cancels pending reconnects")
_ = call("mappings.update", mappingOptions, payload: ["autoReconnect": false])

let staleHost = store.hosts[0]
_ = call("hosts.update", ["host-id": hostID], payload: ["name": "updated externally"])
check(!store.updateHost(staleHost), "stale UI draft cannot overwrite CLI edits")
let diskStore = ConfigStore(directory: testDirectory, seedDemo: false)
check(diskStore.hosts[0].name == "updated externally", "disk matches published state")
let invalidDirectory = testDirectory.appendingPathComponent("gone")
let failingStore = ConfigStore(directory: invalidDirectory, seedDemo: false)
try FileManager.default.removeItem(at: invalidDirectory)
let failingService = AutomationService(store: failingStore, manager: manager, defaults: defaults)
let failed = failingService.handle(AutomationRequest(command: "hosts.create", payload: try JSONSerialization.data(withJSONObject: ["host": "localhost"])))
check(code(failed) == "SAVE_FAILED" && failingStore.hosts.isEmpty, "failed save does not publish success")

let beforeCascade = store.revision
let cascadePreview = call("hosts.delete", ["host-id": hostID, "cascade": "true", "dry-run": "true"])
check(data(cascadePreview)["affectedMappingIds"] as? [String] == [mappingID], "cascade preview lists affected IDs")
check(store.revision == beforeCascade && store.mappings.count == 1, "cascade preview unchanged")
_ = call("hosts.delete", ["host-id": hostID, "cascade": "true", "if-revision": beforeCascade])
check(store.hosts.isEmpty && store.mappings.isEmpty, "cascade committed")

do { _ = try PortBarCLI.parse(["tunnels", "start", "--wait", "--timeout", "NaN"]); check(false, "NaN timeout rejected") } catch {}
do { _ = try PortBarCLI.parse(["status", "--wait"]); check(false, "wait restricted") } catch {}
do { _ = try PortBarCLI.parse(["hosts", "list", "--json", "--json"]); check(false, "duplicate flag rejected") } catch {}
let parsed = try PortBarCLI.parse(["tunnels", "start", "--mapping-id", mappingID, "--wait", "--json"])
check(parsed.wait && parsed.timeout == 15 && parsed.request.command == "tunnels.start", "CLI parser")
let skillDirectory = testDirectory.appendingPathComponent("skills")
let installed = try PortBarCLI.installSkill(directory: skillDirectory)
check(FileManager.default.fileExists(atPath: installed.appendingPathComponent("SKILL.md").path), "skill installed")
do { _ = try PortBarCLI.installSkill(directory: skillDirectory); check(false, "skill overwrite rejected") } catch {}
print("PASS: automation permissions, config transactions, redaction, tunnel lifecycle, parser and Skill installation")
