import Foundation
import SwiftUI
import WebKit
import CryptoKit

// Native iOS adaptation of the Scripting source modules:
// utils/pddExpress.ts, utils/cainiao.ts, utils/mtop.ts and utils/model.ts.
// These are H5 endpoints used by the original project, NOT contracted public
// third-party APIs. No captcha bypass; failure must never be called success.

enum NativeSyncError: LocalizedError {
    case noLogin(String), verify(String), unavailable(String), badResponse(String)
    var errorDescription: String? {
        switch self {
        case .noLogin(let x), .verify(let x), .unavailable(let x), .badResponse(let x): return x
        }
    }
}
struct NativeSyncParcel: Sendable {
    var source: String
    var accountID: String = ""
    var orderID: String = ""
    var orderStatus: String = ""
    // Only an official, structured JD logistics response may create an
    // order-linked progress card before a courier waybill is assigned.
    var verifiedJDOrderLogistics: Bool = false
    var mailNo: String = ""
    var title: String = ""
    var company: String = ""
    var code: String = ""
    var station: String = ""
    var latest: String = ""
    var tracks: [TrackNode] = []
    var arrived: Bool = false
    var eta: String = ""
}
struct NativeSyncResult {
    let name: String
    let found: Int
    let imported: Int
    let errors: [String]
    var description: String {
        if !errors.isEmpty { return "\(name)：导入 \(imported) 件；" + errors.joined(separator: "；") }
        return "\(name)：发现 \(found) 件，新增或更新 \(imported) 件"
    }
}
enum SyncJSON {
    static func dict(_ v: Any?) -> [String: Any] { v as? [String: Any] ?? [:] }
    static func list(_ v: Any?) -> [[String: Any]] { v as? [[String: Any]] ?? [] }
    static func str(_ v: Any?) -> String {
        if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }
    static func first(_ d: [String: Any], _ keys: [String]) -> String {
        for key in keys {
            let s = str(d[key])
            if !s.isEmpty { return s }
        }
        return ""
    }
    static func isMail(_ value: String) -> Bool {
        let s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (8...40).contains(s.count) &&
               s.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil
    }
    static func pickup(_ raw: String) -> String {
        let t = raw.replacingOccurrences(of: "取件码", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let blocked = ["", "0", "-1", "needsms", "need_sms", "null", "none", "true", "false"]
        return blocked.contains(t.lowercased()) ? "" : String(t.prefix(50))
    }
}

@MainActor enum WebCookieRequest {
    static let store = WKWebsiteDataStore.default().httpCookieStore
    static func cookieStore(accountID: String? = nil) -> WKHTTPCookieStore {
        ParcelAccounts.websiteDataStore(for: accountID ?? "legacy:taobao").httpCookieStore
    }
    static func cookies(domain: String, accountID: String? = nil) async -> [HTTPCookie] {
        await cookieStore(accountID: accountID).allCookies().filter {
            ($0.domain == domain || $0.domain.hasSuffix("." + domain)) &&
            ($0.expiresDate == nil || ($0.expiresDate ?? .distantPast) > Date())
        }
    }
    /// Match the cookies WKWebView would send to the exact MTOP host and
    /// path, not every unrelated Taobao subdomain. Keep only one cookie per
    /// name so the signed _m_h5_tk matches the Cookie request header.
    static func mtopCookies(for url: URL, accountID: String) async -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        let saved = await cookieStore(accountID: accountID).allCookies()
        let matching = saved.filter { cookie in
            let domain = cookie.domain.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            return (host == domain || host.hasSuffix("." + domain)) &&
                (path == cookiePath || path.hasPrefix(
                    cookiePath.hasSuffix("/") ? cookiePath : cookiePath + "/")) &&
                (cookie.expiresDate == nil || cookie.expiresDate! > Date()) &&
                !cookie.value.isEmpty
        }.sorted { left, right in
            // RFC-style precedence: the most specific path/domain first.
            if left.path.count != right.path.count {
                return left.path.count > right.path.count
            }
            return left.domain.count > right.domain.count
        }
        var names = Set<String>()
        return matching.filter { names.insert($0.name).inserted }
    }

    static func mtopHeaders(cookies: [HTTPCookie]) throws -> [String: String] {
        guard !cookies.isEmpty else {
            throw NativeSyncError.noLogin("未检测到当前账号的淘宝网页会话")
        }
        return [
            "Cookie": cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "),
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 Version/17.5 Mobile/15E148 Safari/604.1",
            "Accept": "application/json"
        ]
    }

