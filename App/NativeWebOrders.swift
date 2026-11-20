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
}
@MainActor final class NativeWebAutoSync: ObservableObject {
    static let shared = NativeWebAutoSync()
    @Published private(set) var activePlatform: String?
    @Published private(set) var activeAccountID: String?
    @Published private(set) var sequence = 0
    private var pending: [String] = []
    private var isRunning = false

    private init() {}

    func refreshAvailable() async {
        for platform in ["jd", "taobao", "pdd"] {
            for profile in await ParcelAccounts.authorizedAccounts(for: platform) {
                _ = await request(platform, accountID: profile.id)
            }
        }
    }

    @discardableResult
    func request(_ platform: String, force: Bool = false, accountID: String? = nil) async -> Bool {
        guard platform == "jd" || platform == "taobao" || platform == "pdd" else { return false }
        // Never open a hidden Pinduoduo H5 order page without explicit opt-in.
        guard platform != "pdd" || PddAccountProtection.webAccessAllowed else { return false }
        if platform == "taobao",
           (UserDefaults.standard.object(forKey: "native.platform.enabled.taobao") as? Bool) == false {
            return false
        }
        let selected = accountID ?? ParcelAccounts.activeID(for: platform)
        guard await ParcelAccounts.hasSession(platform, accountID: selected) else { return false }
        let key = "native.web.autosync.at." + platform + "." + selected
        let now = Date().timeIntervalSince1970
        // Use the same foreground auto-refresh interval as the native
        // platform synchronizer; manual force-sync remains available.
        let configured = UserDefaults.standard.object(forKey: "native.refresh.app") as? Int ?? 15
        let interval = TimeInterval(max(5, min(120, configured))) * 60
        if !force && now - UserDefaults.standard.double(forKey: key) < interval {
            return false
        }
        let job = platform + "|" + selected
        if (activePlatform == platform && activeAccountID == selected) ||
            pending.contains(job) { return true }
        UserDefaults.standard.set(now, forKey: key)
        pending.append(job)
        startNext()
        return true
    }

