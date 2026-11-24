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
    private var didCheckOnLaunch = false

    private init() {
        let last = UserDefaults.standard.double(forKey: Self.checkKey)
        if last > 0 { lastChecked = Date(timeIntervalSince1970: last) }
    }

    var available: ParcelUpdateRelease? {
        guard let latest, ParcelUpdateVersions.newer(latest.version, than: ParcelUpdateVersions.installed)
        else { return nil }
        return latest
    }

    // Exactly one automatic network check per app process launch, not on
    // every return from the background and not every time a settings page opens.
    func checkOnLaunch() async {
        guard !didCheckOnLaunch else { return }
        didCheckOnLaunch = true
        guard UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true else { return }
        await check(force: false)
    }

    func check(force: Bool = false) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        errorMessage = nil
        do {
            var request = URLRequest(
                url: URL(string: "https://api.github.com/repos/O96u/ParcelHelper/releases?per_page=50")!,
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
            guard data.count < 4_000_000,
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let release = list.compactMap(Self.parse)
                    .filter({ $0.ipa != nil })
                    .max(by: {
                        let left = ParcelUpdateVersions.numbers($0.version) ?? []
                        let right = ParcelUpdateVersions.numbers($1.version) ?? []
                        return left.lexicographicallyPrecedes(right)
                    })
            else {
                throw UpdateError.message("未找到包含 ParcelHelper.ipa 的正式版本")
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

    private static func parse(_ json: [String: Any]) -> ParcelUpdateRelease? {
        guard json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
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
                Text("启用后每次启动 App 自动检查一次，不会在切回前台时反复检查；也可手动检查。不会在后台运行。")
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


// Local, bounded diagnostics. Only explicitly authored stage names and counts
// are recorded. Never pass raw HTML, URLs, cookies, headers, tokens, order IDs,
// tracking numbers, phone numbers, addresses, or product names to this logger.
@MainActor enum ParcelRunLog {
    struct Entry: Codable, Identifiable {
        var id: UUID = UUID()
        var date: Date
        var subsystem: String
        var event: String
        var level: String? = nil
        var taskID: String? = nil
        var elapsed: Double? = nil
        var severity: String { level ?? ParcelRunLog.classify(event) }
    }

    nonisolated static func classify(_ event: String) -> String {
        if ["失败", "错误"].contains(where: event.contains) { return "错误" }
        if ["超时", "失效", "无法", "未完成"].contains(where: event.contains) { return "警告" }
        if ["成功", "已完成", "读取结束", "已合并"].contains(where: event.contains) { return "成功" }
        return "信息"
    }

    private static let key = "native.runtime.diagnostics.v1"
    private static let maximumEntries = 240

    // Keep source IDs unchanged in sync/storage. Translate only text that
    // reaches the diagnostic interface or its shareable export.
    private static let subsystemNames: [String: String] = [
        "jd": "京东", "taobao": "淘宝", "cainiao": "菜鸟",
        "pdd": "拼多多", "fengchao": "丰巢", "mi": "小米",
        "douyin": "抖音", "kdniao": "快递鸟",
        "kuaidi100": "快递100", "publictracking": "免费物流查询",
        "sf": "顺丰", "zto": "中通", "yto": "圆通",
        "sto": "申通", "jtexpress": "极兔", "ems": "邮政"
    ]
    static func displaySubsystem(_ raw: String) -> String {
        subsystemNames[raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] ?? raw
    }
    private static func displayEvent(_ raw: String) -> String {
        // Do not replace fragments of real tracking identifiers or URLs.
        // Match standalone internal platform keys only (case-insensitive).
        let tokens: [(String, String)] = [
            ("publictracking", "免费物流查询"), ("kuaidi100", "快递100"),
            ("fengchao", "丰巢"), ("cainiao", "菜鸟"),
            ("taobao", "淘宝"), ("kdniao", "快递鸟"),
            ("douyin", "抖音"), ("jtexpress", "极兔"),
            ("pdd", "拼多多"), ("jd", "京东")
        ]
        var result = raw
        for (token, label) in tokens {
            result = result.replacingOccurrences(
                of: "(?<![A-Za-z0-9_-])" + token + "(?![A-Za-z0-9_-])",
                with: label, options: [.regularExpression, .caseInsensitive])
        }
        return result
    }
    private static func localized(_ entry: Entry) -> Entry {
        Entry(id: entry.id, date: entry.date,
              subsystem: displaySubsystem(entry.subsystem),
              event: displayEvent(entry.event), level: entry.severity, taskID: entry.taskID, elapsed: entry.elapsed)
    }

    static func entries() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return items.map(localized)
    }

    static func record(_ subsystem: String, _ event: String, level: String? = nil, taskID: String? = nil, elapsed: Double? = nil) {
        // Defense in depth: replace long identifiers and suspicious values in
        // case a future call accidentally includes a URL or raw platform error.
        func redact(_ raw: String) -> String {
            let patterns = [
                #"https?://[^\s]+"#,
                #"\b[A-Za-z0-9_-]{18,}\b"#,
                #"\b\d{7,}\b"#,
                #"(?i)(?:cookie|token|password|secret|apikey)\s*[:=]\s*[^\s]+"#
            ]
            return patterns.reduce(String(raw.prefix(240))) {
                $0.replacingOccurrences(of: $1, with: "[已隐藏]",
                                        options: .regularExpression)
            }
        }
        var items = entries()
        items.append(Entry(date: Date(),
                           subsystem: displaySubsystem(redact(subsystem)),
                           event: displayEvent(redact(event)),
                           level: level ?? classify(event), taskID: taskID, elapsed: elapsed))
        if items.count > maximumEntries {
            items.removeFirst(items.count - maximumEntries)
        }
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func export() -> String {
        let lines = entries().map { entry in
            let stamp = entry.date.formatted(date: .numeric, time: .standard)
            let context = entry.taskID.map { " [任务 " + $0 + "]" } ?? ""
            let duration = entry.elapsed.map { String(format: " %.1f秒", $0) } ?? ""
            return "[\(stamp)] [\(entry.subsystem)] [\(entry.severity)]" + context + " " + entry.event + duration
        }
        return (["ParcelHelper \(ParcelUpdateVersions.installed) · 本地运行日志",
                 "仅包含流程阶段、状态和数量，不包含登录凭据及订单详情。", ""]
                + lines).joined(separator: "\n")
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

@MainActor struct ParcelRunLogPage: View {
    @State private var records: [ParcelRunLog.Entry] = []
    @State private var selectedSource = "全部来源"
    @State private var selectedLevel = "全部"
    @State private var copied = false
    @State private var confirmClear = false

    private var sourceNames: [String] {
        ["全部来源"] + Array(Set(records.map(\.subsystem))).sorted()
    }
    private var visibleRecords: [ParcelRunLog.Entry] {
        let items = selectedSource == "全部来源" ? records :
            records.filter { $0.subsystem == selectedSource }
        return Array(items.filter { selectedLevel == "全部" || $0.severity == selectedLevel }.reversed())
    }
    private func symbol(for event: String) -> String {
        if ["失败", "错误", "超时", "失效", "无法", "未完成"].contains(where: event.contains) {
            return "exclamationmark.circle"
        }
        if ["成功", "已完成", "读取结束", "已合并"].contains(where: event.contains) {
            return "checkmark.circle"
        }
        return "circle.dotted"
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Label("本地运行记录", systemImage: "list.bullet.rectangle")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(records.count) 条")
                        .foregroundStyle(.secondary)
                        .font(.subheadline.monospacedDigit())
                }
                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = ParcelRunLog.export()
                        copied = true
                    } label: {
                        Label(copied ? "已复制" : "复制全部", systemImage: "doc.on.doc")
                    }
                    .disabled(records.isEmpty)
                    Spacer()
                    HStack(spacing: 4) {
                        Button { reload() } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 40, height: 40)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("刷新日志")
                        Button(role: .destructive) { confirmClear = true } label: {
                            Image(systemName: "trash")
                                .frame(width: 40, height: 40)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("清空日志")
                        .disabled(records.isEmpty)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.borderless)
            } footer: {
                Text("仅保存在本机，最多 240 条；不包含账号凭据与订单详情。")
            }

            Section {
                Picker("级别", selection: $selectedLevel) {
                    ForEach(["全部", "信息", "成功", "警告", "错误"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented)
                if visibleRecords.isEmpty {
                    ContentUnavailableView("暂无运行日志",
                        systemImage: "text.book.closed",
                        description: Text("同步包裹后可在这里查看记录"))
                } else {
                    ForEach(visibleRecords) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.severity == "成功" ? "checkmark.circle" : item.severity == "警告" ? "exclamationmark.circle" : "circle.dotted")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    Text(item.subsystem)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer(minLength: 8)
                                    Text(item.date.formatted(date: .omitted, time: .standard))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text(item.event)
                                    .font(.subheadline)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            } header: {
                HStack {
                    Text("运行记录")
                    Spacer()
                    if !records.isEmpty {
                        Picker("筛选来源", selection: $selectedSource) {
                            ForEach(sourceNames, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }
            }
        }
        .navigationTitle("运行日志")
        .onAppear(perform: reload)
        .alert("确认清空运行日志？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("清空日志", role: .destructive) {
                ParcelRunLog.clear()
                reload()
            }
        } message: {
            Text("将永久删除本机保存的 \(records.count) 条运行记录，无法撤销；不会删除包裹或账号数据。")
        }
    }

    private func reload() {
        records = ParcelRunLog.entries()
        if !sourceNames.contains(selectedSource) { selectedSource = "全部来源" }
        copied = false
    }
}