    static func headers(domain: String, accountID: String? = nil) async throws -> [String: String] {
        let cookies = await cookies(domain: domain, accountID: accountID)
        guard !cookies.isEmpty else {
            throw NativeSyncError.noLogin("尚未检测到\(domain)网页会话，请先网页登录")
        }
        return [
            "Cookie": cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "),
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 Version/17.5 Mobile/15E148 Safari/604.1",
            "Accept": "application/json"
        ]
    }
    static func request(_ url: URL, method: String = "GET", headers: [String: String], body: Data? = nil) async throws -> ([String: Any], HTTPURLResponse) {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
        req.httpMethod = method
        req.httpBody = body
        // Explicit cookies come from the selected WebKit account. Do not mix
        // them with URLSession.shared's unrelated system cookie jar.
        req.httpShouldHandleCookies = false
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NativeSyncError.badResponse("服务器未返回 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw NativeSyncError.noLogin("账号会话失效或访问受限（HTTP \(http.statusCode)）")
            }
            throw NativeSyncError.unavailable("请求失败（HTTP \(http.statusCode)）")
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (json, http)
        }
        // The original Scripting/pddExpress.ts also accepts the H5Response
        // wrappers returned by some PDD mdkd endpoints.
        if url.host == "api.pinduoduo.com", let source = String(data: data, encoding: .utf8) {
            let tags = ["RESULT", "result", "DATA", "data", "DATA_JSON", "body"]
            for tag in tags {
                let escaped = NSRegularExpression.escapedPattern(for: tag)
                guard let regex = try? NSRegularExpression(
                    pattern: "<" + escaped + ">([\\s\\S]*?)</" + escaped + ">",
                    options: [.caseInsensitive]),
                    let match = regex.firstMatch(in: source,
                        range: NSRange(source.startIndex..., in: source)),
                    let range = Range(match.range(at: 1), in: source) else { continue }
                let nested = String(source[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&amp;", with: "&")
                if let blob = nested.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: blob) as? [String: Any] {
                    return (object, http)
                }
            }
            let fields = ["identification_code", "expire_mills", "mobile_info_desc",
                          "error_code", "error_msg"]
            var extracted: [String: Any] = [:]
            for field in fields {
                let escaped = NSRegularExpression.escapedPattern(for: field)
                guard let regex = try? NSRegularExpression(
                    pattern: "<" + escaped + ">([^<]+)</" + escaped + ">",
                    options: [.caseInsensitive]),
                    let match = regex.firstMatch(in: source,
                        range: NSRange(source.startIndex..., in: source)),
                    let range = Range(match.range(at: 1), in: source) else { continue }
                extracted[field] = String(source[range])
            }
            if extracted["identification_code"] != nil {
                return (["result": extracted], http)
            }
            let summary = source.replacingOccurrences(of: "<[^>]*>", with: " ",
                options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if summary.localizedCaseInsensitiveContains("登录") ||
               summary.localizedCaseInsensitiveContains("验证") {
                throw NativeSyncError.noLogin("拼多多会话失效或需要官方 App 安全验证")
            }
        }
        throw NativeSyncError.badResponse("接口返回非 JSON，可能需要在平台内完成验证")
    }
}

/// Refreshes the MTOP token through the SAME gateway host that issued
/// the failed request, inside the selected account's persistent WebKit store.
/// Loading h5.m.taobao.com is insufficient when the API host uses a different
/// scoped token cookie. This WebView never appears in the UI and does not
/// inspect webpage contents, passwords, or identity codes.
@MainActor final class CainiaoMtopTokenRefresh: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var continuation: CheckedContinuation<Void, Never>?

    init(accountID: String) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = ParcelAccounts.websiteDataStore(for: accountID)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    func run(gatewayURL: URL) async {
        // No third-party URLs or login pages. Revisit the MTOP gateway URL
        // so WebKit can accept host-scoped Set-Cookie for this account.
        guard gatewayURL.scheme == "https",
              gatewayURL.host == "h5api.m.taobao.com" else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
            webView.load(URLRequest(url: gatewayURL,
                cachePolicy: .reloadIgnoringLocalCacheData))
            // Retain the refresh owner until its continuation is resumed.
            // WKNavigationDelegate is weak; a weak timeout can otherwise
            // leave this async refresh suspended indefinitely.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                self.finish()
            }
        }
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        continuation.resume()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish()
    }
    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finish()
    }
    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!, withError error: Error) {
        finish()
    }
}

@MainActor enum NativeParcelSync {
    static let platforms = ["pdd", "cainiao", "fengchao", "mi"]
    // Throttle user-triggered refreshes too: no bursts into private endpoints.
    static let minGap: TimeInterval = 30
    private static var activeJobs = Set<String>()

