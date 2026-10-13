// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "ToyKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ToyKit", targets: ["ToyKit"])],
    targets: [.target(name: "ToyKit")]
)
