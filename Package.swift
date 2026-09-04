// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "pdf-seal",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SealCore", path: "Sources/SealCore"),
        .executableTarget(
            name: "PDFSeal",
            dependencies: ["SealCore"],
            path: "Sources/PDFSeal"
        ),
        .executableTarget(
            name: "SealTool",
            dependencies: ["SealCore"],
            path: "Sources/SealTool"
        )
    ]
)
