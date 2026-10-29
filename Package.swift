// swift-tools-version: 5.9
import PackageDescription
import Foundation

var products: [Product] = [.library(name: "DictationCore", targets: ["DictationCore"])]
var targets: [Target] = [
    .target(name: "DictationCore"),
    .testTarget(name: "DictationCoreTests", dependencies: ["DictationCore"])
]
#if os(macOS)
products.append(.executable(name: "WhistleBar", targets: ["WhistleBar"]))
targets += [
    .systemLibrary(name: "CNeedle"),
    .executableTarget(name: "WhistleBar", dependencies: ["DictationCore", "CNeedle"],
        linkerSettings: [.unsafeFlags(["-L", Context.packageDirectory + "/Vendor"]),
                         .linkedLibrary("needle"), .linkedLibrary("c++")])
]
#endif

// The official pinned libneedle.a declares macOS 26.0 as its minimum OS.
let package = Package(name: "WhistleBar", platforms: [.macOS("26.0")],
                      products: products, targets: targets)
