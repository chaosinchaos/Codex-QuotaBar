// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexQuotaBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexQuotaBar", targets: ["CodexQuotaBar"])
    ],
    targets: [
        .executableTarget(
            name: "CodexQuotaBar",
            path: "Xcode/CodexQuotaBar",
            exclude: ["CodexQuotaBar-Info.plist", "AppIcon.icns", "AppIcon-80-white.png"],
            sources: ["AppDelegate.swift", "FullResetSupport.swift"]
        )
    ],
    swiftLanguageModes: [.v5]
)
