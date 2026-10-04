// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EasyPic",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "EasyPic", targets: ["EasyPic"])],
    targets: [
        .target(name: "EasyPicCore"),
        .executableTarget(name: "EasyPic", dependencies: ["EasyPicCore"]),
        .executableTarget(name: "EasyPicChecks", dependencies: ["EasyPicCore"], path: "Tests/EasyPicCoreTests", resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
