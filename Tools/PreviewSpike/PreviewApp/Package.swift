// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "PreviewApp",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../ToyKit")],
    targets: [
        .target(name: "PreviewSupport"),
        .executableTarget(name: "PreviewApp", dependencies: [.product(name: "ToyKit", package: "ToyKit"), "PreviewSupport"]),
    ]
)
