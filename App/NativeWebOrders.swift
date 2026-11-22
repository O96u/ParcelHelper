import Foundation
import SwiftUI
import WebKit

// Native WebKit port of the order-discovery path in utils/net.ts and utils/jd.ts.
// No bypass of platform challenge screens. Reads only in the user's logged-in
// WKWebView and imports packages with verified tracking numbers.

private struct WebOrder: Decodable {
    var id: String
    var title: String
    var status: String
    var sku: String
    var shop: String
}
private struct WebShipment: Decodable {
    var mail: String
    var company: String
    var latest: String
    var pickup: String
    var station: String
    var tracks: [TrackNode]
    var login: Bool?
    var verify: Bool?
}
@MainActor final class NativeWebAutoSync: ObservableObject {
    static let shared = NativeWebAutoSync()
    @Published private(set) var activePlatform: String?
    @Published private(set) var activeAccountID: String?
    @Published private(set) var sequence = 0
    private var pending: [String] = []
    private var isRunning = false
    private var timeoutTask: Task<Void, Never>?
    private var queueDecisions: [String: String] = [:]

    private init() {}

    func lastQueueDecision(_ platform: String, accountID: String) -> String {
        queueDecisions[platform + "|" + accountID] ?? "当前账号尚未加入同步队列"
    }

    private func recordOutcome(platform: String, accountID: String?, success: Bool) {
        guard let accountID else { return }
        let prefix = "native.web.retry." + platform + "." + accountID
        if success {
            UserDefaults.standard.removeObject(forKey: prefix + ".failures")
            UserDefaults.standard.removeObject(forKey: prefix + ".after")
        } else {
            let attempts = min(7, UserDefaults.standard.integer(forKey: prefix + ".failures") + 1)
            UserDefaults.standard.set(attempts, forKey: prefix + ".failures")
            let seconds = min(21_600.0, 300.0 * pow(2.0, Double(attempts - 1)))
            UserDefaults.standard.set(Date().timeIntervalSince1970 +
                seconds * Double.random(in: 0.8...1.2), forKey: prefix + ".after")
        }
    }

    func refreshAvailable() async {
        // Foreground timer checks once a minute, but reading WebKit cookies
        // for every account each minute is unnecessary and power-hungry.
        let now = Date().timeIntervalSince1970
        let key = "native.web.autosync.lastSweep"
        let interval = TimeInterval(RefreshPolicy.minutes) * 60
        guard now - UserDefaults.standard.double(forKey: key) >= interval else { return }
        UserDefaults.standard.set(now, forKey: key)
        for platform in ["jd", "taobao", "pdd"] {
            for profile in await ParcelAccounts.authorizedAccounts(for: platform) {
                _ = await request(platform, accountID: profile.id)
            }
        }
    }

    @discardableResult
    func request(_ platform: String, force: Bool = false, accountID: String? = nil) async -> Bool {
        guard platform == "jd" || platform == "taobao" || platform == "pdd" else { return false }
        let selected = accountID ?? ParcelAccounts.activeID(for: platform)
        let job = platform + "|" + selected

        // Never start hidden PDD or a user-disabled Taobao source.
        if platform == "pdd" && !PddAccountProtection.webAccessAllowed {
            queueDecisions[job] = "拼多多网页访问未开启"
            return false
        }
        if platform == "taobao" &&
            (UserDefaults.standard.object(forKey: "native.platform.enabled.taobao") as? Bool) == false {
            queueDecisions[job] = "淘宝购物订单来源已关闭"
            return false
        }
        let retryAfter = UserDefaults.standard.double(
            forKey: "native.web.retry." + platform + "." + selected + ".after"
        )
        if !force && Date().timeIntervalSince1970 < retryAfter {
            queueDecisions[job] = "自动同步暂缓，等候失败退避窗口结束"
            ParcelRunLog.record(platform, "自动同步暂缓：此前网页读取失败，等待退避时间")
            return false
        }
        guard await ParcelAccounts.hasSession(platform, accountID: selected) else {
            queueDecisions[job] = "当前账号网页登录会话失效，请重新登录"
            ParcelRunLog.record(platform, "未排队：当前账号网页登录会话无效")
            return false
        }
        let key = "native.web.autosync.at." + platform + "." + selected
        let now = Date().timeIntervalSince1970
        if (activePlatform == platform && activeAccountID == selected) ||
            pending.contains(job) {
            queueDecisions[job] = "订单同步任务已在队列中"
            return true
        }
        let manualKey = "native.web.manual.lastAt." + platform + "." + selected
        if force && now - UserDefaults.standard.double(forKey: manualKey) < 30 {
            let remaining = Int(ceil(30 - (now - UserDefaults.standard.double(forKey: manualKey))))
            queueDecisions[job] = "30 秒防重复：约 \(max(1, remaining)) 秒后可重试"
            ParcelRunLog.record(platform, "手动同步防重复：30 秒内已有请求")
            return false
        }
        let interval = TimeInterval(RefreshPolicy.minutes) * 60
        if !force && now - UserDefaults.standard.double(forKey: key) < interval {
            queueDecisions[job] = "未达到前台自动刷新间隔"
            return false
        }
        UserDefaults.standard.set(now, forKey: key)
        if force { UserDefaults.standard.set(now, forKey: manualKey) }
        pending.append(job)
        queueDecisions[job] = "已加入网页同步队列，结果稍后写入包裹"
        ParcelRunLog.record(platform, force ? "手动同步已加入队列" : "前台自动同步已加入队列")
        startNext()
        return true
    }

