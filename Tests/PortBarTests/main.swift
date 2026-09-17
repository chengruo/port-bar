import Foundation

func assert(_ condition: Bool, _ message: String) {
    if !condition {
        print("❌ ASSERTION FAILED: \(message)")
        exit(1)
    }
}

print("🧪 开始运行 PortBar 2.0 (解耦主机与映射) 自动化测试...")

// 1. Test SSHHost & PortMapping Models
print("▶️ [1/4] 测试 SSHHost 与 PortMapping 关联及 JSON 序列化...")
let host1 = SSHHost(
    name: "生产跳板机",
    host: "1.2.3.4",
    port: 2222,
    username: "devuser",
    password: "Complex!@#$%^&*()_+Pass",
    notes: "Production Host"
)

let mapping1 = PortMapping(
    name: "MySQL 3306",
    hostId: host1.id,
    forwardType: .localPort,
    localPort: 3307,
    remotePort: 3306,
    remoteHost: "127.0.0.1",
    autoReconnect: true,
    autoStart: false
)

let mapping2 = PortMapping(
    name: "Redis 6379",
    hostId: host1.id,
    forwardType: .localPort,
    localPort: 6380,
    remotePort: 6379,
    remoteHost: "127.0.0.1"
)

let portBarData = PortBarData(hosts: [host1], mappings: [mapping1, mapping2])
let encoder = JSONEncoder()
encoder.outputFormatting = .prettyPrinted
encoder.dateEncodingStrategy = .iso8601
let data = try! encoder.encode(portBarData)

let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let decodedData = try! decoder.decode(PortBarData.self, from: data)

assert(decodedData.hosts.count == 1, "Decoded host count should be 1")
assert(decodedData.mappings.count == 2, "Decoded mappings count should be 2")
assert(decodedData.hosts[0].name == "生产跳板机", "Host name mismatch")
assert(decodedData.hosts[0].password == "Complex!@#$%^&*()_+Pass", "Host password mismatch")
assert(decodedData.mappings[0].hostId == decodedData.hosts[0].id, "Mapping 1 hostId mismatch")
assert(decodedData.mappings[1].hostId == decodedData.hosts[0].id, "Mapping 2 hostId mismatch")
print("✅ [1/4] 模型独立管理与 1:N 映射关系测试通过！")

// 2. Test Askpass bridge
print("▶️ [2/4] 测试 askpass 桥接程序...")
let askpassPath = "build/PortBar.app/Contents/Resources/portbar-askpass"
assert(FileManager.default.isExecutableFile(atPath: askpassPath), "askpass binary should be executable")

let testPassword = "MyStr0ng!P@ssw0rd'\"$\\nSpecial"
let proc = Process()
proc.executableURL = URL(fileURLWithPath: askpassPath)
var env = ProcessInfo.processInfo.environment
env["PORTBAR_SSH_PASSWORD"] = testPassword
proc.environment = env
let pipe = Pipe()
proc.standardOutput = pipe
try! proc.run()
proc.waitUntilExit()

let askpassOutputData = pipe.fileHandleForReading.readDataToEndOfFile()
let returnedPassword = String(data: askpassOutputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
assert(returnedPassword == testPassword, "Askpass password mismatch!")
print("✅ [2/4] askpass 认证桥接测试通过！")

// 3. Test ConfigStore operations
print("▶️ [3/4] 测试 ConfigStore 主机与映射增删改查及级联删除...")
let store = ConfigStore.shared
let newHost = SSHHost(name: "临时跳板", host: "1.1.1.1", username: "root")
store.addHost(newHost)
let newMapping = PortMapping(name: "临时转发", hostId: newHost.id, localPort: 9999, remotePort: 80)
store.addMapping(newMapping)

assert(store.host(for: newHost.id) != nil, "New host should exist")
assert(store.mapping(for: newMapping.id) != nil, "New mapping should exist")

// Deleting host should clean up associated mappings
store.deleteHost(id: newHost.id)
assert(store.host(for: newHost.id) == nil, "Deleted host should not exist")
assert(store.mapping(for: newMapping.id) == nil, "Associated mapping should be removed on host delete")
print("✅ [3/4] ConfigStore 增删改查与级联清理测试通过！")

// 4. Test NetworkDetector
print("▶️ [4/4] 测试 NetworkDetector 端口检测...")
let notListening = NetworkDetector.shared.isLocalPortListening(port: 59872)
assert(!notListening, "Port 59872 should not be listening")
print("✅ [4/4] NetworkDetector 端口检测测试通过！")

print("🎉 所有自动化测试全部通过！")
