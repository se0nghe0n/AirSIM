// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WebRTC",
    // AirSIM only links the iOS slice. The upstream tag declares visionOS v26
    // with a Swift 5.9 manifest; omit unused platforms for older Xcode hosts.
    platforms: [.iOS(.v13)],
    products: [
        .library(
            name: "WebRTC",
            targets: ["WebRTC"]
        ),
    ],
    dependencies: [],
    targets: [
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/webrtc-sdk/Specs/releases/download/144.7559.15/WebRTC.xcframework.zip",
            checksum: "a17a6688e208255b70381926110526593ba626e033cf88c9ed4a7b618f98eb8a"
        ),
    ]
)
