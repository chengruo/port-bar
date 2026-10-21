import Cocoa

if CommandLine.arguments.dropFirst().first == "--cli" || URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "portbar" {
    var arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "--cli" { arguments.removeFirst() }
    exit(PortBarCLI.run(arguments))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
