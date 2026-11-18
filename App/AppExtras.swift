import SwiftUI
import Foundation
import UIKit

// The public GitHub Release is a *download source*, not an installation
// authority. A sideloaded IPA must still be signed by the user's signing app.
struct ParcelUpdateRelease: Identifiable {
    let version: String
    let tag: String
    let notes: String
    let page: URL
    let ipa: URL?
    let ipaSize: Int64
    let publishedAt: Date?

    var id: String { tag }
}

enum ParcelUpdateVersions {
    static var installed: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func numbers(_ raw: String) -> [Int]? {
        let text = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2])
        else { return nil }
        return [major, minor, patch]
    }

    static func newer(_ candidate: String, than installed: String) -> Bool {
        guard let lhs = numbers(candidate), let rhs = numbers(installed) else { return false }
        return lhs.lexicographicallyPrecedes(rhs) == false && lhs != rhs
    }
}

@MainActor final class ParcelUpdateCenter: ObservableObject {
    static let shared = ParcelUpdateCenter()

    @Published private(set) var latest: ParcelUpdateRelease?
    @Published private(set) var checking = false
    @Published private(set) var downloading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var downloadedURL: URL?

    private static let checkKey = "native.update.checkedAt"
    static let autoCheckKey = "native.update.autoCheck"
    private let interval: TimeInterval = 6 * 3600

    private init() {
        let last = UserDefaults.standard.double(forKey: Self.checkKey)
        if last > 0 { lastChecked = Date(timeIntervalSince1970: last) }
    }

    var available: ParcelUpdateRelease? {
        guard let latest, ParcelUpdateVersions.newer(latest.version, than: ParcelUpdateVersions.installed)
        else { return nil }
        return latest
    }

    func checkOnForeground() async {
        guard UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true else { return }
        await check(force: false)
    }

