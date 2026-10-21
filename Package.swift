// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TodoApp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TodoApp",
            path: "Sources"
        )
    ]
)