    private func startNext() {
        guard activePlatform == nil, !pending.isEmpty else { return }
        let job = pending.removeFirst().components(separatedBy: "|")
        guard job.count == 2 else { startNext(); return }
        let platform = job[0], accountID = job[1]
        // A queued job must never revive a profile removed during a previous
        // WebKit task. Skip it without creating another WKWebsiteDataStore.
        guard ParcelAccounts.accounts(for: platform)
            .contains(where: { $0.id == accountID }) else {
            startNext()
            return
        }
        // Consent may have been revoked while this reader was queued.
        if platform == "pdd" && !PddAccountProtection.webAccessAllowed {
            startNext()
            return
        }
        sequence += 1
        isRunning = true
        ParcelRunLog.record(platform, "开始读取官方订单网页")
        activePlatform = platform
        activeAccountID = accountID
        let requestNumber = sequence
        // Cancel the timeout worker as soon as the reader finishes, rather
        // than leaving one sleeping task per completed platform/account.
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: platform == "jd" ? 75_000_000_000 : 35_000_000_000)
            } catch { return }
            guard let self,
                  activePlatform == platform && activeAccountID == accountID &&
                  sequence == requestNumber else { return }
            ParcelRunLog.record(platform, "网页同步超时，任务已结束")
            if platform == "pdd" {
                finishPdd("拼多多购物订单：网页读取超时，请稍后重试", succeeded: false)
            } else {
                finish(platform, packages: [], failure: "网页同步超时，请稍后重试或打开官方订单页检查")
            }
        }
    }

    func finishPdd(_ message: String, succeeded: Bool,
                   expectedAccountID: String? = nil,
                   expectedSequence: Int? = nil) {
        guard activePlatform == "pdd",
              expectedAccountID == nil || activeAccountID == expectedAccountID,
              expectedSequence == nil || sequence == expectedSequence else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        let retained = activeAccountID.map { accountID in
            ParcelAccounts.accounts(for: "pdd").contains(where: { $0.id == accountID })
        } ?? false
        if retained {
            recordOutcome(platform: "pdd", accountID: activeAccountID, success: succeeded)
        }
        if !succeeded, retained, let accountID = activeAccountID {
            Task { await ParcelNotifications.notifySyncFailure(
                platform: "pdd", accountID: accountID) }
        }
        if succeeded && retained {
            let syncedAt = Date().timeIntervalSince1970
            UserDefaults.standard.set(syncedAt,
                                      forKey: "native.sync.success.pdd")
            UserDefaults.standard.set(syncedAt, forKey: "native.home.lastRefresh")
        }
        UserDefaults.standard.set(message, forKey: "native.sync.result.pdd")
        if let accountID = activeAccountID {
            UserDefaults.standard.set(message, forKey: "native.sync.result.pdd." + accountID)
        }
        activePlatform = nil
        activeAccountID = nil
        isRunning = false
        DispatchQueue.main.async { [weak self] in self?.startNext() }
    }

    func finish(_ platform: String, packages: [NativeSyncParcel], failure: String?,
                expectedAccountID: String? = nil,
                expectedSequence: Int? = nil) {
        guard activePlatform == platform,
              expectedAccountID == nil || activeAccountID == expectedAccountID,
              expectedSequence == nil || sequence == expectedSequence else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        let retained = activeAccountID.map { accountID in
            ParcelAccounts.accounts(for: platform).contains(where: { $0.id == accountID })
        } ?? false
        if retained {
            recordOutcome(platform: platform, accountID: activeAccountID, success: failure == nil)
        }
        if failure != nil, retained, let accountID = activeAccountID {
            Task { await ParcelNotifications.notifySyncFailure(
                platform: platform, accountID: accountID) }
        }
        let description: String
        if !retained {
            description = "账号已解除授权，忽略滞后的网页同步结果"
        } else if let failure {
            description = (platform == "jd" ? "京东" : "淘宝") + "自动同步： " + failure
        } else {
            var scoped = packages
            let accountID = activeAccountID ?? ParcelAccounts.activeID(for: platform)
            for index in scoped.indices { scoped[index].accountID = accountID }
            let baselineKey = "native.sync.baseline.web." + platform + "." + accountID
            let syncedAt = Date().timeIntervalSince1970
            UserDefaults.standard.set(syncedAt, forKey: "native.home.lastRefresh")
            let merged = NativeParcelSync.merge(scoped,
                notifyNewArrival: UserDefaults.standard.bool(forKey: baselineKey))
            ParcelRunLog.record(platform, "有效运单 \(scoped.count) 件，新增或更新 \(merged) 件（其余可能已存在、已完成或无变化）")
            if merged == 0 { ParcelStore.shared.persist() }
            UserDefaults.standard.set(true, forKey: baselineKey)
            UserDefaults.standard.set(syncedAt,
                                      forKey: "native.sync.success." + platform)
            UserDefaults.standard.set(syncedAt,
                                      forKey: "native.sync.success." + platform + "." + accountID)
            description = "\(platform == "jd" ? "京东" : "淘宝")：识别 \(packages.count) 件，导入或更新 \(merged) 件。"
        }
        if failure != nil {
            ParcelRunLog.record(platform, "网页同步未完成；详情请查看账号同步结果")
        }
        UserDefaults.standard.set(description, forKey: "native.sync.result." + platform)
        if let accountID = activeAccountID {
            UserDefaults.standard.set(description, forKey: "native.sync.result." + platform + "." + accountID)
        }
        activePlatform = nil
        activeAccountID = nil
        isRunning = false
        // Defer the next WebKit update until the previous reader has disappeared.
        DispatchQueue.main.async { [weak self] in self?.startNext() }
    }
}

