#if DEBUG && NTFY_PRIVATE_SYSTEM_TONES

import AVFoundation
import CryptoKit
import Foundation

struct PrivateSystemTone: Identifiable, Hashable {
    let id: String
    let name: String
    let collection: String
    let sourceUrl: URL
}

struct InstalledSystemTone: Equatable {
    let fileName: String
    let displayName: String
}

enum PrivateSystemToneError: LocalizedError {
    case catalogUnavailable
    case sharedContainerUnavailable
    case unsupportedAudio

    var errorDescription: String? {
        switch self {
        case .catalogUnavailable:
            return "The iOS system-tone catalog is unavailable on this device."
        case .sharedContainerUnavailable:
            return "ntfy could not open its shared notification-sound folder."
        case .unsupportedAudio:
            return "This system tone could not be converted for notifications."
        }
    }
}

enum PrivateSystemToneCatalog {
    private struct Collection {
        let name: String
        let directory: String
    }

    private static let collections = [
        Collection(name: "Current", directory: "EncoreInfinitum"),
        Collection(name: "Classic", directory: "Modern"),
        Collection(name: "Classic", directory: "Classic")
    ]

    private static var catalogRoot: URL {
        URL(fileURLWithPath: "/System/Library/PrivateFrameworks/ToneLibrary.framework/AlertTones", isDirectory: true)
    }

    static func availableTones(catalogRoot overrideRoot: URL? = nil) -> [PrivateSystemTone] {
        let fileManager = FileManager.default
        let allowedExtensions = Set(["caf", "m4r", "wav", "aiff", "aif"])
        let root = overrideRoot ?? catalogRoot

        return collections.flatMap { collection in
            let directory = root.appendingPathComponent(collection.directory, isDirectory: true)
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return [PrivateSystemTone]()
            }

            return urls.compactMap { url in
                guard allowedExtensions.contains(url.pathExtension.lowercased()) else { return nil }
                let relativePath = "\(collection.directory)/\(url.lastPathComponent)"
                return PrivateSystemTone(
                    id: relativePath,
                    name: displayName(for: url),
                    collection: collection.name,
                    sourceUrl: url
                )
            }
        }
        .sorted {
            if $0.collection != $1.collection {
                return $0.collection == "Current"
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func install(_ tone: PrivateSystemTone, soundsDirectory overrideDirectory: URL? = nil) throws -> InstalledSystemTone {
        guard FileManager.default.fileExists(atPath: tone.sourceUrl.path) else {
            throw PrivateSystemToneError.catalogUnavailable
        }
        guard let soundsDirectory = overrideDirectory ?? sharedSoundsDirectory() else {
            throw PrivateSystemToneError.sharedContainerUnavailable
        }

        try FileManager.default.createDirectory(
            at: soundsDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.none]
        )

        let digest = SHA256.hash(data: Data(tone.id.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let fileName = "ntfy-system-\(digest).caf"
        let destination = soundsDirectory.appendingPathComponent(fileName)

        if !FileManager.default.fileExists(atPath: destination.path) {
            if tone.sourceUrl.pathExtension.lowercased() == "caf" {
                try FileManager.default.copyItem(at: tone.sourceUrl, to: destination)
            } else {
                try convertToLinearPcmCaf(source: tone.sourceUrl, destination: destination)
            }
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.none],
                ofItemAtPath: destination.path
            )
        }

        return InstalledSystemTone(fileName: fileName, displayName: tone.name)
    }

    static func installedUrl(fileName: String, soundsDirectory overrideDirectory: URL? = nil) -> URL? {
        (overrideDirectory ?? sharedSoundsDirectory())?.appendingPathComponent(fileName)
    }

    private static func sharedSoundsDirectory() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Store.appGroup)?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    private static func displayName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-EncoreInfinitum", with: "")
            .replacingOccurrences(of: "-", with: " ")
    }

    private static func convertToLinearPcmCaf(source: URL, destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            throw PrivateSystemToneError.unsupportedAudio
        }

        let output = try AVAudioFile(
            forWriting: destination,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }
}

@MainActor
final class SystemTonePreviewPlayer: ObservableObject {
    private var player: AVAudioPlayer?

    func play(_ tone: PrivateSystemTone) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        player = try AVAudioPlayer(contentsOf: tone.sourceUrl)
        player?.prepareToPlay()
        player?.play()
    }

    func stop() {
        player?.stop()
        player = nil
    }
}

#endif
