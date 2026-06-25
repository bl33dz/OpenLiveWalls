import AVFoundation
import AppKit
import Foundation

final class LockScreenManager: @unchecked Sendable {
    static let shared = LockScreenManager()
    private let fm = FileManager.default
    private var timer: DispatchSourceTimer?

    private var applicationSupportDir: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private var aDir: URL {
        applicationSupportDir.appendingPathComponent("com.apple.wallpaper/aerials")
    }

    private var vDir: URL { aDir.appendingPathComponent("videos") }
    private var tDir: URL { aDir.appendingPathComponent("thumbnails") }
    private var eURL: URL { aDir.appendingPathComponent("manifest/entries.json") }
    private var tURL: URL { aDir.appendingPathComponent("manifest.tar") }

    private var sURL: URL {
        applicationSupportDir.appendingPathComponent("com.apple.wallpaper/Store/Index.plist")
    }

    private let catID = "OLW00000-0000-4000-8000-000000000001"
    private let subID = "OLW00000-0000-4000-8000-000000000002"

    private init() {}

    func start(_ task: @escaping () -> Void) {
        let queue = DispatchQueue(label: "owl.ls", qos: .default)
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer?.schedule(deadline: .now(), repeating: 5.0)
        timer?.setEventHandler(handler: task)
        timer?.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func inject(videoSourceURL: URL) {
        do {
            try fm.createDirectory(at: vDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: tDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: eURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: sURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            let id = currentAssetID()
            let name = videoSourceURL.deletingPathExtension().lastPathComponent
            let videoDestination = vDir.appendingPathComponent("\(id).mov")

            try? fm.removeItem(at: videoDestination)
            try fm.copyItem(at: videoSourceURL, to: videoDestination)

            try writeEntries(assetID: id, videoPath: videoDestination.path, name: name)
            try writeStore(assetID: id)
            killAll()

            UserDefaults.standard.set(videoDestination.path, forKey: "owl_video")
            UserDefaults.standard.set(name, forKey: "owl_name")
        } catch {
            print("[LSM] inject: \(error)")
        }
    }

    func reapply() {
        guard let id = UserDefaults.standard.string(forKey: "owl_id") else { return }
        guard let data = try? Data(contentsOf: eURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]],
              assets.contains(where: { ($0["id"] as? String) == id }) else {
            return
        }

        do {
            try writeStore(assetID: id)
            try run("/usr/bin/killall", arguments: ["-9", "WallpaperAgent"])
        } catch {
            print("[LSM] reapply: \(error)")
        }
    }

    private func writeEntries(assetID: String, videoPath: String, name: String) throws {
        var entries = readEntries()
        var categories = entries["categories"] as? [[String: Any]] ?? []
        var assets = entries["assets"] as? [[String: Any]] ?? []

        categories.removeAll { ($0["id"] as? String) == catID }
        assets.removeAll { ($0["categories"] as? [String])?.contains(catID) ?? false }

        let previewPath = tDir.appendingPathComponent("\(assetID).png").path
        try writePreviewImage(videoPath: videoPath, previewPath: previewPath)

        categories.append([
            "id": catID,
            "localizedNameKey": "OpenLiveWalls",
            "localizedDescriptionKey": "From local files",
            "preferredOrder": 0,
            "representativeAssetID": assetID,
            "previewImage": "file://\(previewPath)",
            "subcategories": [[
                "id": subID,
                "localizedNameKey": "OpenLiveWalls",
                "preferredOrder": 0,
                "representativeAssetID": assetID,
                "previewImage": "file://\(previewPath)"
            ]]
        ])

        let shotID = "CUSTOM_\(assetID.replacingOccurrences(of: "-", with: "_"))"
        assets.append([
            "id": assetID,
            "localizedNameKey": name,
            "preferredOrder": 0,
            "shotID": shotID,
            "url-4K-SDR-240FPS": "file://\(videoPath)",
            "previewImage": "file://\(previewPath)",
            "accessibilityLabel": name,
            "includeInShuffle": true,
            "showInTopLevel": true,
            "subcategories": [subID],
            "categories": [catID],
            "pointsOfInterest": ["0": "\(shotID)_0"]
        ])

        entries["categories"] = categories
        entries["assets"] = assets
        try JSONSerialization.data(withJSONObject: entries, options: .prettyPrinted)
            .write(to: eURL, options: .atomic)

        let tmp = fm.temporaryDirectory.appendingPathComponent("owl_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }

        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        if fm.fileExists(atPath: tURL.path) {
            try run("/usr/bin/tar", arguments: ["-xf", tURL.path, "-C", tmp.path])
        }

        try? fm.removeItem(at: tmp.appendingPathComponent("entries.json"))
        try fm.copyItem(at: eURL, to: tmp.appendingPathComponent("entries.json"))
        try? fm.removeItem(at: tURL)
        try run("/usr/bin/tar", arguments: ["-cf", tURL.path, "-C", tmp.path, "."])
    }

    private func writeStore(assetID: String) throws {
        let config = try PropertyListSerialization.data(
            fromPropertyList: ["assetID": assetID],
            format: .binary,
            options: 0
        )
        let encodedValues = try PropertyListSerialization.data(
            fromPropertyList: ["values": []] as [String: Any],
            format: .binary,
            options: 0
        )
        let choice: [String: Any] = [
            "Configuration": config,
            "Files": [] as [Any],
            "Provider": "com.apple.wallpaper.choice.aerials"
        ]
        let content: [String: Any] = [
            "Choices": [choice],
            "EncodedOptionValues": encodedValues
        ]
        let linked: [String: Any] = [
            "Content": content,
            "LastSet": Date(),
            "LastUse": Date()
        ]
        let type: [String: Any] = [
            "Type": "linked",
            "Linked": linked
        ]

        try PropertyListSerialization.data(
            fromPropertyList: [
                "SystemDefault": type,
                "AllSpacesAndDisplays": type,
                "Displays": [:],
                "Spaces": [:]
            ] as [String: Any],
            format: .binary,
            options: 0
        ).write(to: sURL, options: .atomic)
    }

    func convertAndInject(source: URL, name: String = "", outputPipe: Pipe? = nil) throws {
        let x265 = URL(fileURLWithPath: "/tmp/owl_x265_\(UUID().uuidString).mov")
        defer { try? fm.removeItem(at: x265) }

        let ffmpeg = Process()
        ffmpeg.executableURL = try ffmpegURL()
        ffmpeg.arguments = [
            "-y", "-i", source.path,
            "-c:v", "libx265",
            "-pix_fmt", "yuv420p10le",
            "-crf", "18",
            "-preset", "medium",
            "-tag:v", "hvc1",
            "-x265-params", "keyint=60:min-keyint=60:scenecut=0:bframes=4:b-adapt=2:b-pyramid=1:temporal-layers=3",
            "-color_range", "tv",
            "-color_primaries", "bt709",
            "-color_trc", "bt709",
            "-colorspace", "bt709",
            "-metadata:s:v", "handler_name=Core Media Video",
            "-metadata:s:v", "encoder=HEVC",
            x265.path
        ]

        if let pipe = outputPipe {
            ffmpeg.standardOutput = pipe
            ffmpeg.standardError = pipe
        } else {
            let devnull = URL(fileURLWithPath: "/dev/null")
            ffmpeg.standardOutput = try FileHandle(forWritingTo: devnull)
            ffmpeg.standardError = try FileHandle(forWritingTo: devnull)
        }

        try ffmpeg.run()
        ffmpeg.waitUntilExit()
        guard ffmpeg.terminationStatus == 0 else { throw LSError.encodeFailed }
        print("[convert] x265 encode done")

        let patched = URL(fileURLWithPath: "/tmp/owl_patched_\(UUID().uuidString).mov")
        defer { try? fm.removeItem(at: patched) }

        let patcher = try AtomPatcher(fileURL: x265)
        try WallpaperInjector.patch(patcher: patcher)
        try patcher.save(outputURL: patched)

        var data = try Data(contentsOf: patched)
        if let vendorRange = data.range(of: Data("FFMP".utf8)) {
            data.replaceSubrange(vendorRange, with: [0, 0, 0, 0])
        }

        let fixed = URL(fileURLWithPath: "/tmp/owl_fixed_\(UUID().uuidString).mov")
        defer { try? fm.removeItem(at: fixed) }
        try data.write(to: fixed)

        let localDir = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("local", isDirectory: true)
        try? fm.createDirectory(at: localDir, withIntermediateDirectories: true)

        let safeName = name.isEmpty ? source.deletingPathExtension().lastPathComponent : name
        let localDest = localDir.appendingPathComponent(safeName + "_lock.mov")

        try? fm.removeItem(at: localDest)
        try fm.copyItem(at: fixed, to: localDest)
        print("[convert] copied to local: \(localDest.lastPathComponent)")

        inject(videoSourceURL: fixed)
    }

    enum LSError: LocalizedError {
        case encodeFailed
        case ffmpegNotFound

        var errorDescription: String? {
            switch self {
            case .encodeFailed:
                return "ffmpeg failed to encode this video. Check that the file is readable and that your ffmpeg build supports libx265."
            case .ffmpegNotFound:
                return "ffmpeg was not found. Install it with Homebrew (`brew install ffmpeg`) or place an ffmpeg binary at /opt/homebrew/bin/ffmpeg, /usr/local/bin/ffmpeg, or somewhere in PATH."
            }
        }
    }

    private func currentAssetID() -> String {
        if let id = UserDefaults.standard.string(forKey: "owl_id") {
            return id
        }

        let id = UUID().uuidString.uppercased()
        UserDefaults.standard.set(id, forKey: "owl_id")
        return id
    }

    private func readEntries() -> [String: Any] {
        guard let data = try? Data(contentsOf: eURL),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [
                "version": 1,
                "initialAssetCount": 4,
                "localizationVersion": "22L-1"
            ]
        }

        return entries
    }

    private func writePreviewImage(videoPath: String, previewPath: String) throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
        let generator = AVAssetImageGenerator(asset: asset)
        let time = CMTime(seconds: 2, preferredTimescale: 600)

        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            return
        }

        try png.write(to: URL(fileURLWithPath: previewPath))
    }

    private func ffmpegURL() throws -> URL {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]

        for path in candidates where isExecutable(path) {
            return URL(fileURLWithPath: path)
        }

        if let path = findExecutableInPath(named: "ffmpeg") {
            return URL(fileURLWithPath: path)
        }

        throw LSError.ffmpegNotFound
    }

    private func findExecutableInPath(named name: String) -> String? {
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""

        for directory in pathValue.split(separator: ":") {
            let path = "\(directory)/\(name)"
            if isExecutable(path) {
                return path
            }
        }

        return nil
    }

    private func isExecutable(_ path: String) -> Bool {
        fm.isExecutableFile(atPath: path)
    }

    private func killAll() {
        for name in ["WallpaperAgent", "WallpaperAerialsExtension", "WallpaperImageExtension", "wallpaperexportd", "Wallpaper"] {
            try? run("/usr/bin/killall", arguments: ["-9", name])
        }
    }

    private func run(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        try process.run()
        process.waitUntilExit()
    }
}