struct NativeWebAutoSyncHost: View {
    @ObservedObject private var sync = NativeWebAutoSync.shared

    var body: some View {
        Group {
            if let platform = sync.activePlatform,
               let accountID = sync.activeAccountID {
                Group {
                    // Capture this reader instance's generation, so a late
                    // callback cannot accidentally complete a newer reader.
                    let generation = sync.sequence
                    if platform == "pdd" {
                        PddOrdersAutoSyncReader(
                            accountID: accountID,
                            isStillCurrent: {
                                sync.activePlatform == "pdd" &&
                                sync.activeAccountID == accountID &&
                                sync.sequence == generation &&
                                ParcelAccounts.accounts(for: "pdd")
                                    .contains(where: { $0.id == accountID })
                            }
                        ) { message, succeeded in
                            Task { @MainActor in
                                sync.finishPdd(message, succeeded: succeeded,
                                               expectedAccountID: accountID,
                                               expectedSequence: generation)
                            }
                        }
                    } else {
                        NativeWebOrderReader(platform: platform, accountID: accountID) { _ in
                            // Progress is available in the explicit manual sync screen.
                        } onComplete: { packages, error in
                            Task { @MainActor in
                                sync.finish(platform, packages: packages, failure: error,
                                            expectedAccountID: accountID,
                                            expectedSequence: generation)
                            }
                        }
                    }
                }
                .id("\(platform)-\(sync.sequence)")
                .frame(width: 390, height: 680)
                .opacity(0.002)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

struct NativeWebOrderPage: View {
    let platform: String
    var accountID: String? = nil
    let onFinish: (String) -> Void
    @State private var detail = "正在访问订单列表…"
    @State private var received = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if !received { ProgressView().controlSize(.small) }
                Text(detail).font(.footnote).lineLimit(3)
                Spacer()
            }.padding(12)
            NativeWebOrderReader(platform: platform, accountID: accountID) { progress in
                detail = progress
            } onComplete: { packages, failure in
                Task { @MainActor in
                    guard !received else { return }
                    received = true
                    if let failure {
                        detail = failure
                        ParcelRunLog.record(platform, "手动网页读取失败：原因见页面提示")
                    } else {
                        var scoped = packages
                        let selected = accountID ?? ParcelAccounts.activeID(for: platform)
                        for index in scoped.indices { scoped[index].accountID = selected }
                        let baselineKey = "native.sync.baseline.web." + platform + "." + selected
                        let syncedAt = Date().timeIntervalSince1970
                        UserDefaults.standard.set(syncedAt, forKey: "native.home.lastRefresh")
                        let count = NativeParcelSync.merge(scoped,
                            notifyNewArrival: UserDefaults.standard.bool(forKey: baselineKey))
                        ParcelRunLog.record(platform, "手动读取完成：有效运单 \(scoped.count) 件，新增或更新 \(count) 件")
                        if count == 0 { ParcelStore.shared.persist() }
                        UserDefaults.standard.set(true, forKey: baselineKey)
                        UserDefaults.standard.set(syncedAt,
                                                  forKey: "native.sync.success." + platform)
                        UserDefaults.standard.set(syncedAt,
                                                  forKey: "native.sync.success." + platform + "." + selected)
                        detail = "\(platform == "jd" ? "京东" : "淘宝")：读取 \(packages.count) 件有效物流包裹，导入或更新 \(count) 件。"
                    }
                    UserDefaults.standard.set(detail, forKey: "native.sync.result." + platform)
                    // Successfully extracted orders: finish automatically.
                    // On authentication challenge/errors, remain visible to explain.
                    if failure == nil {
                        try? await Task.sleep(nanoseconds: 550_000_000)
                        onFinish(detail)
                    }
                }
            }
        }
        .navigationTitle(platform == "jd" ? "京东订单同步" : "淘宝订单同步")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { onFinish(detail) }
            }
        }
    }
}

