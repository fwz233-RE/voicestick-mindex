// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VoiceToText",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "VoiceToTextApp", targets: ["VoiceToTextApp"])
    ],
    targets: [
        .executableTarget(
            name: "VoiceToTextApp",
            path: "Sources/VoiceToTextApp",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/VoiceToTextApp/Info.plist"
                ])
            ]
        )
    ]
)
