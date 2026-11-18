// swift-tools-version: 6.2
// TuneGod Link: the protocol, clock and transport shared by the companion's helper (and, later, its driver).
// The protocol, clock and MIDI conversion build for iOS as well, so the phone side can use the same code.
// TuneGodSamplerKit: the instrument maker (hosting an Audio Unit, sampling it, writing a .tgi); Mac only.
import Foundation
import PackageDescription

// The .tgi format and its layer rules live in the phone's repository, checked out beside this one. TUNEGOD_CORE names another checkout.
let core = ProcessInfo.processInfo.environment["TUNEGOD_CORE"] ?? "../tunegod-native/ios/TuneGodCore"

let package = Package(
    name: "TuneGodLink",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [
        .library(name: "TuneGodLinkKit", targets: ["TuneGodLinkKit"]),
        .library(name: "TuneGodSamplerKit", targets: ["TuneGodSamplerKit"]),
        .executable(name: "tglink", targets: ["tglink"]),
        .executable(name: "tgsample", targets: ["tgsample"]),
    ],
    dependencies: [.package(name: "TuneGodCore", path: core)],
    targets: [
        .target(name: "TuneGodLinkKit"),
        .executableTarget(name: "tglink", dependencies: ["TuneGodLinkKit"]),
        .testTarget(name: "TuneGodLinkKitTests", dependencies: ["TuneGodLinkKit"]),
        .target(name: "TuneGodSamplerKit", dependencies: [.product(name: "TuneGodCore", package: "TuneGodCore")]),
        .executableTarget(name: "tgsample", dependencies: ["TuneGodSamplerKit"]),
        .testTarget(name: "TuneGodSamplerKitTests", dependencies: ["TuneGodSamplerKit"]),
    ],
    swiftLanguageModes: [.v5]
)