private struct NativeWebOrderReader: UIViewRepresentable {
    let platform: String
    var accountID: String? = nil
    let onProgress: (String) -> Void
    let onComplete: ([NativeSyncParcel], String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(platform: platform, accountID: accountID, onProgress: onProgress, onComplete: onComplete)
    }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = ParcelAccounts.webStore(for: platform, accountID: accountID)
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        let url = platform == "jd" ?
            "https://trade.m.jd.com/order/orderlist_jdm.shtml?sceneval=2" :
            "https://h5.m.taobao.com/mlapp/olist.html"
        view.load(URLRequest(url: URL(string: url)!))
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        enum Stage { case orderList, tracking }
        let platform: String
        let accountID: String?
        let onProgress: (String) -> Void
        let onComplete: ([NativeSyncParcel], String?) -> Void
        var stage = Stage.orderList
        var orders: [WebOrder] = []
        var loaded: [NativeSyncParcel] = []
        var position = 0
        var scanning = false
        var finished = false
        var usedJDFallback = false
        var emptyReadAttempts = 0
        var trackingReadAttempts = 0
        var missingTracking = 0

        private func record(_ stage: String) {
            let category = platform == "jd" ? "京东网页" : "淘宝网页"
            Task { @MainActor in ParcelRunLog.record(category, stage) }
        }

