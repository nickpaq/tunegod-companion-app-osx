// swift-tools-version: 6.2
// TuneGod Link: the protocol, clock and transport shared by the companion's helper (and, later, its driver).
// The protocol, clock and MIDI conversion build for iOS as well, so the phone side can use the same code.
import Foundation
import PackageDescription

// The phone repository's core (the .tgi instrument format and how it plays): beside this repository on the Mac, or where
// TUNEGOD_CORE says.
let core = ProcessInfo.processInfo.environment["TUNEGOD_CORE"] ?? "../tunegod-native/ios/TuneGodCore"

let package = Package(
    name: "TuneGodLink",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [
        .library(name: "TuneGodLinkKit", targets: ["TuneGodLinkKit"]),
        .executable(name: "tglink", targets: ["tglink"]),
        .executable(name: "tgsample", targets: ["tgsample"]),
    ],
    dependencies: [.package(name: "TuneGodCore", path: core)],
    targets: [
        .target(name: "TuneGodLinkKit"),
        .executableTarget(name: "tglink", dependencies: ["TuneGodLinkKit"]),
        // Samples an Audio Unit instrument into a TuneGod instrument (.tgi). macOS only.
        .executableTarget(name: "tgsample", dependencies: [.product(name: "TuneGodCore", package: "TuneGodCore")]),
        .testTarget(name: "TuneGodLinkKitTests", dependencies: ["TuneGodLinkKit"]),
    ],
    swiftLanguageModes: [.v5]
)
