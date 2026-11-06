// swift-tools-version: 6.2
// TuneGod Link: the protocol, clock and transport shared by the companion's helper (and, later, its driver).
// The protocol, clock and MIDI conversion build for iOS as well, so the phone side can use the same code.
import PackageDescription

let package = Package(
    name: "TuneGodLink",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [
        .library(name: "TuneGodLinkKit", targets: ["TuneGodLinkKit"]),
        .executable(name: "tglink", targets: ["tglink"]),
    ],
    targets: [
        .target(name: "TuneGodLinkKit"),
        .executableTarget(name: "tglink", dependencies: ["TuneGodLinkKit"]),
        .testTarget(name: "TuneGodLinkKitTests", dependencies: ["TuneGodLinkKit"]),
    ],
    swiftLanguageModes: [.v5]
)
