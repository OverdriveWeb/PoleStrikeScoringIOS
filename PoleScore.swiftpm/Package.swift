// swift-tools-version: 5.9

// Deliberately minimal. The app icon and accent colour are set from Swift
// Playgrounds' own App Settings panel, where the picker only offers names that
// actually exist in your version — naming them here risks a manifest that fails
// to evaluate, which takes the whole build down before a line is compiled.

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "PoleScore",
    platforms: [.iOS("17.0")],
    products: [
        .iOSApplication(
            name: "PoleScore",
            targets: ["AppModule"],
            bundleIdentifier: "com.overdrive.polescore",
            displayVersion: "1.0",
            bundleVersion: "1",
            supportedDeviceFamilies: [.pad, .phone],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: ".",
            exclude: ["README.md", "supabase-schema.sql"]
        )
    ]
)