    func check(force: Bool = false) async {
        guard !checking else { return }
        if !force, latest != nil, let lastChecked, Date().timeIntervalSince(lastChecked) < interval { return }
        checking = true
        defer { checking = false }
        errorMessage = nil
        do {
            var request = URLRequest(
                url: URL(string: "https://api.github.com/repos/O96u/ParcelHelper/releases/latest")!,
                cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("ParcelHelper/" + ParcelUpdateVersions.installed, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UpdateError.message("无法连接 GitHub 更新服务")
            }
            guard http.statusCode == 200 else {
                throw UpdateError.message(http.statusCode == 403 || http.statusCode == 429
                    ? "GitHub 请求受限，请稍后再检查" : "查询失败：HTTP \(http.statusCode)")
            }
            guard let release = Self.parse(data) else {
                throw UpdateError.message("最新 Release 缺少有效版本信息")
            }
            latest = release
            let date = Date()
            lastChecked = date
            UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.checkKey)
            if let url = downloadedURL, !FileManager.default.fileExists(atPath: url.path) {
                downloadedURL = nil
            }
        } catch is CancellationError {
            // Leaving a screen must not be presented as an update failure.
        } catch {
            if (error as? URLError)?.code != .cancelled {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func parse(_ data: Data) -> ParcelUpdateRelease? {
        guard data.count < 1_000_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String,
              let numbers = ParcelUpdateVersions.numbers(tag),
              let pageString = json["html_url"] as? String,
              let page = URL(string: pageString),
              page.scheme == "https", page.host == "github.com",
              page.path.hasPrefix("/O96u/ParcelHelper/releases/tag/")
        else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let asset = assets.first { ($0["name"] as? String) == "ParcelHelper.ipa" }
        let candidate = (asset?["browser_download_url"] as? String).flatMap(URL.init(string:))
        let ipa: URL?
        if let candidate,
           candidate.scheme == "https", candidate.host == "github.com",
           candidate.path.hasPrefix("/O96u/ParcelHelper/releases/download/"),
           candidate.path.hasSuffix("/ParcelHelper.ipa") {
            ipa = candidate
        } else { ipa = nil }
        let published = (json["published_at"] as? String)
            .flatMap { ISO8601DateFormatter().date(from: $0) }
        return ParcelUpdateRelease(
            version: numbers.map(String.init).joined(separator: "."),
            tag: tag, notes: json["body"] as? String ?? "", page: page, ipa: ipa,
            ipaSize: (asset?["size"] as? NSNumber)?.int64Value ?? 0,
            publishedAt: published)
    }

    func cachedFile(for release: ParcelUpdateRelease) -> URL? {
        let url = Self.fileURL(for: release)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 100_000,
              release.ipaSize <= 0 || size.int64Value == release.ipaSize
        else { return nil }
        return url
    }

    static func fileURL(for release: ParcelUpdateRelease) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ParcelUpdates", isDirectory: true)
            .appendingPathComponent("ParcelHelper-\(release.version).ipa")
    }

    @discardableResult
    func download(_ release: ParcelUpdateRelease) async throws -> URL {
        guard !downloading else { throw UpdateError.message("正在下载安装包") }
        if let cached = cachedFile(for: release) {
            downloadedURL = cached
            return cached
        }
        guard let url = release.ipa else {
            throw UpdateError.message("该版本没有 ParcelHelper.ipa 安装包")
        }
        downloading = true
        progress = 0
        defer { downloading = false }
        let reporter = ParcelUpdateDownloadProgress { [weak self] amount in
            Task { @MainActor [weak self] in
                self?.progress = amount
            }
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 180)
        request.setValue("ParcelHelper/" + ParcelUpdateVersions.installed, forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await URLSession.shared.download(for: request, delegate: reporter)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.message("IPA 下载失败，请稍后重试")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 100_000, release.ipaSize <= 0 || bytes == release.ipaSize else {
            throw UpdateError.message("IPA 下载大小不完整，请重新下载")
        }
        let handle = try FileHandle(forReadingFrom: temporary)
        let header = try handle.read(upToCount: 4)
        try handle.close()
        guard header?.starts(with: [0x50, 0x4b, 0x03, 0x04]) == true else {
            throw UpdateError.message("收到的文件不是有效的 IPA 压缩包")
        }
        let target = Self.fileURL(for: release)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep one recent version, without deleting unrelated App files.
        let folder = target.deletingLastPathComponent()
        let oldFiles = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in oldFiles where file.pathExtension == "ipa" && file != target {
            try? FileManager.default.removeItem(at: file)
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: temporary, to: target)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = folder
        try? directory.setResourceValues(values)
        progress = 1
        downloadedURL = target
        return target
    }

    func removeDownloads() {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ParcelUpdates", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        downloadedURL = nil
        progress = 0
    }

    private enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }
}

private final class ParcelUpdateDownloadProgress: NSObject, URLSessionDownloadDelegate,
                                                   @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void

    init(_ onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}

struct ParcelUpdateShareFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct ParcelUpdateShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ParcelUpdatePage: View {
    @StateObject private var update = ParcelUpdateCenter.shared
    @AppStorage(ParcelUpdateCenter.autoCheckKey) private var autoCheck = true
    @State private var fileToShare: ParcelUpdateShareFile?
    @State private var downloadError: String?
    @State private var copiedLCSignSource = false

    private var installed: String { ParcelUpdateVersions.installed }

    var body: some View {
        Form {
            Section {
                LabeledContent("当前版本", value: installed)
                LabeledContent("最新版本", value: update.latest?.version ?? "尚未检查")
                if let checked = update.lastChecked {
                    LabeledContent("上次检查", value: checked.formatted(date: .abbreviated, time: .shortened))
                }
                if let available = update.available {
                    Label("发现新版本 \(available.version)", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.blue).fontWeight(.medium)
                } else if update.latest != nil {
                    Label("已是最新版本", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } header: {
                Text("ParcelHelper 更新")
            }

            Section {
                Toggle("自动检查更新", isOn: $autoCheck)
                Button {
                    Task { await update.check(force: true) }
                } label: {
                    HStack {
                        Label("检查更新", systemImage: "arrow.clockwise")
                        Spacer()
                        if update.checking { ProgressView() }
                    }
                }.disabled(update.checking)
                if let message = update.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.orange)
                }
            } footer: {
                Text("启用后在打开 App 或返回前台时检查，最多每 6 小时检查一次；iOS 不保证后台定时执行。")
            }

            Section {
                Button {
                    UIPasteboard.general.string = "https://github.com/O96u/ParcelHelper/releases"
                    copiedLCSignSource = true
                } label: {
                    Label(copiedLCSignSource ? "已复制 LCSign 软件源地址" : "复制 LCSign 软件源地址",
                          systemImage: copiedLCSignSource ? "checkmark.circle" : "doc.on.doc")
                }
                Text("在 LCSign 的「软件源」中添加刚复制的 GitHub Releases 地址。新版 LCSign 支持直接识别其中的 IPA、跟踪版本更新；在 LCSign 内选择更新并完成签名安装。")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("更省事的更新方式")
            } footer: {
                Text("只需在 LCSign 添加一次；LCSign 的版本追踪和安装仍取决于其软件源配置及证书。")
            }

            if let release = update.available {
                Section("更新内容 · \(release.version)") {
                    if let date = release.publishedAt {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("此版本没有提供更新说明。")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(release.notes)
                            .font(.subheadline)
                            .textSelection(.enabled)
                    }
                }
                Section {
                    if let cached = update.cachedFile(for: release) {
                        Button {
                            fileToShare = ParcelUpdateShareFile(url: cached)
                        } label: {
                            Label("用 LCSign / 其他签名工具安装", systemImage: "square.and.arrow.up")
                        }
                    } else if release.ipa != nil {
                        Button {
                            Task {
                                do {
                                    let file = try await update.download(release)
                                    fileToShare = ParcelUpdateShareFile(url: file)
                                } catch {
                                    downloadError = error.localizedDescription
                                }
                            }
                        } label: {
                            HStack {
                                Label(update.downloading ? "正在下载 IPA…" : "下载新版 IPA",
                                      systemImage: "arrow.down.circle")
                                Spacer()
                                if update.downloading {
                                    Text("\(Int(update.progress * 100))%")
                                        .font(.caption.monospacedDigit())
                                } else if release.ipaSize > 0 {
                                    Text(ByteCountFormatter.string(fromByteCount: release.ipaSize,
                                                                   countStyle: .file))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(update.downloading)
                        if update.downloading { ProgressView(value: update.progress) }
                    } else {
                        Text("该 Release 暂无 IPA 附件，请到 GitHub 查看。")
                            .foregroundStyle(.secondary)
                    }
                    Link(destination: release.page) {
                        Label("查看 GitHub Release", systemImage: "arrow.up.right.square")
                    }
                } footer: {
                    Text("IPA 是未签名构建。下载后使用系统分享面板选择 LCSign，签名后安装；不会绕过 iOS 安装限制。请保留原来的 Bundle ID 与签名配置，才能覆盖更新且保留数据。")
                }
            } else {
                Section {
                    Link(destination: URL(string: "https://github.com/O96u/ParcelHelper/releases")!) {
                        Label("查看版本历史", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
        }
        .navigationTitle("软件更新")
        .navigationBarTitleDisplayMode(.inline)
        .task { await update.check(force: false) }
        .sheet(item: $fileToShare) { file in
            ParcelUpdateShareSheet(url: file.url)
        }
        .alert("下载失败", isPresented: Binding(
            get: { downloadError != nil },
            set: { if !$0 { downloadError = nil } }
        )) {
            Button("确定") { downloadError = nil }
        } message: {
            Text(downloadError ?? "")
        }
    }
}
