import AppKit
import Combine
import CryptoKit
import Foundation
import IVYCore
import Security

struct GitHubUpdate: Sendable {
    let version: String
    let notes: String
    let url: URL
    let digest: String
    let size: Int64
    let releaseURL: URL
}

enum UpdateError: LocalizedError {
    case invalidRelease, checksum, signature, installation(String)
    var errorDescription: String? {
        switch self {
        case .invalidRelease: return "GitHub didn't provide a compatible IVY DMG with a SHA-256 digest."
        case .checksum: return "The download checksum doesn't match GitHub. The update was discarded."
        case .signature: return "The downloaded app's identity or signing team doesn't match IVY."
        case .installation(let reason): return reason
        }
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var available: GitHubUpdate?
    @Published private(set) var busy = false
    @Published private(set) var message = "Check GitHub for a newer version of IVY."
    @Published private(set) var progress: Double?
    private var task: Task<Void, Never>?
    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    static let releasesURL = URL(string: "https://github.com/RavoxX/IVY/releases")!

    init() {
        let errorFile = AppPaths.applicationSupport.appendingPathComponent("update-error.json")
        if let data = try? Data(contentsOf: errorFile), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
           let text = value["message"]?.stringValue { message = "Last update: " + text }
    }

    func check() {
        guard !busy else { return }
        task = Task { [self] in
            busy = true; message = "Checking GitHub…"; defer { busy = false }
            do {
                let release = try await latest()
                if let remote = ReleaseVersion(release.version), let current = ReleaseVersion(currentVersion), remote > current {
                    available = release; message = "IVY \(release.version) is available."
                } else { available = nil; message = "You're up to date (IVY \(currentVersion))." }
            } catch is CancellationError { message = "Update check cancelled." }
            catch { message = error.localizedDescription }
        }
    }
    func update() {
        guard !busy, let release = available else { return }
        task = Task { [self] in
            busy = true; progress = 0; message = "Downloading IVY \(release.version)…"
            defer { busy = false; progress = nil }
            let folder = AppPaths.temporary.appendingPathComponent("Update-\(UUID().uuidString)", isDirectory: true)
            let mount = folder.appendingPathComponent("mount", isDirectory: true)
            var mounted = false; var handedOff = false
            defer {
                if mounted { _ = UpdateInstaller.process("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) }
                if !handedOff { try? FileManager.default.removeItem(at: folder) }
            }
            do {
                let fm = FileManager.default
                let target = Bundle.main.bundleURL.resolvingSymlinksInPath()
                guard target.pathExtension == "app", !target.path.contains("/AppTranslocation/"),
                      fm.isWritableFile(atPath: target.deletingLastPathComponent().path), fm.isWritableFile(atPath: target.path) else {
                    throw UpdateError.installation("IVY can't replace this copy. Move it to a writable Applications folder, then try again, or download the DMG below.")
                }
                try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                var request = URLRequest(url: release.url)
                request.timeoutInterval = 300
                let observer = UpdateDownloadObserver(limit: release.size) { [weak self] written in
                    Task { @MainActor [weak self] in self?.progress = Double(written) / Double(release.size) }
                }
                let (download, response) = try await URLSession(configuration: .ephemeral).download(for: request, delegate: observer)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      response.url?.scheme == "https" else { throw UpdateError.invalidRelease }
                let dmg = folder.appendingPathComponent("IVY.dmg")
                try fm.moveItem(at: download, to: dmg)
                let actualSize = try dmg.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard Int64(actualSize) == release.size else { throw UpdateError.checksum }
                let checksum = try await Task.detached(priority: .userInitiated) {
                    let handle = try FileHandle(forReadingFrom: dmg); defer { try? handle.close() }
                    var hash = SHA256()
                    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                        try Task.checkCancellation(); hash.update(data: chunk)
                    }
                    return hash.finalize().map { String(format: "%02x", $0) }.joined()
                }.value
                guard checksum == release.digest else { throw UpdateError.checksum }
                message = "Verifying the signed app…"; progress = nil
                try fm.createDirectory(at: mount, withIntermediateDirectories: true)
                let attached = await Task.detached { UpdateInstaller.process("/usr/bin/hdiutil", ["attach", dmg.path, "-mountpoint", mount.path, "-readonly", "-nobrowse", "-quiet"]) }.value
                guard attached == 0 else { throw UpdateError.installation("The downloaded disk image couldn't be opened.") }
                mounted = true
                let source = mount.appendingPathComponent("IVY.app")
                try UpdateInstaller.verify(source, matching: target, version: release.version)
                let staged = folder.appendingPathComponent("IVY.app")
                let copied = await Task.detached { UpdateInstaller.process("/usr/bin/ditto", [source.path, staged.path]) }.value
                guard copied == 0 else { throw UpdateError.installation("The update couldn't be staged.") }
                try UpdateInstaller.verify(staged, matching: target, version: release.version)
                try Task.checkCancellation()
                guard let executable = Bundle.main.executableURL else { throw UpdateError.signature }
                let helper = folder.appendingPathComponent("installer")
                try fm.copyItem(at: executable, to: helper)
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
                let process = Process(); process.executableURL = helper
                process.arguments = ["--ivy-install-update", String(ProcessInfo.processInfo.processIdentifier), target.path, staged.path, release.version, folder.path]
                try process.run()
                handedOff = true; message = "Installing and restarting IVY…"
                NSApp.terminate(nil)
            } catch is CancellationError { message = "Update cancelled. Your app wasn't replaced." }
            catch { message = error.localizedDescription }
        }
    }
    func cancel() { task?.cancel() }

    private func latest() async throws -> GitHubUpdate {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/RavoxX/IVY/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("IVY-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000,
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              value["draft"]?.boolValue == false, value["prerelease"]?.boolValue == false,
              let version = value["tag_name"]?.stringValue, ReleaseVersion(version) != nil,
              let asset = value["assets"]?.arrayValue?.first(where: { $0["name"]?.stringValue == "IVY-\(version.hasPrefix("v") ? String(version.dropFirst()) : version).dmg" }),
              let url = asset["browser_download_url"]?.stringValue.flatMap(URL.init(string:)),
              url.scheme == "https", url.host == "github.com", url.user == nil, url.query == nil,
              url.path.hasPrefix("/RavoxX/IVY/releases/download/"),
              let digest = asset["digest"]?.stringValue, digest.hasPrefix("sha256:"),
              let size = asset["size"]?.doubleValue, size > 0, size < 1_000_000_000 else { throw UpdateError.invalidRelease }
        let checksum = String(digest.dropFirst(7)).lowercased()
        guard checksum.count == 64, checksum.allSatisfy({ $0.isHexDigit }) else { throw UpdateError.invalidRelease }
        return GitHubUpdate(version: version.hasPrefix("v") ? String(version.dropFirst()) : version,
                            notes: String((value["body"]?.stringValue ?? "").prefix(20_000)), url: url, digest: checksum,
                            size: Int64(size), releaseURL: URL(string: "https://github.com/RavoxX/IVY/releases/tag/\(version)")!)
    }
}

/// Runs from a copied executable after the app exits. All paths are fixed arguments,
/// never shell text. Replacement is on the destination volume; a failed launch rolls back.
enum UpdateInstaller {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.dropFirst().first == "--ivy-install-update" else { return false }
        guard args.count == 7, let pid = Int32(args[2]), pid > 1, ReleaseVersion(args[5]) != nil else { return true }
        let target = URL(fileURLWithPath: args[3]).standardizedFileURL
        let source = URL(fileURLWithPath: args[4]).standardizedFileURL
        let folder = URL(fileURLWithPath: args[6]).standardizedFileURL
        let backup = target.deletingLastPathComponent().appendingPathComponent(".IVY-backup-\(UUID().uuidString).app")
        let fm = FileManager.default
        let receipt = folder.appendingPathComponent("launch-receipt.json")
        var movedOld = false; var installed = false
        do {
            guard folder.deletingLastPathComponent() == AppPaths.temporary.standardizedFileURL,
                  folder.lastPathComponent.hasPrefix("Update-"), source == folder.appendingPathComponent("IVY.app"),
                  target.pathExtension == "app", !target.path.hasPrefix(folder.path + "/") else { throw UpdateError.signature }
            try verify(source, matching: target, version: args[5])
            for _ in 0..<600 {
                if kill(pid, 0) != 0 { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard kill(pid, 0) != 0 else { throw UpdateError.installation("IVY didn't exit; the update was cancelled.") }
            try fm.moveItem(at: target, to: backup); movedOld = true
            // ditto preserves executable permissions, resource forks and signing metadata.
            guard process("/usr/bin/ditto", [source.path, target.path]) == 0 else { throw UpdateError.installation("Couldn't install the update.") }
            installed = true; try verify(target, matching: backup, version: args[5])
            guard process("/usr/bin/open", ["-n", target.path, "--args", "--ivy-update-receipt", receipt.path]) == 0 else { throw UpdateError.installation("Couldn't restart IVY.") }
            var acknowledged = false
            for _ in 0..<200 {
                if fm.fileExists(atPath: receipt.path) { acknowledged = true; break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard acknowledged else { throw UpdateError.installation("The new app didn't finish starting. The previous version was restored.") }
            try? fm.removeItem(at: backup)
            try? fm.removeItem(at: AppPaths.applicationSupport.appendingPathComponent("update-error.json"))
        } catch {
            if movedOld {
                for application in NSRunningApplication.runningApplications(withBundleIdentifier: "com.ravoxx.IVY") where application.bundleURL?.standardizedFileURL == target && application.processIdentifier != pid {
                    _ = application.terminate()
                    for _ in 0..<30 {
                        if application.isTerminated { break }
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                    if !application.isTerminated { _ = application.forceTerminate() }
                }
                if installed || fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
                try? fm.moveItem(at: backup, to: target)
                _ = process("/usr/bin/open", ["-n", target.path])
            }
            let receipt: JSONValue = ["message": .string(error.localizedDescription), "date": .string(Date().formatted(.iso8601))]
            try? fm.createDirectory(at: AppPaths.applicationSupport, withIntermediateDirectories: true)
            try? Data(receipt.jsonString().utf8).write(to: AppPaths.applicationSupport.appendingPathComponent("update-error.json"), options: .atomic)
        }
        try? fm.removeItem(at: folder)
        return true
    }
    static func confirmLaunch() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--ivy-update-receipt"), args.indices.contains(index + 1) else { return }
        let receipt = URL(fileURLWithPath: args[index + 1]).standardizedFileURL
        let folder = receipt.deletingLastPathComponent()
        guard receipt.lastPathComponent == "launch-receipt.json",
              folder.deletingLastPathComponent() == AppPaths.temporary.standardizedFileURL,
              folder.lastPathComponent.hasPrefix("Update-") else { return }
        try? Data("started".utf8).write(to: receipt, options: .atomic)
    }

    static func verify(_ app: URL, matching installed: URL, version: String) throws {
        guard let bundle = Bundle(url: app), let old = Bundle(url: installed),
              bundle.bundleIdentifier == old.bundleIdentifier, bundle.bundleIdentifier == "com.ravoxx.IVY",
              let actual = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
              ReleaseVersion(actual) == ReleaseVersion(version) else { throw UpdateError.signature }
        func signing(_ url: URL) throws -> String {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), nil) == errSecSuccess else { throw UpdateError.signature }
            var info: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                  let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { throw UpdateError.signature }
            return team
        }
        guard try signing(app) == signing(installed) else { throw UpdateError.signature }
    }
    @discardableResult static func process(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus }
        catch { return -1 }
    }
}

private final class UpdateDownloadObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let limit: Int64
    let progress: @Sendable (Int64) -> Void
    init(limit: Int64, progress: @escaping @Sendable (Int64) -> Void) { self.limit = limit; self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit { downloadTask.cancel() }
        progress(totalBytesWritten)
    }
}
