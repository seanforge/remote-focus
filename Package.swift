// swift-tools-version:5.9
import PackageDescription

// RemoteFocus: a small companion to SayAll for driving Claude / Codex on macOS with a Xiaomi Remote 2 Pro.
let package = Package(
    name: "remote-focus",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "remote-focus", path: "Sources/RemoteFocus"),
        // Diagnostic tool: dumps the accessibility tree of the Claude / Codex window to a text file.
        .executableTarget(name: "ax-dump", path: "Sources/AXDump")
    ]
)
