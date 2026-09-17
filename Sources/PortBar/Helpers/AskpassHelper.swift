import Foundation

public final class AskpassHelper {
    public static let shared = AskpassHelper()

    private init() {}

    /// Returns the absolute path to the portbar-askpass binary, ensuring it exists and is executable.
    public func getAskpassBinaryPath() -> String? {
        let fileManager = FileManager.default

        // 1. Check inside Bundle Resources
        if let bundlePath = Bundle.main.path(forResource: "portbar-askpass", ofType: nil),
           fileManager.isExecutableFile(atPath: bundlePath) {
            return bundlePath
        }

        // 2. Check next to current executable
        let currentExecURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let siblingAskpass = currentExecURL.deletingLastPathComponent().appendingPathComponent("portbar-askpass").path
        if fileManager.isExecutableFile(atPath: siblingAskpass) {
            return siblingAskpass
        }

        // 3. Fallback: Check or create in Application Support/PortBar/bin
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let binDir = appSupport.appendingPathComponent("PortBar/bin", isDirectory: true)
        let targetBinary = binDir.appendingPathComponent("portbar-askpass")

        if fileManager.isExecutableFile(atPath: targetBinary.path) {
            return targetBinary.path
        }

        // Ensure directory exists
        try? fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)

        // Compile or write askpass binary on the fly
        let cCode = """
        #include <stdio.h>
        #include <stdlib.h>
        int main(void) {
            const char *p = getenv("PORTBAR_SSH_PASSWORD");
            if (p) {
                fputs(p, stdout);
                fputc('\\n', stdout);
                fflush(stdout);
                return 0;
            }
            return 1;
        }
        """
        let tempC = binDir.appendingPathComponent("askpass.c")
        try? cCode.write(to: tempC, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        process.arguments = [tempC.path, "-O2", "-o", targetBinary.path]
        try? process.run()
        process.waitUntilExit()
        try? fileManager.removeItem(at: tempC)

        if fileManager.isExecutableFile(atPath: targetBinary.path) {
            return targetBinary.path
        }

        // Final fallback: Shell script askpass if clang isn't available
        let shScript = """
        #!/bin/sh
        printf "%s\\n" "$PORTBAR_SSH_PASSWORD"
        """
        let shTarget = binDir.appendingPathComponent("portbar-askpass.sh")
        try? shScript.write(to: shTarget, atomically: true, encoding: .utf8)
        var attrs = (try? fileManager.attributesOfItem(atPath: shTarget.path)) ?? [:]
        attrs[.posixPermissions] = 0o755
        try? fileManager.setAttributes(attrs, ofItemAtPath: shTarget.path)

        return shTarget.path
    }
}