    private func startNext() {
        guard activePlatform == nil, !pending.isEmpty else { return }
        let job = pending.removeFirst().components(separatedBy: "|")
        guard job.count == 2 else { startNext(); return }
        let platform = job[0], accountID = job[1]
        // Consent may have been revoked while this reader was queued.
        if platform == "pdd" && !PddAccountProtection.webAccessAllowed {
            startNext()
            return
        }
        sequence += 1
        isRunning = true
        activePlatform = platform
        activeAccountID = accountID
        let requestNumber = sequence
        // Fail safely if the site never finishes navigation. A new run may retry.
        Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard activePlatform == platform && activeAccountID == accountID &&
                  sequence == requestNumber else { return }
            if platform == "pdd" {
                finishPdd("拼多多购物订单：网页读取超时，请稍后重试", succeeded: false)
            } else {
                finish(platform, packages: [], failure: "网页同步超时，请稍后重试或打开官方订单页检查")
            }
        }
    }

    func finishPdd(_ message: String, succeeded: Bool) {
        guard activePlatform == "pdd" else { return }
        if succeeded {
            UserDefaults.standard.set(Date().timeIntervalSince1970,
                                      forKey: "native.sync.success.pdd")
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

    func finish(_ platform: String, packages: [NativeSyncParcel], failure: String?) {
        guard activePlatform == platform else { return }
        let description: String
        if let failure {
            description = (platform == "jd" ? "京东" : "淘宝") + "自动同步： " + failure
        } else {
            var scoped = packages
            let accountID = activeAccountID ?? ParcelAccounts.activeID(for: platform)
            for index in scoped.indices { scoped[index].accountID = accountID }
            let merged = NativeParcelSync.merge(scoped)
            UserDefaults.standard.set(Date().timeIntervalSince1970,
                                      forKey: "native.sync.success." + platform)
            description = "\(platform == "jd" ? "京东" : "淘宝")：识别 \(packages.count) 件，导入或更新 \(merged) 件。"
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
            if let platform = sync.activePlatform {
                Group {
                    if platform == "pdd" {
                        PddOrdersAutoSyncReader(accountID: sync.activeAccountID) { message, succeeded in
                            Task { @MainActor in
                                sync.finishPdd(message, succeeded: succeeded)
                            }
                        }
                    } else {
                        NativeWebOrderReader(platform: platform, accountID: sync.activeAccountID) { _ in
                            // Progress is available in the explicit manual sync screen.
                        } onComplete: { packages, error in
                            Task { @MainActor in
                                sync.finish(platform, packages: packages, failure: error)
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
                    } else {
                        var scoped = packages
                        let selected = accountID ?? ParcelAccounts.activeID(for: platform)
                        for index in scoped.indices { scoped[index].accountID = selected }
                        let count = NativeParcelSync.merge(scoped)
                        UserDefaults.standard.set(Date().timeIntervalSince1970,
                                                  forKey: "native.sync.success." + platform)
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

        init(platform: String, accountID: String?,
             onProgress: @escaping (String) -> Void,
             onComplete: @escaping ([NativeSyncParcel], String?) -> Void) {
            self.platform = platform
            self.accountID = accountID
            self.onProgress = onProgress
            self.onComplete = onComplete
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if stage == .tracking { position += 1; next(webView) }
            else { complete("页面加载失败：\(error.localizedDescription)") }
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
                    self.complete("订单列表解析失败，页面可能已变更")
                    return
                }
                if result.verify {
                    self.complete("平台要求安全验证，请在官方页面完成验证后重新同步")
                    return
                }
                if result.login {
                    self.complete("未检测到有效账号登录，请先授权")
                    return
                }
                self.orders = Array(result.orders.filter {
                    !$0.id.isEmpty &&
                    $0.id.range(of: #"^\d{8,}$"#, options: .regularExpression) != nil &&
                    !$0.status.contains("退款") && !$0.status.contains("已关闭") &&
                    !$0.status.contains("已完成")
                }.prefix(10))
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
                        self.usedJDFallback = true
                        self.emptyReadAttempts = 0
                        self.scanning = false
                        if let url = URL(string: "https://my.m.jd.com/index.html?sceneval=2") {
                            webView.load(URLRequest(url: url))
                            return
                        }
                    }
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
                finished = true
                onComplete(loaded, nil)
                return
            }
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
            webView.evaluateJavaScript(script) { [weak self, weak webView] value, _ in
                guard let self, let webView, !self.finished, self.position < self.orders.count else { return }
                if let json = value as? String, let data = json.data(using: .utf8),
                   let shipment = try? JSONDecoder().decode(WebShipment.self, from: data),
                   shipment.mail.range(of: #"^[A-Za-z0-9-]{8,40}$"#, options: .regularExpression) != nil {
                    let order = self.orders[self.position]
                    var item = NativeSyncParcel(source: self.platform)
                    item.accountID = self.accountID ?? ""
                    item.orderID = order.id
                    item.mailNo = shipment.mail
                    item.company = shipment.company
                    item.title = order.title
                    item.latest = shipment.latest.isEmpty ? order.status : shipment.latest
                    item.code = shipment.pickup
                    item.station = shipment.station
                    item.tracks = shipment.tracks
                    item.arrived = !shipment.pickup.isEmpty
                    self.loaded.append(item)
                }
                self.position += 1
                self.next(webView)
            }
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
        private static let jdOrdersJS = #"""
        (function(){
          var body=(document.body&&document.body.innerText||'').slice(0,3000);
          var orders=[],seen={};
          function extract(card,state,details){
            var raw=details||{},id=String(raw.orderid||raw.orderId||raw.dealId||'');
            if(!/^\d{8,}$/.test(id)||seen[id])return;
            seen[id]=1;
            var sku=(raw.orderSkus&&raw.orderSkus[0])||{};
            var titleNode=card.querySelector('[class*="desc"],[class*="goods_name"],[class*="product_name"]');
            var title=titleNode?(titleNode.innerText||titleNode.textContent||'').trim().slice(0,120):'';
            var statusNode=card.querySelector('[class*="order_state"],[class*="status"]');
            var status=(statusNode&&(statusNode.innerText||statusNode.textContent)||state||'').trim().slice(0,80);
            orders.push({id:id,title:title,status:status,
              sku:String(sku.skuid||raw.skuid||''),shop:String(raw.shopId||sku.shopid||'')});
          }
          document.querySelectorAll('[data-eparam]').forEach(function(el){
            var json={};try{json=JSON.parse((el.getAttribute('data-eparam')||'').replace(/&quot;/g,'"'))}catch(e){}
            var node=el;
            for(var i=0;i<5&&node.parentElement;i++){
              if(node.querySelector&&node.querySelector('[class*="order_state"]'))break;
              node=node.parentElement;
            }
            extract(node,'',json);
          });
          document.querySelectorAll('[data-orderid],[data-order-id],[data-dealid]').forEach(function(el){
            var id=el.getAttribute('data-orderid')||el.getAttribute('data-order-id')||el.getAttribute('data-dealid');
            extract(el.closest('[class*="order"]')||el.parentElement||el,'',{orderid:id});
          });
          return JSON.stringify({
            login:/请登录|登录后查看|账号登录/.test(body)&&!orders.length,
            verify:/滑块验证|人机验证|安全验证|异常登录/.test(body),
            orders:orders.slice(0,30)
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
          var txt=(document.body&&document.body.innerText||'').split('可能您还想要')[0];
          function g(re){var m=txt.match(re);return m?m[1]:''}
          var mail=g(/(?:运单号|快递单号|物流单号)\s*[:：]?\s*([A-Za-z0-9-]{8,})/);
          var company=g(/(?:国内承运人|承运人|配送方)\s*[:：]?\s*([^\s]{2,12})/);
          var code=g(/(?:取件码|提货码|取货码|自提码)\s*[:：]?\s*([A-Za-z0-9-]{3,12})/);
          var tracks=[],re=/(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\s*([\s\S]*?)(?=\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}|$)/g,m;
          while((m=re.exec(txt))&&tracks.length<40){var t=m[2].replace(/\s+/g,' ').trim();if(t)tracks.push({time:m[1],text:t.slice(0,500)})}
          return JSON.stringify({mail:mail,company:company,latest:tracks[0]?tracks[0].text:'',pickup:code,station:'',tracks:tracks});
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
