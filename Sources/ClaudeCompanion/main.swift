import AppKit

let args = CommandLine.arguments
if args.contains("--selftest") {
    exit(SelfTest.run(includeClaude: args.contains("--claude")) ? 0 : 1)
}

// Dev aid: `ClaudeCompanion --type-into <iTerm session id> <text>` exercises the real typing path.
if let i = args.firstIndex(of: "--type-into"), args.count > i + 2 {
    print(ITerm.type(args[i + 2], intoSession: args[i + 1]) ?? "error")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
