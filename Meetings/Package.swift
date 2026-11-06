// swift-tools-version: 6.0
// Meetings: record a call or a talk, transcribe it through OpenRouter, keep summary, transcript
// and own tabs as Markdown (docs/design/meetings.md). It depends on nothing in AKitCore, so this
// folder can leave the AKit repo as it is.
import PackageDescription

let package = Package(
    name: "Meetings",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MeetingsCore", targets: ["MeetingsCore"]),
        .library(name: "MeetingsAudio", targets: ["MeetingsAudio"]),
        .library(name: "MeetingsUI", targets: ["MeetingsUI"]),
    ],
    targets: [
        // Files, OpenRouter, transcription and summary. No audio devices, no UI.
        .target(name: "MeetingsCore"),
        // Microphone + system sound capture, 5-minute pieces, mixing.
        .target(name: "MeetingsAudio", dependencies: ["MeetingsCore"]),
        .target(name: "MeetingsUI", dependencies: ["MeetingsCore", "MeetingsAudio"]),
        .testTarget(name: "MeetingsCoreTests", dependencies: ["MeetingsCore", "MeetingsAudio"]),
    ]
)