        init(platform: String, accountID: String?,
             onProgress: @escaping (String) -> Void,
             onComplete: @escaping ([NativeSyncParcel], String?) -> Void) {
            self.platform = platform
            self.accountID = accountID
            self.onProgress = onProgress
            self.onComplete = onComplete
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).domain == NSURLErrorDomain &&
                (error as NSError).code == NSURLErrorCancelled { return }
            if stage == .tracking {
                record("物流详情页无法打开：已跳过第 \(position + 1) 笔")
                missingTracking += 1
                position += 1
                next(webView)
            } else {
                record("订单页打开失败（网络或页面访问错误）")
                complete("页面加载失败：\(error.localizedDescription)")
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !finished else { return }
            if stage == .orderList && !scanning {
                scanning = true
                if platform == "jd" && usedJDFallback {
                    webView.evaluateJavaScript(Self.openJDOrders) { _, _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self, weak webView] in
                            guard let self, let view = webView, !self.finished else { return }
                            self.readOrders(view)
                        }
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self, weak webView] in
                        guard let self, let view = webView, !self.finished else { return }
                        self.readOrders(view)
                    }
                }
            } else if stage == .tracking {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self, weak webView] in
                    guard let self, let view = webView, !self.finished else { return }
                    self.readTracking(view)
                }
            }
        }
        private func readOrders(_ webView: WKWebView) {
            guard !finished else { return }
            let script = platform == "jd" ? Self.jdOrdersJS : Self.taobaoOrdersJS
            webView.evaluateJavaScript(script) { [weak self, weak webView] value, error in
                guard let self, let webView, !self.finished else { return }
                guard error == nil, let text = value as? String, let data = text.data(using: .utf8),
                      let result = try? JSONDecoder().decode(OrdersResponse.self, from: data) else {
                    self.record("订单页脚本无法解析：官方页面结构可能已变化")
                    self.complete("订单列表解析失败，页面可能已变更")
                    return
                }
                self.record("订单页检查：候选 \(result.orders.count) 笔，来源 \(result.source ?? "网页")")
                if result.verify {
                    self.record("页面要求安全验证，暂停自动读取")
                    self.complete("平台要求安全验证，请在官方页面完成验证后重新同步")
                    return
                }
                if result.login {
                    self.record("订单页出现登录提示，当前网页会话失效")
                    self.complete("未检测到有效账号登录，请先授权")
                    return
                }
                self.orders = Array(result.orders.filter { order in
                    !order.id.isEmpty &&
                    order.id.range(of: #"^\d{8,}$"#, options: .regularExpression) != nil &&
                    !["退款", "已关闭", "已完成", "交易成功", "已签收",
                      "已收货", "已取件", "确认收货"].contains {
                        order.status.contains($0)
                    }
                }.prefix(self.platform == "jd" ? 15 : 10))
                self.record("筛选后可查询 \(self.orders.count) 笔订单")
                if self.orders.isEmpty {
                    if self.emptyReadAttempts < 2 {
                        self.emptyReadAttempts += 1
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak webView] in
                            guard let self, let view = webView, !self.finished else { return }
                            self.readOrders(view)
                        }
                        return
                    }
                    if self.platform == "jd" && !self.usedJDFallback {
                        self.record("列表无匹配订单，尝试从京东个人首页进入订单")
                        self.usedJDFallback = true
                        self.emptyReadAttempts = 0
                        self.scanning = false
                        if let url = URL(string: "https://my.m.jd.com/index.html?sceneval=2") {
                            webView.load(URLRequest(url: url))
                            return
                        }
                    }
                    self.record("订单列表及备用页面均未识别到符合条件的订单")
                    self.complete("未识别到可查询的订单。页面可能未加载完毕、账号需要安全验证，或平台调整了订单结构；必要时可打开官方订单页核对。")
                } else {
                    self.stage = .tracking
                    self.position = 0
                    self.next(webView)
                }
            }
        }
        private func next(_ webView: WKWebView) {
            guard !finished else { return }
            if position >= orders.count {
                record("物流详情读取结束：成功 \(loaded.count) 件，未取得有效单号 \(missingTracking) 笔")
                if loaded.isEmpty && !orders.isEmpty {
                    complete("已发现 \(orders.count) 笔订单，但物流详情未取得有效运单号。可能是订单未发货、页面未加载、要求安全验证或页面结构已变化；请在「运行日志」查看阶段记录。")
                    return
                }
                finished = true
                onComplete(loaded, nil)
                return
            }
            trackingReadAttempts = 0
            let order = orders[position]
            onProgress("正在查询 \(position + 1)/\(orders.count) 笔订单的物流")
            let url: String
            if platform == "jd" {
                url = "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?from=orderdetail&dealState=7&dealId=\(order.id)&orderType=22&skuid=\(order.sku)&shopid=\(order.shop)&source=m_inner_orderList.track_orderTrack"
            } else {
                url = "https://pages-g.m.taobao.com/wow/z/app/mtb/logisticsV2/h5-detail?x-ssr=true&bizOrderId=\(order.id)&viewLogisticDetail=true&skipEnterAnimation=true&forceThemis=true&disableNav=YES"
            }
            guard let parsed = URL(string: url) else { position += 1; next(webView); return }
            webView.load(URLRequest(url: parsed))
        }
        private func readTracking(_ webView: WKWebView) {
            guard !finished, position < orders.count else { return }
            let script = platform == "jd" ? Self.jdTrackingJS : Self.taobaoTrackingJS
            webView.evaluateJavaScript(script) { [weak self, weak webView] value, scriptError in
                guard let self, let webView, !self.finished, self.position < self.orders.count else { return }
                if scriptError == nil,
                   let json = value as? String, let data = json.data(using: .utf8),
                   let shipment = try? JSONDecoder().decode(WebShipment.self, from: data) {
                    if shipment.verify == true {
                        self.record("物流详情要求安全验证，停止本轮读取")
                        self.complete("物流页面要求官方安全验证，请在京东网页完成验证后重新同步")
                        return
                    }
                    if shipment.login == true {
                        self.record("物流详情跳转到登录页，停止本轮读取")
                        self.complete("京东物流网页会话已失效，请重新登录后同步")
                        return
                    }
                    if shipment.mail.range(of: #"^[A-Za-z0-9-]{8,40}$"#,
                                           options: .regularExpression) == nil {
                        self.retryTracking(webView)
                        return
                    }
                    let order = self.orders[self.position]
                    var item = NativeSyncParcel(source: self.platform)
                    item.accountID = self.accountID ?? ""
                    item.orderID = order.id
                    item.orderStatus = order.status
                    item.mailNo = shipment.mail
                    item.company = shipment.company
                    item.title = order.title
                    item.latest = shipment.latest.isEmpty ? order.status : shipment.latest
                    item.code = shipment.pickup
                    item.station = shipment.station
                    item.tracks = shipment.tracks
                    item.arrived = !shipment.pickup.isEmpty
                    self.loaded.append(item)
                    self.record("第 \(self.position + 1) 笔：已识别有效运单及 \(shipment.tracks.count) 条轨迹")
                    self.position += 1
                    self.next(webView)
                    return
                }
                self.retryTracking(webView)
            }
        }

        private func retryTracking(_ webView: WKWebView) {
            guard !finished else { return }
            if trackingReadAttempts < 2 {
                trackingReadAttempts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { [weak self, weak webView] in
                    guard let self, let view = webView, !self.finished else { return }
                    self.readTracking(view)
                }
                return
            }
            record("第 \(position + 1) 笔：物流页无有效运单号或解析失败（重试后）")
            missingTracking += 1
            position += 1
            next(webView)
        }
        private func complete(_ error: String) {
            guard !finished else { return }
            finished = true
            onComplete(loaded, error)
        }
        struct OrdersResponse: Decodable {
            let login: Bool
            let verify: Bool
            let orders: [WebOrder]
            let source: String?
        }
        private static let openJDOrders = #"""
        (function(){
          var el = document.querySelector('.my_order_entrance.type_orders');
          if (!el) el = [].slice.call(document.querySelectorAll('a,div,span')).find(function(x){
            return /^(待收货|全部订单|进行中)$/.test((x.textContent||'').trim()) && x.children.length<3;
          });
          if(el) { el.click(); return true; } return false;
        })()
        """#
        // JD uses multiple H5 layouts: old data-eparam cards, newer anchor
        // links, and client-side initial state. Read only the current signed-in
        // official page; no private API calls or login/session bypass.
        private static let jdOrdersJS = #"""
        (function(){
          var body=(document.body&&document.body.innerText||'').slice(0,4500);
          var orders=[],seen={},stats={attrs:0,links:0,state:0};
          function cardOf(el){
            if(!el||!el.closest) return document.body;
            return el.closest('[class*="order-card"],[class*="order_item"],[class*="orderItem"],[class*="order_list"],[data-orderid],[data-order-id]')||
                   el.closest('li,article,section')||el.parentElement||el;
          }
          function add(id,el,raw,source){
            id=String(id||'').trim();
            if(!/^\d{8,}$/.test(id)||seen[id])return;
            seen[id]=1;
            var card=cardOf(el),extra=raw||{};
            var sku=(extra.orderSkus&&extra.orderSkus[0])||{};
            var titleNode=card&&card.querySelector&&card.querySelector(
              '[class*="goods_name"],[class*="product_name"],[class*="goodsName"],[class*="desc"],[class*="sku_name"]');
            var statusNode=card&&card.querySelector&&card.querySelector(
              '[class*="order_state"],[class*="orderStatus"],[class*="status"],[class*="state"]');
            var title=titleNode?(titleNode.innerText||titleNode.textContent||'').trim().slice(0,120):'';
            var status=statusNode?(statusNode.innerText||statusNode.textContent||'').trim().slice(0,80):
                       String(extra.orderStatusName||extra.statusName||extra.orderStatus||'').slice(0,80);
            orders.push({id:id,title:title,status:status,
              sku:String(sku.skuid||sku.skuId||extra.skuid||extra.skuId||''),
              shop:String(extra.shopId||extra.shopid||sku.shopid||'')});
            stats[source]++;
          }
          document.querySelectorAll('[data-eparam]').forEach(function(el){
            var raw={};try{raw=JSON.parse((el.getAttribute('data-eparam')||'').replace(/&quot;/g,'"'))}catch(e){}
            add(raw.orderid||raw.orderId||raw.dealId,el,raw,'attrs');
          });
          document.querySelectorAll('[data-orderid],[data-order-id],[data-dealid]').forEach(function(el){
            add(el.getAttribute('data-orderid')||el.getAttribute('data-order-id')||
                el.getAttribute('data-dealid'),el,{},'attrs');
          });
          // Several current JD mobile layouts expose IDs only in order-detail links.
          document.querySelectorAll('a[href], [data-href]').forEach(function(el){
            var href=el.getAttribute('href')||el.getAttribute('data-href')||'';
            if(!/(?:orderid|dealid|order_id)[=%3D:]/i.test(href))return;
            var match=href.match(/(?:orderid|dealid|order_id)(?:=|%3D|:)(\d{8,})/i);
            if(match)add(match[1],el,{},'links');
          });
          // Limited, local search of already-rendered page state; never sends
          // account data to native code. Identifiers remain inside this WebView.
          var visited=new WeakSet(),nodes=0;
          function walk(v,depth){
            if(!v||typeof v!=='object'||depth>12||nodes++>7000||visited.has(v))return;
            visited.add(v);
            if(!Array.isArray(v)){
              var id=v.orderId||v.orderid||v.dealId;
              if(id)add(id,null,v,'state');
            }
            Object.keys(v).slice(0,65).forEach(function(key){
              try{walk(v[key],depth+1)}catch(e){}
            });
          }
          [window.__INITIAL_STATE__,window.__PRELOADED_STATE__,
           window.__NEXT_DATA__,window.pageData].forEach(function(v){
              try{walk(v,0)}catch(e){}
           });
          return JSON.stringify({
            login:/请登录|登录后查看|账号登录/.test(body)&&!orders.length,
            verify:/滑块验证|人机验证|安全验证|异常登录/.test(body),
            source:'属性'+stats.attrs+' 链接'+stats.links+' 页面状态'+stats.state,
            orders:orders.slice(0,45)
          });
        })()
        """#
        private static let taobaoOrdersJS = #"""
        (function(){
          var raw=window.currentUltronData||window.rawData||null, seen={},o=[];
          function add(id,title,status){
            id=String(id||'');
            if(!/^\d{10,}$/.test(id)||seen[id])return;
            seen[id]=1;o.push({id:id,title:String(title||'').slice(0,120),status:String(status||''),sku:'',shop:''});
          }
          var visited=new WeakSet(),nodes=0;
          function walk(v,d){
            if(!v||typeof v!=='object'||d>16||nodes++>20000||visited.has(v))return;
            visited.add(v);
            var id=v.bizOrderId||v.orderId;
            if(id) add(id,v.itemTitle||v.title||'',v.statusDesc||v.status||'');
            Object.keys(v).slice(0,100).forEach(function(k){walk(v[k],d+1)});
          }
          try{walk(raw,0)}catch(e){}
          var html=document.documentElement&&document.documentElement.outerHTML||'';
          (html.match(/bizOrderId[=%:"\\]+[0-9]{10,}/g)||[]).forEach(function(v){
            var m=v.match(/\d{10,}/);if(m)add(m[0],'','');
          });
          var s=(document.body&&document.body.innerText||'').slice(0,1200);
          return JSON.stringify({login:/请登录|登录后查看/.test(s)&&!o.length,
            verify:/滑块验证|人机验证|安全验证/.test(s),orders:o.slice(0,30)});
        })()
        """#
        private static let jdTrackingJS = #"""
        (function(){
          var txt=(document.body&&document.body.innerText||'').split('可能您还想要')[0].slice(0,70000);
          var html=(document.documentElement&&document.documentElement.outerHTML||'').slice(0,450000);
          function get(text,regex){var m=text.match(regex);return m?m[1]:''}
          // JD-operated and third-party shipments use different labels.
          var mail=get(txt,/(?:运单号|快递单号|物流单号|京东快递单号|运单编号|物流编号|快递编号)\s*[:：]?\s*([A-Za-z0-9-]{8,40})/i);
          if(!mail)mail=get(html,/(?:waybillCode|waybillNo|mailNo|expressNo|trackingNumber|logisticsNo|waybillNumber)["\\]?\s*[:=]\s*["\\]?([A-Za-z0-9-]{8,40})/i);
          var company=get(txt,/(?:国内承运人|承运人|配送方|快递公司|物流公司)\s*[:：]?\s*([^\s]{2,15})/);
          var code=get(txt,/(?:取件码|提货码|取货码|自提码)\s*[:：]?\s*([A-Za-z0-9-]{3,12})/);
          var tracks=[];
          // Some tracking pages omit seconds in dates, and some use '/'.
          var re=/(\d{4}[-/]\d{1,2}[-/]\d{1,2}\s+\d{2}:\d{2}(?::\d{2})?)\s*([\s\S]*?)(?=\d{4}[-/]\d{1,2}[-/]\d{1,2}\s+\d{2}:\d{2}|$)/g,m;
          while((m=re.exec(txt))&&tracks.length<40){
            var note=m[2].replace(/\s+/g,' ').trim();
            if(note)tracks.push({time:m[1],text:note.slice(0,500)});
          }
          return JSON.stringify({mail:mail,company:company,
            latest:tracks[0]?tracks[0].text:'',pickup:code,station:'',tracks:tracks,login:/请登录|登录后查看/.test(txt)&&!mail,verify:/滑块验证|安全验证|人机验证/.test(txt)});
        })()
        """#
        private static let taobaoTrackingJS = #"""
        (function(){
          var html=document.documentElement&&document.documentElement.outerHTML||'';
          function g(re){var m=html.match(re);return m?m[1]:''}
          var mail=g(/"mailNo":"([A-Za-z0-9-]{8,})"/);
          var company=g(/"logisticCompany":\{[^}]*?"name":"([^"]+)"/);
          var station=g(/"LASTONE_TRACE_CODING":\{[^}]*?"address":"([^"]+)"/);
          var code=g(/"(?:pickupCode|takeCode|pickup_code|take_code)":"([A-Za-z0-9-]{3,20})"/);
          var tracks=[],at=html.indexOf('"multiStage":[');
          if(at>=0){
            var start=at+'"multiStage":'.length,dep=0,q=false,esc=false,end=-1;
            for(var i=start;i<html.length;i++){
              var c=html[i];
              if(q){if(esc){esc=false;continue}if(c==='\\'){esc=true;continue}if(c==='"')q=false;continue}
              if(c==='"'){q=true;continue}if(c==='['||c==='{')dep++;else if(c===']'||c==='}'){dep--;if(dep===0){end=i+1;break}}
            }
            if(end>start){try{
              JSON.parse(html.slice(start,end)).forEach(function(s){
                var v=s.labelDesc||{},parts=v.richContent||[];
                var joined=parts.map(function(x){return x.text||''}).join('');
                var text=joined.length>(v.text||'').length?joined:v.text||'';
                if(text&&!/号码保护|无需物流/.test(text))tracks.push({time:String(s.subtitle||''),text:String(text).slice(0,500)});
              });
            }catch(e){}}
          }
          return JSON.stringify({mail:mail,company:company,latest:tracks[0]?tracks[0].text:g(/"statusDesc":"([^"]+)"/),pickup:code,station:station,tracks:tracks.slice(0,40)});
        })()
        """#
    }
}
