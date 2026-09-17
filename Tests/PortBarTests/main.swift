import Foundation

func assert(_ condition: Bool, _ message: String) {
    if !condition {
        print("❌ ASSERTION FAILED: \(message)")
        exit(1)
    }
}

print("🧪 开始运行 PortBar 2.1 (多端口转发与批量解析) 自动化测试...")

// 1. Test Multi-Port Models & Default Port Alignment
print("▶️ [1/5] 测试 PortRule 与多端口 PortMapping 关联...")
let host1 = SSHHost(
    name: "生产跳板机",
    host: "1.2.3.4",
    port: 2222,
    username: "devuser",
    password: "Complex!@#$%^&*()_+Pass"
)

let multiPortMapping = PortMapping(
    name: "开发全家桶",
    hostId: host1.id,
    forwardType: .localPort,
    portRules: [
        PortRule(localPort: 8080, remotePort: 8080),
        PortRule(localPort: 3306, remotePort: 3306),
        PortRule(localPort: 6379, remotePort: 6379)
    ],
    autoReconnect: true
)

assert(multiPortMapping.portRules.count == 3, "Should have 3 port rules")
assert(multiPortMapping.portRules[0].localPort == multiPortMapping.portRules[0].remotePort, "Port 1 should have local == remote")
assert(multiPortMapping.portRules[1].localPort == 3306, "Port 2 local should be 3306")
assert(multiPortMapping.portRules[2].remotePort == 6379, "Port 3 remote should be 6379")
assert(multiPortMapping.allLocalPorts == [8080, 3306, 6379], "allLocalPorts should match")
print("✅ [1/5] 多端口模型及本地=目标端口对齐测试通过！")

// 2. Test Batch Port Parser
print("▶️ [2/5] 测试批量快速端口录入解析器 (parseBatchPorts)...")
let batchInput = "8080, 3306, 6379, 9000-9002, 3000:3001"
let parsedRules = PortMapping.parseBatchPorts(batchInput)

assert(parsedRules.contains(where: { $0.localPort == 8080 && $0.remotePort == 8080 }), "Parsed should contain 8080->8080")
assert(parsedRules.contains(where: { $0.localPort == 3306 && $0.remotePort == 3306 }), "Parsed should contain 3306->3306")
assert(parsedRules.contains(where: { $0.localPort == 6379 && $0.remotePort == 6379 }), "Parsed should contain 6379->6379")
assert(parsedRules.contains(where: { $0.localPort == 9000 && $0.remotePort == 9000 }), "Parsed range 9000")
assert(parsedRules.contains(where: { $0.localPort == 9001 && $0.remotePort == 9001 }), "Parsed range 9001")
assert(parsedRules.contains(where: { $0.localPort == 9002 && $0.remotePort == 9002 }), "Parsed range 9002")
assert(parsedRules.contains(where: { $0.localPort == 3000 && $0.remotePort == 3001 }), "Parsed custom mapping 3000:3001")
print("✅ [2/5] 批量端口录入解析器测试通过！")

// 3. Test JSON Serialization & Legacy Compatibility
print("▶️ [3/5] 测试 JSON 序列化及向下兼容旧版单端口数据...")
// Encode modern
let encoder = JSONEncoder()
encoder.outputFormatting = .prettyPrinted
encoder.dateEncodingStrategy = .iso8601
let modernData = try! encoder.encode([multiPortMapping])

let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let decodedModern = try! decoder.decode([PortMapping].self, from: modernData)
assert(decodedModern[0].portRules.count == 3, "Modern decoded should have 3 rules")

// Decode legacy single port JSON
let legacyJSON = """
[
  {
    "id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
    "name": "旧版单端口映射",
    "hostId": "\(host1.id.uuidString)",
    "forwardType": "local_port",
    "localPort": 8888,
    "remotePort": 8888,
    "remoteHost": "127.0.0.1",
    "autoReconnect": false,
    "autoStart": false
  }
]
""".data(using: .utf8)!

let decodedLegacy = try! decoder.decode([PortMapping].self, from: legacyJSON)
assert(decodedLegacy.count == 1, "Legacy should decode 1 mapping")
assert(decodedLegacy[0].portRules.count == 1, "Legacy should convert to 1 portRule")
assert(decodedLegacy[0].portRules[0].localPort == 8888, "Legacy localPort should be 8888")
assert(decodedLegacy[0].portRules[0].remotePort == 8888, "Legacy remotePort should be 8888")
print("✅ [3/5] JSON 序列化与旧版向下兼容测试通过！")

// 4. Test Askpass bridge
print("▶️ [4/5] 测试 askpass 桥接程序...")
guard let askpassPath = AskpassHelper.shared.getAskpassBinaryPath(),
      FileManager.default.isExecutableFile(atPath: askpassPath) else {
    print("❌ ASSERTION FAILED: AskpassHelper should return an executable askpass binary")
    exit(1)
}

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
print("✅ [4/5] askpass 认证桥接测试通过！")

// 5. Test ConfigStore operations
print("▶️ [5/5] 测试 ConfigStore 主机与多端口映射操作...")
let store = ConfigStore.shared
let newHost = SSHHost(name: "临时主机", host: "1.1.1.1", username: "root")
store.addHost(newHost)
let newMapping = PortMapping(
    name: "临时多端口",
    hostId: newHost.id,
    portRules: [
        PortRule(localPort: 7001, remotePort: 7001),
        PortRule(localPort: 7002, remotePort: 7002)
    ]
)
store.addMapping(newMapping)

assert(store.mapping(for: newMapping.id)?.portRules.count == 2, "Stored mapping should have 2 rules")

// Cleanup
store.deleteHost(id: newHost.id)
assert(store.mapping(for: newMapping.id) == nil, "Cascaded mapping deletion")
print("✅ [5/5] ConfigStore 多端口增删改查测试通过！")

print("🎉 所有自动化测试全部通过！")
