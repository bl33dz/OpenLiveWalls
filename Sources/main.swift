import AppKit

if CommandLine.arguments.contains("--patch") {
    let sourceIndex = CommandLine.arguments.firstIndex(of: "--src") ?? .max
    let destinationIndex = CommandLine.arguments.firstIndex(of: "--dst") ?? .max

    guard sourceIndex < CommandLine.arguments.count - 1,
          destinationIndex < CommandLine.arguments.count - 1 else {
        print("Usage: --patch --src <input.mov> --dst <output.mov>")
        exit(0)
    }

    let source = URL(fileURLWithPath: CommandLine.arguments[sourceIndex + 1])
    let destination = URL(fileURLWithPath: CommandLine.arguments[destinationIndex + 1])

    try? FileManager.default.removeItem(at: destination)

    print("Patching \(source.lastPathComponent)...")
    let patcher = try AtomPatcher(fileURL: source)
    try WallpaperInjector.patch(patcher: patcher)
    try patcher.save(outputURL: destination)

    print("Saved to \(destination.lastPathComponent)")
    let data = try Data(contentsOf: destination)

    for atom in ["csgm", "sgpd", "tapt", "sbgp", "cslg"] {
        if let atomData = atom.data(using: .utf8) {
            print("  \(atom): \(data.range(of: atomData) != nil ? "YES" : "NO")")
        }
    }

    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