    static func run(_ id: String, force: Bool = false,
                    accountID: String? = nil) async throws -> NativeSyncResult {
        guard platforms.contains(id) else {
            throw NativeSyncError.unavailable("该平台尚未完成 Swift 原生查询适配")
        }
        if id == "pdd" && !PddAccountProtection.webAccessAllowed {
            throw NativeSyncError.unavailable("拼多多同步已暂停，以保护官方 App 的登录状态。可在拼多多账号详情手动开启。")
        }
        let selected = accountID ?? ParcelAccounts.activeID(for: id)
        let generation = ParcelAccounts.syncGeneration(selected)
        guard id == "mi" || ParcelAccounts.canSync(id, accountID: selected) else { throw CancellationError() }
        let job = id + "|" + selected
        guard activeJobs.insert(job).inserted else {
            throw NativeSyncError.unavailable("该账号已有同步任务")
        }
        defer { activeJobs.remove(job) }
        let key = "native.sync.at." + id + "." + selected
        let retryKey = "native.sync.retryAfter." + id + "." + selected
        let failuresKey = "native.sync.failures." + id + "." + selected
        let now = Date().timeIntervalSince1970
        if !force && now < UserDefaults.standard.double(forKey: retryKey) {
            throw NativeSyncError.unavailable("账号正在等待失败退避，稍后会自动再试")
        }
        let last = UserDefaults.standard.double(forKey: key)
        // Force bypasses retry backoff, not endpoint rate limiting. The old
        // condition unintentionally let a rapid manual tap burst the API.
        if now - last < minGap {
            throw NativeSyncError.unavailable("请求过于频繁，请 30 秒后再试")
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        do {
            let incoming: [NativeSyncParcel]
            if id == "pdd" { incoming = try await pddPackages(accountID: selected) }
            else if id == "cainiao" {
                var rows = try await cainiaoPackages(accountID: selected)
                let seen = Set(rows.map { $0.mailNo.uppercased() })
                // After official sign-off a parcel may disappear from the
                // active package list. Check a small bounded set of existing
                // uncollected parcels belonging to THIS account for a newer
                // status; never interpret missing parcels as collected.
                let candidates = ParcelStore.shared.snapshot.parcels.filter { parcel in
                    let source = parcel.source ?? parcel.srcApp?.id ?? ""
                    let mail = parcel.mailNo ?? ""
                    let linked = parcel.linkedAccounts ?? []
                    let belongs = linked.contains(selected) ||
                        (linked.isEmpty && selected == ParcelAccounts.legacyID("taobao"))
                    // A Taobao order may later merge with a Cainiao station
                    // record for the same mail number. Keep that record
                    // eligible for a Cainiao status recheck.
                    return (source == "cainiao" || source == "taobao") && belongs &&
                        !parcel.isDone && !parcel.isSigned &&
                        SyncJSON.isMail(mail) && !seen.contains(mail.uppercased())
                }.sorted {
                    if ($0.source == "cainiao") != ($1.source == "cainiao") {
                        return $0.source == "cainiao"
                    }
                    return $0.createdAt > $1.createdAt
                }
                for parcel in candidates.prefix(3) {
                    guard let mail = parcel.mailNo,
                          let detail = await cainiaoTrack(mail, accountID: selected),
                          !detail.nodes.isEmpty || !detail.status.isEmpty else { continue }
                    var updated = NativeSyncParcel(source: "cainiao")
                    updated.accountID = selected
                    updated.mailNo = mail
                    updated.company = detail.company
                    updated.tracks = detail.nodes
                    updated.latest = detail.status.isEmpty ?
                        (detail.nodes.first?.text ?? "") : detail.status
                    rows.append(updated)
                }
                incoming = rows
            }
            else if id == "fengchao" { incoming = try await NativeFengchao.packages(accountID: selected) }
            else { incoming = try await NativeMiExpress.packages() }
            let prepared = await Task.detached(priority: .utility) {
                incoming.map { value in
                    var row = value
                    row.tracks = TrackMerge.ordered(value.tracks)
                    return row
                }
            }.value
            // A background expiration must not merge stale results or update
            // sync-success state after its parent task was cancelled.
            try Task.checkCancellation()
            if id != "mi" {
                let kind = id == "cainiao" ? "taobao" : id
                guard ParcelAccounts.canSync(kind, accountID: selected),
                      ParcelAccounts.syncGeneration(selected) == generation,
                      id != "pdd" || PddAccountProtection.webAccessAllowed,
                      id != "cainiao" || (UserDefaults.standard.object(forKey: "native.platform.enabled.cainiao") as? Bool) != false else {
                    // A removed account can finish an in-flight network
                    // request; never restore its deleted parcels afterward.
                    throw CancellationError()
                }
            }
            let baselineKey = "native.sync.baseline." + id + "." + selected
            let hadBaseline = UserDefaults.standard.bool(forKey: baselineKey)
            let count = merge(prepared, notifyNewArrival: hadBaseline)
            UserDefaults.standard.set(true, forKey: baselineKey)
            let result = NativeSyncResult(
                name: id == "pdd" ? "拼多多驿站包裹" : (id == "cainiao" ? "菜鸟" : (id == "fengchao" ? "丰巢" : "小米")),
                found: incoming.count, imported: count, errors: [])
            UserDefaults.standard.set(result.description, forKey: "native.sync.result." + id)
            UserDefaults.standard.set(result.description, forKey: "native.sync.result." + id + "." + selected)
            let syncedAt = Date().timeIntervalSince1970
            UserDefaults.standard.set(syncedAt, forKey: "native.sync.success." + id)
            UserDefaults.standard.set(syncedAt, forKey: "native.sync.success." + id + "." + selected)
            UserDefaults.standard.set(syncedAt, forKey: "native.home.lastRefresh")
            UserDefaults.standard.removeObject(forKey: retryKey)
            UserDefaults.standard.removeObject(forKey: failuresKey)
            return result
        } catch {
            // Cancellation is a scheduler decision, not a provider failure.
            // Propagate it so the background task can stop without poisoning
            // the account's exponential backoff.
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if id != "mi" && (!ParcelAccounts.canSync(id, accountID: selected) ||
                ParcelAccounts.syncGeneration(selected) != generation) { throw CancellationError() }
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain &&
               nsError.code == NSURLErrorCancelled { throw error }
            // Account-scoped exponential backoff prevents a failing platform
            // from blocking unrelated accounts. Manual force bypasses it.
            let failures = min(7, UserDefaults.standard.integer(forKey: failuresKey) + 1)
            UserDefaults.standard.set(failures, forKey: failuresKey)
            let isAuthFailure: Bool
            if let nativeError = error as? NativeSyncError {
                switch nativeError {
                case .noLogin, .verify: isAuthFailure = true
                default: isAuthFailure = false
                }
            } else {
                isAuthFailure = false
            }
            let base = min(21_600.0, 300.0 * pow(2.0, Double(failures - 1)))
            let delay = isAuthFailure ? 24 * 3600.0 :
                base * Double.random(in: 0.8...1.2)
            UserDefaults.standard.set(Date().timeIntervalSince1970 + delay,
                                      forKey: retryKey)
            let detail = error.localizedDescription
            UserDefaults.standard.set(detail, forKey: "native.sync.result." + id)
            UserDefaults.standard.set(detail, forKey: "native.sync.result." + id + "." + selected)
            Task { await ParcelNotifications.notifySyncFailure(platform: id, accountID: selected) }
            throw error
        }
    }

    // Scripting utils/platformSync.ts and utils/codes.ts compatibility.
    static func codeKey(_ raw: String) -> String {
        let half = raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw
        return half.filter { !$0.isWhitespace && !"-－—_".contains($0) }.uppercased()
    }
    static func normalizedCode(_ raw: String) -> String {
        let prefix = #"^(取件码|提货码|取货码|自提码|凭码)[:：\s]*"#
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: prefix, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let garbage = ["needsms", "need sms", "none", "null", "undefined",
                       "待出码", "待生成", "暂无", "无", "--", "—", "/", "0"]
        guard !garbage.contains(trimmed.lowercased()),
              trimmed.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{1,19}$"#, options: .regularExpression) != nil
        else { return "" }
        return trimmed
    }
    static func isAggregator(_ source: String?) -> Bool {
        ["cainiao", "fengchao", "mi"].contains(source ?? "")
    }
    static func arrivalKind(_ text: String) -> String {
        let noPickup = ["转运中心", "分拨中心", "集散中心", "运转中心", "揽收", "正在派送", "派件中"]
        // "已签收" can mean an express station signed on behalf of the user.
        // Only unequivocal pickup wording should mark an item as collected.
        if Parcel.confirmsRecipientPickup(text) { return "picked" }
        if noPickup.contains(where: { text.contains($0) }) { return "transit" }
        if Parcel.isStationArrival(text) || ["凭取件码", "请及时领取"].contains(where: text.contains) { return "arrived" }
        return "transit"
    }

    // Updates should supplement, not overwrite user decisions. Source loyalty,
    // code merging, deduplication, transit history and pickup statuses follow
    // the supplied original platformSync.ts and codes.ts design.
    @discardableResult static func merge(
        _ rows: [NativeSyncParcel], notifyNewArrival: Bool = false
    ) -> Int {
        let store = ParcelStore.shared
        var changed = 0
        var newArrivalNotifications = 0
        var notificationChanges: [(Parcel?, Parcel)] = []
        var pendingWrites: [Parcel] = []
        var working = store.snapshot.parcels
        var inserted = 0
        var updated = 0
        var historicalSkipped = 0
        let cutoff = Date().timeIntervalSince1970 * 1000 - 14 * 24 * 3600 * 1000
        for row in rows {
            if !row.accountID.isEmpty && row.source != "mi",
               !ParcelAccounts.canSync(row.source, accountID: row.accountID) { continue }
            let mail = row.mailNo.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = normalizedCode(row.code)
            let verifiedOrderProgress = row.source == "jd" &&
                row.verifiedJDOrderLogistics &&
                row.orderID.range(of: #"^\d{8,}$"#, options: .regularExpression) != nil &&
                !row.latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard SyncJSON.isMail(mail) || (row.arrived && !code.isEmpty) ||
                verifiedOrderProgress else { continue }
            let scopedAccount = row.accountID
            let orderPrefix = scopedAccount.isEmpty ||
                scopedAccount == ParcelAccounts.legacyID(row.source) ?
                row.source : row.source + ":" + scopedAccount
            let orderKey = row.orderID.isEmpty ? "" : orderPrefix + ":" + row.orderID
            // Manual delete is a user decision: never silently re-import this
            // shipment on the next platform refresh.
            guard !store.isDeletedShipment(source: row.source, order: orderKey,
                                           mail: mail, code: code, station: row.station)
            else { continue }
            // Latest provider state takes precedence over old route events.
            let currentStatus = row.latest.isEmpty ? (row.tracks.first?.text ?? "") : row.latest
            let newestTrack = TrackMerge.latest(row.tracks)?.text ?? ""
            let trackKind = arrivalKind(newestTrack)
            let kind = trackKind == "picked" ? "picked" : (trackKind == "arrived" ? "arrived" : arrivalKind(currentStatus))
            let wasArrived = row.arrived || !code.isEmpty || kind == "arrived"
            let closure = ["已取消", "退款成功", "已关闭", "退货成功"].first {
                row.latest.contains($0) || row.orderStatus.contains($0)
            }
            let normalizedMail = codeKey(mail)
            let byMail = normalizedMail.isEmpty ? nil : working.first {
                codeKey($0.mailNo ?? "") == normalizedMail
            }
            let byOrder = orderKey.isEmpty ? nil : working.first {
                $0.allOrderIDs.contains(orderKey) &&
                    (mail.isEmpty || ($0.mailNo ?? "").isEmpty ||
                     codeKey($0.mailNo ?? "") == normalizedMail)
            }
            let byCode = (wasArrived && !code.isEmpty && !row.station.isEmpty &&
                row.station != "其他驿站") ? working.first {
                    ($0.mailNo ?? "").isEmpty && $0.isPending && $0.createdAt >= cutoff &&
                    codeKey($0.code) == codeKey(code) && $0.stationText == row.station &&
                    (($0.linkedAccounts ?? []).isEmpty || $0.linkedAccounts?.contains(scopedAccount) == true)
            } : nil
            let previous = byMail ?? byOrder ?? byCode
            if let closure {
                if var existing = previous, !existing.isDone, !existing.isSigned, existing.closed != closure {
                    existing.closed = closure
                    pendingWrites.append(existing)
                    if let index = working.firstIndex(where: { $0.uuid == existing.uuid }) { working[index] = existing }
                    ParcelNotifications.cancel(existing.uuid)
                    changed += 1
                    updated += 1
                }
                continue
            }
            // Do not create records from completed historical orders.
            // Existing records still receive completed/signed tracking updates.
            let finishedOrder = ["交易成功", "已完成", "确认收货", "已收货",
                                 "已取件", "Accomplish", "Completed"].contains {
                row.orderStatus.localizedCaseInsensitiveContains($0)
            } || (row.orderStatus.contains("已签收") && !wasArrived)
            let stationTerms = ["驿站签收", "驿站代签收", "代为签收",
                                "网点签收", "快递柜签收", "暂存签收",
                                "包裹已到站", "待取件"]
            let receiptTerms = ["已签收", "签收成功", "已妥投",
                                "收件人签收", "本人签收", "已从代收点取出"]
            let finishedDelivery = [TrackMerge.latest(row.tracks)?.text ?? row.latest].contains { event in
                Parcel.confirmsRecipientPickup(event) ||
                Parcel.confirmsFinalDelivery(event) ||
                (!Parcel.isStationArrival(event) && !stationTerms.contains(where: event.contains) &&
                 receiptTerms.contains(where: event.contains))
            }
            if previous == nil && (kind == "picked" || finishedOrder || finishedDelivery ||
                                  Parcel.confirmsPersonalSignature(currentStatus) ||
                                  Parcel.isReturn(currentStatus) || Parcel.isReturn(newestTrack)) {
                historicalSkipped += 1
                continue
            }
            // An old order with no actual route detail should not become a
            // new fake in-transit shipment.
            if previous == nil && !wasArrived && row.latest.isEmpty && row.tracks.isEmpty { continue }
            var p = previous ?? Parcel()
            let priorSource = p.source
            if let previous, (previous.linkedAccounts ?? []).isEmpty,
               previous.orderId == nil,
               !["jd", "taobao", "pdd", "cainiao", "fengchao", "mi"].contains(previous.source ?? "") {
                p.retainedLocally = true
            }
            if !orderKey.isEmpty {
                if p.orderId == nil || p.orderId?.isEmpty == true { p.orderId = orderKey }
                p.linkedOrderIDs = Array(Set(p.allOrderIDs + [orderKey])).sorted()
            }
            if !scopedAccount.isEmpty {
                var owners = Set(p.linkedAccounts ?? [])
                owners.insert(scopedAccount)
                p.linkedAccounts = owners.sorted()
            }
            if (p.mailNo ?? "").isEmpty && !mail.isEmpty { p.mailNo = mail }

            if priorSource == nil || priorSource?.isEmpty == true ||
                (!isAggregator(row.source) && isAggregator(priorSource)) {
                p.source = row.source
                let names = ["pdd": "拼多多", "cainiao": "菜鸟", "taobao": "淘宝",
                             "jd": "京东", "fengchao": "丰巢", "mi": "小米"]
                p.srcApp = SourceApp(id: row.source, name: names[row.source] ?? row.source)
            }
            if (p.itemTitle == nil || p.itemTitle?.isEmpty == true ||
                p.itemTitle == "拼多多订单"), !row.title.isEmpty { p.itemTitle = row.title }
            if (p.trackCompany == nil || p.trackCompany?.isEmpty == true ||
                ["其他快递", "快递包裹", "未知", "未知快递"].contains(p.trackCompany ?? "")), !row.company.isEmpty {
                p.trackCompany = row.company
            }
            if !row.station.isEmpty && row.station != "其他驿站" {
                p.courierStationName = row.station
                if let station = StationMatcher.match(store.snapshot.stations,
                    text: [row.station, row.latest].joined(separator: " ")) {
                    p.courierStationName = station.courierStationName
                    p.courierStationUuid = station.id
                }
            }
            let shouldStoreCode = !code.isEmpty && codeKey(code) != codeKey(mail)
            if shouldStoreCode && !p.codes.contains(where: { codeKey($0) == codeKey(code) }) {
                p.codes.append(code)
                p.codes = Array(p.codes.prefix(3))
            }
            if shouldStoreCode && p.code.isEmpty { p.code = code }
            TrackMerge.apply(to: &p, nodes: row.tracks, summary: row.latest)
            if !row.tracks.isEmpty || verifiedOrderProgress {
                p.trackUpdatedAt = Date().timeIntervalSince1970 * 1000
            }
            if !row.eta.isEmpty && !wasArrived { p.eta = row.eta }

            if !p.pickedByUser {
                if p.latestPickupConfirmed {
                    p.status = 2
                    if p.pickedAt == nil, let node = TrackMerge.ordered(p.trackNodes).first,
                       let date = TrackMerge.date(node.time) { p.pickedAt = date.timeIntervalSince1970 * 1000 }
                } else if !p.isDone && !p.isSigned && wasArrived && p.arrivedAt == nil {
                    p.arrivedAt = Date().timeIntervalSince1970 * 1000
                }
            }
            if wasArrived { p.eta = nil; p.etaAt = nil }
            if p.pickedByUser { p.status = 2 }
            // Missing title, ETA, source app, order ID or receiver changes
            // here previously caused genuine server updates to be discarded.
            let contentChanged = p.hasSyncedContentChange(comparedTo: previous)
            if contentChanged || p.trackUpdatedAt != previous?.trackUpdatedAt {
                pendingWrites.append(p)
                if let index = working.firstIndex(where: { $0.uuid == p.uuid }) { working[index] = p }
                else { working.insert(p, at: 0) }
                guard contentChanged else { continue }
                if previous != nil {
                    notificationChanges.append((previous, p))
                } else if notifyNewArrival && p.isPending && newArrivalNotifications < 3 {
                    // Do not flood the user with old deliveries on a first
                    // account import. Only alert after a successful baseline.
                    newArrivalNotifications += 1
                    notificationChanges.append((nil, p))
                }
                changed += 1
                if previous == nil { inserted += 1 } else { updated += 1 }
            }
        }
        if !pendingWrites.isEmpty { store.applySyncBatch(pendingWrites) }
        if !notificationChanges.isEmpty {
            let changes = notificationChanges
            Task { await ParcelNotifications.notifyBatch(changes) }
        }
        if rows.contains(where: { $0.source == "jd" }) {
            ParcelRunLog.record("jd", "物流合并结果：新增 \(inserted) 件，更新 \(updated) 件，跳过已完成历史物流 \(historicalSkipped) 件")
        }
        return changed
    }

    // Native port of the exact three identity-code endpoints in
    // 包裹助手(1).scripting/utils/identity.ts and utils/pddExpress.ts.
    // These are private H5 interfaces: valid authorization is required and
    // endpoint availability can change. Never fabricate a platform identity.
    struct IdentityResult {
        var code: String
        var expiresAt: Date
        var certified: Bool?
        var name: String?
        var maskedID: String?
        var mobile: String?
    }
    // Accept identity codes in verified Cainiao fields across nested H5 shapes.
    // Do not substitute an order number, pickup code, or fabricated barcode.
    private static func cainiaoIdentityCode(_ value: Any?, depth: Int = 0) -> String? {
        guard depth < 8 else { return nil }
        if let dict = value as? [String: Any] {
            let fields = ["identityCode", "identity_code", "identityCodeValue",
                          "realNameIdentityCode", "realnameIdentityCode",
                          "barCode", "barcode", "qrCode", "qrcode"]
            for field in fields {
                guard let raw = dict[field] else { continue }
                let code = SyncJSON.str(raw)
                // Identity codes may contain characters outside [A-Z0-9_]
                // and can exceed 64 characters. Do not reject real codes by
                // imposing an invented format.
                if !code.hasPrefix("{"), !code.hasPrefix("["),
                   (4...1024).contains(code.count),
                   !["unknown", "invalid", "null", "undefined", "false", "true"]
                        .contains(code.lowercased()) {
                    return code
                }
                if let result = cainiaoIdentityCode(raw, depth: depth + 1) {
                    return result
                }
            }
            for field in ["model", "data", "result", "identityInfo",
                          "identity", "identityCodeInfo", "body", "value"] {
                if let result = cainiaoIdentityCode(dict[field], depth: depth + 1) {
                    return result
                }
            }
        } else if let list = value as? [Any] {
            for item in list {
                if let result = cainiaoIdentityCode(item, depth: depth + 1) {
                    return result
                }
            }
        } else if let raw = value as? String,
                  (raw.hasPrefix("{") || raw.hasPrefix("[")),
                  let data = raw.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) {
            return cainiaoIdentityCode(decoded, depth: depth + 1)
        }
        return nil
    }

    private static func identityData(_ value: Any?) -> [String: Any] {
        let direct = SyncJSON.dict(value)
        let nested = SyncJSON.dict(direct["data"])
        return nested.isEmpty ? direct : nested
    }
    private static func identityCodeIn(_ value: Any?, depth: Int = 0) -> String? {
        guard depth <= 6 else { return nil }
        if let raw = value as? String {
            return raw.range(of: #"^[A-Z]{2}[0-9A-Z]{8,26}$"#,
                             options: .regularExpression) != nil ? raw : nil
        }
        if let rows = value as? [Any] {
            for row in rows {
                if let found = identityCodeIn(row, depth: depth + 1) { return found }
            }
        }
        if let dict = value as? [String: Any] {
            for key in dict.keys.sorted(by: { a, b in
                let ap = a.lowercased().contains("code") || a.lowercased().contains("identity")
                let bp = b.lowercased().contains("code") || b.lowercased().contains("identity")
                return ap && !bp
            }) {
                if let found = identityCodeIn(dict[key], depth: depth + 1) { return found }
            }
        }
        return nil
    }
    private static func identityExpiry(_ value: Any?, depth: Int = 0) -> TimeInterval? {
        guard depth <= 6 else { return nil }
        if let dict = value as? [String: Any] {
            for (key, raw) in dict where key.lowercased().contains("expir") {
                let n = (raw as? NSNumber)?.doubleValue ??
                        Double(SyncJSON.str(raw)) ?? 0
                if n > 0 {
                    // Original Scripting handles second and millisecond durations.
                    let now = Date().timeIntervalSince1970
                    if n > 1_000_000_000_000 { return max(0, n / 1000 - now) }
                    if n > 1_000_000_000 { return max(0, n - now) }
                    return n > 1_000_000 ? n / 1000 : n
                }
            }
            for entry in dict.values {
                if let n = identityExpiry(entry, depth: depth + 1) { return n }
            }
        } else if let rows = value as? [Any] {
            for entry in rows {
                if let n = identityExpiry(entry, depth: depth + 1) { return n }
            }
        }
        return nil
    }
    private static func hasTaobaoCookie() async -> Bool {
        // Scripting tbHasLogin() checks for the presence of stored Taobao
        // cookies; their names vary between Taobao login methods. The signed
        // MTOP response, not a hardcoded cookie-name list, decides validity.
        let cookies = await WebCookieRequest.cookies(
            domain: "taobao.com", accountID: ParcelAccounts.activeID(for: "taobao"))
        return cookies.contains { !$0.name.isEmpty && !$0.value.isEmpty }
    }
    static func hasIdentitySession(_ platform: String) async -> Bool {
        if platform == "pdd" {
            // Use the same account-scoped authorization rule as the settings:
            // small-account H5 credentials may be on pinduoduo.net.
            return await ParcelAccounts.hasSession(
                "pdd", accountID: ParcelAccounts.activeID(for: "pdd"))
        }
        // Scripting checks saved Taobao cookies, while the MTOP response
        // itself verifies whether the actual identity code is available.
        if platform == "cainiao" { return await hasTaobaoCookie() }
        return await ParcelAccounts.hasSession(
            "taobao", accountID: ParcelAccounts.activeID(for: "taobao"))
    }
    static func identityCode(_ platform: String) async throws -> IdentityResult {
        guard ["taobao", "cainiao", "pdd"].contains(platform) else {
            throw NativeSyncError.unavailable("暂不支持该平台身份码")
        }
        guard await hasIdentitySession(platform) else {
            throw NativeSyncError.noLogin(platform == "pdd" ?
                "请先在「账号授权」登录拼多多" : "请先在「账号授权」登录淘宝")
        }
        if platform == "pdd" {
            let result = try await pddJSON(
                "/api/express_trackbox/generate_identification_code",
                body: ["entry_source": "APP"],
                referer: "https://m.pinduoduo.net/mdkd/package?pr_page_from=scheme&tab=ID_CODE",
                accountID: ParcelAccounts.activeID(for: "pdd"))
            let body = SyncJSON.dict(result["result"])
            let code = SyncJSON.str(body["identification_code"])
            guard !code.isEmpty else {
                throw NativeSyncError.badResponse("拼多多接口没有返回身份码，可能需要官方 App 安全验证")
            }
            let raw = (body["expire_mills"] as? NSNumber)?.doubleValue ??
                Double(SyncJSON.str(body["expire_mills"])) ?? 0
            let millis = raw > 0 ? raw : 5 * 60 * 1000
            let mobileInfo = SyncJSON.dict(body["mobile_info"])
            let mobile = SyncJSON.first(mobileInfo,
                ["mobile_desc", "mobile", "mobile_info_desc"])
            let mobileText = mobile.isEmpty ?
                SyncJSON.str(body["mobile_info_desc"]) : mobile
            return IdentityResult(code: code,
                expiresAt: Date().addingTimeInterval(millis / 1000),
                certified: nil, name: nil, maskedID: nil,
                mobile: mobileText.isEmpty ? nil : mobileText)
        }
        if platform == "cainiao" {
            // Matches the uploaded Scripting utils/identity.ts exactly:
            // the genuine code comes from Taobao-cookie MTOP, NOT an H5 page.
            let response = try await mtop(
                "mtop.cainiao.nbpickup.identitycode.get",
                data: ["appName": "GUOGUO", "verifyVersion": "V2"],
                accountID: ParcelAccounts.activeID(for: "taobao"))
            let outer = identityData(response["data"])
            let rawModel = outer["model"]
            let model: [String: Any]
            if let raw = rawModel as? String, let bytes = raw.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                model = decoded
            } else {
                model = SyncJSON.dict(rawModel)
            }
            let code = SyncJSON.str(model["identityCode"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard (4...1024).contains(code.count),
                  !code.hasPrefix("{"), !code.hasPrefix("["),
                  !["null", "undefined", "true", "false", "invalid"].contains(code.lowercased()) else {
                throw NativeSyncError.badResponse(
                    "菜鸟接口未返回有效身份码，请稍后重试或检查当前授权账号")
            }
            // The reference implementation treats expireTime as seconds.
            let ttl = Double(SyncJSON.str(model["expireTime"])) ?? 600
            guard ttl.isFinite, ttl > 0, ttl <= 86400 else {
                throw NativeSyncError.badResponse("菜鸟身份码有效期异常")
            }
            return IdentityResult(
                code: code,
                expiresAt: Date().addingTimeInterval(ttl),
                certified: nil, name: nil, maskedID: nil, mobile: nil)
        }
        let response = try await mtop(
            "mtop.cainiao.pickup.identity.getIdentityMessage", data: [:],
            accountID: ParcelAccounts.activeID(for: "taobao"))
        let content = identityData(response["data"])
        guard let code = identityCodeIn(content) else {
            throw NativeSyncError.badResponse("淘宝接口没有返回有效身份码")
        }
        let seconds = max(60, identityExpiry(content) ?? 300)
        return IdentityResult(code: code,
            expiresAt: Date().addingTimeInterval(seconds),
            certified: nil, name: nil, maskedID: nil, mobile: nil)
    }

    // The manual search and details screen share the same track endpoints.
    // Returning nil means this source had no verified shipment data.
    static func lookupShipment(_ mail: String, source: String? = nil,
                               accountIDs: [String] = []) async -> NativeTrackLookup? {
        let usePdd = (source == "pdd" || source == nil || source == "")
        let useCainiao = (source == "cainiao" || source == "taobao" ||
                          source == nil || source == "")
        if usePdd {
            let known = Set(ParcelAccounts.accounts(for: "pdd").map(\.id))
            let candidates = accountIDs.isEmpty ? [ParcelAccounts.activeID(for: "pdd")] : accountIDs.filter { known.contains($0) }
            for id in candidates.prefix(3) {
                if let detail = try? await pddTrack(mail, accountID: id), !detail.1.isEmpty {
                    return NativeTrackLookup(mailNo: mail, company: detail.0,
                        shipperCode: "", latest: detail.1.first?.text ?? "",
                        nodes: detail.1, provider: "拼多多")
                }
            }
        }
        if useCainiao {
            // First query the account which imported the parcel. A friend's
            // shipment can be visible to that account but not the currently
            // selected default Taobao login.
            let known = Set(ParcelAccounts.accounts(for: "taobao").map(\.id))
            var candidates = accountIDs.filter { known.contains($0) }
            let active = ParcelAccounts.activeID(for: "taobao")
            if accountIDs.isEmpty && !candidates.contains(active) { candidates.append(active) }
            for id in candidates.prefix(3) {
                if let detail = await cainiaoTrack(mail, accountID: id),
                   !detail.nodes.isEmpty || !detail.status.isEmpty {
                    return NativeTrackLookup(mailNo: mail, company: detail.company,
                        shipperCode: "",
                        latest: detail.status.isEmpty ?
                            (detail.nodes.first?.text ?? "") : detail.status,
                        nodes: detail.nodes, provider: "菜鸟")
                }
            }
        }
        return nil
    }

}


