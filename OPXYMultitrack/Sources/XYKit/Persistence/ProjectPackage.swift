// ProjectPackage.swift — a song on disk.
//
//   Song.xyproj/
//     project.json      everything in Project (small, rewritten on every save)
//     Audio/<id>.wav    dry recordings and imported audio (written once, never rewritten)
//     Peaks/<id>.peaks  cached waveform overviews (safe to delete; rebuilt on open)

import Foundation

public struct ProjectPackage: Equatable {
    public static let fileExtension = "xyproj"
    public let url: URL

    public init(url: URL) { self.url = url }

    public var jsonURL: URL { url.appendingPathComponent("project.json") }
    public var audioDir: URL { url.appendingPathComponent("Audio", isDirectory: true) }
    public var peaksDir: URL { url.appendingPathComponent("Peaks", isDirectory: true) }

    public func audioURL(_ asset: Asset) -> URL { audioDir.appendingPathComponent(asset.fileName) }
    public func peaksURL(_ assetID: UUID) -> URL { peaksDir.appendingPathComponent("\(assetID.uuidString).peaks") }

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("OPXYMultitrack", isDirectory: true)
    }

    /// Untitled projects live here until the first Save As, so recording works before the song has a name.
    public static func makeUntitled() throws -> ProjectPackage {
        let dir = supportDirectory.appendingPathComponent("Untitled", isDirectory: true)
        let package = ProjectPackage(url: dir.appendingPathComponent("Untitled-\(UUID().uuidString).\(fileExtension)"))
        try package.ensureDirectories()
        return package
    }

    public var isUntitled: Bool { url.path.hasPrefix(Self.supportDirectory.path) }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: peaksDir, withIntermediateDirectories: true)
    }

    public func load() throws -> Project {
        let project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: jsonURL))
        guard project.version <= Project.currentVersion else {
            throw PackageError.newerVersion(project.version)
        }
        return project
    }

    public func save(_ project: Project) throws {
        try ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: jsonURL, options: .atomic)
    }

    /// Save As: copy the whole package, audio included, to a new place.
    public func copy(to destination: URL) throws -> ProjectPackage {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: url, to: destination)
        return ProjectPackage(url: destination)
    }

    /// Assets whose audio file is gone. Their clips are shown hatched and skipped during playback.
    public func missingAssets(in project: Project) -> Set<UUID> {
        Set(project.assets.filter { !FileManager.default.fileExists(atPath: audioURL($0).path) }.map(\.id))
    }
}

enum PackageError: LocalizedError {
    case newerVersion(Int)

    var errorDescription: String? {
        switch self {
        case .newerVersion(let v):
            return "This project was saved by a newer version of the app (format \(v))."
        }
    }
}
