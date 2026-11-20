import SwiftUI
import WebKit

// Native adaptation of utils/pdd.ts:
// pddDiscoverOrders -> pddFetchPackage(goods_express.html) -> merge.
// Only physical shipments with real tracking numbers or pickup codes are saved.

fileprivate struct PddDetectedOrder: Codable {
    var orderSn: String
    var trackingNumber: String
    var title: String
    var status: String
    var company: String? = nil
    var pickupCode: String? = nil
    var station: String? = nil
    var latest: String? = nil
    var tracks: [TrackNode]? = nil
}

private enum PddSyncResult {
    case success([PddDetectedOrder], Int)
    case failure(String)
}

struct PddOrderSyncPage: View {
    var accountID: String? = nil
    @State private var message = "正在读取拼多多订单…"
    @State private var busy = true
    let onFinish: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                Text(message).font(.footnote).lineLimit(3)
                Spacer()
            }.padding(12)
            PddOrdersWebView(accountID: accountID) { result in
                busy = false
                switch result {
                case .success(let orders, let discovered):
                    let changed = Self.save(orders, accountID: accountID)
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "native.sync.success.pdd")
                    message = "发现 \(discovered) 笔订单，核验 \(orders.count) 笔；保存 \(changed) 件有效物流包裹。"
                case .failure(let reason):
                    message = reason
                }
            } onProgress: { text in
                message = text
            }
        }
        .navigationTitle("拼多多同步")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { onFinish(message) }
            }
        }
    }

    @MainActor fileprivate static func save(_ orders: [PddDetectedOrder],
                                            accountID: String? = nil) -> Int {
        let incoming = orders.compactMap { order -> NativeSyncParcel? in
            let mail = order.trackingNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = order.pickupCode ?? ""
            guard mail.range(of: #"^[A-Za-z0-9-]{8,40}$"#, options: .regularExpression) != nil ||
                    (!code.isEmpty && !(order.station ?? "").isEmpty) else { return nil }
            var p = NativeSyncParcel(source: "pdd")
            p.accountID = accountID ?? ParcelAccounts.activeID(for: "pdd")
            p.orderID = order.orderSn
            p.mailNo = mail
            p.title = order.title
            p.company = order.company ?? ""
            p.station = order.station ?? ""
            p.code = code
            p.latest = order.latest ?? order.status
            p.tracks = order.tracks ?? []
            p.arrived = !code.isEmpty
            return p
        }
        return NativeParcelSync.merge(incoming)
    }
}

// The same official order reader powers both the visible manual action and
// the foreground automatic sync. There are no separate parsing paths.
struct PddOrdersAutoSyncReader: View {
    var accountID: String? = nil
    let onComplete: (String, Bool) -> Void

    var body: some View {
        PddOrdersWebView(accountID: accountID) { result in
            switch result {
            case .success(let orders, let discovered):
                let changed = PddOrderSyncPage.save(orders, accountID: accountID)
                let message = "拼多多购物订单：发现 \(discovered) 笔，核验 \(orders.count) 笔，新增或更新 \(changed) 件。"
                onComplete(message, true)
            case .failure(let reason):
                onComplete("拼多多购物订单：" + reason, false)
            }
        } onProgress: { _ in }
    }
}

private struct PddOrdersWebView: UIViewRepresentable {
    var accountID: String? = nil
    let onResult: (PddSyncResult) -> Void
    let onProgress: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onResult: onResult, onProgress: onProgress)
    }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = ParcelAccounts.webStore(for: "pdd", accountID: accountID)
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: URL(string: "https://mobile.yangkeduo.com/orders.html")!))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        // Never open PDD's custom-app schemes during an order refresh.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = action.request.url?.scheme?.lowercased()
            decisionHandler(scheme == "https" || scheme == "http" || scheme == "about" ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard action.targetFrame == nil,
                  let scheme = action.request.url?.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else { return nil }
            webView.load(action.request)
            return nil
        }
        private let onResult: (PddSyncResult) -> Void
        private let onProgress: (String) -> Void
        private enum Stage { case list, detail }
        private var stage = Stage.list
        private var orders: [PddDetectedOrder] = []
        private var enriched: [PddDetectedOrder] = []
        private var cursor = 0
        private var discovered = 0
        private var emptyAttempts = 0
        private var requestID = 0
        private var finished = false

        init(onResult: @escaping (PddSyncResult) -> Void,
             onProgress: @escaping (String) -> Void) {
            self.onResult = onResult
            self.onProgress = onProgress
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if stage == .detail {
                cursor += 1
                next(webView)
            } else {
                conclude(.failure("订单页加载失败：\(error.localizedDescription)"))
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !finished else { return }
            requestID += 1
            let version = requestID
            let delay = stage == .list ? 2.8 : 1.6
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                guard let self, let webView, version == self.requestID, !self.finished else { return }
                if self.stage == .list { self.readList(webView) }
                else { self.readDetails(webView) }
            }
        }

        private func readList(_ view: WKWebView) {
            view.evaluateJavaScript(Self.orderListJS) { [weak self, weak view] value, error in
                guard let self, let view, !self.finished else { return }
                guard error == nil, let json = value as? String,
                      let data = json.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(ListOutput.self, from: data) else {
                    self.conclude(.failure("拼多多订单页结构暂不可识别"))
                    return
                }
                if decoded.blocked {
                    self.conclude(.failure("拼多多需要安全验证，请先在官方 App 完成验证"))
                    return
                }
                if decoded.login {
                    self.conclude(.failure("拼多多网页登录可能失效，请重新授权"))
                    return
                }
                let filtered = decoded.orders.filter {
                    !$0.orderSn.isEmpty &&
                    !$0.status.contains("已关闭") &&
                    !$0.status.contains("退款") &&
                    !$0.status.contains("已完成")
                }
                self.discovered = filtered.count
                if filtered.isEmpty {
                    // The H5 order list often renders after didFinish.
                    if self.emptyAttempts < 2 {
                        self.emptyAttempts += 1
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak view] in
                            guard let self, let view, !self.finished else { return }
                            self.readList(view)
                        }
                        return
                    }
                    self.conclude(.success([], 0))
                    return
                }
                // Original source limits each pass to a batch to reduce traffic
                // and avoid permanently favoring the first few orders.
                let first = UserDefaults.standard.integer(forKey: "native.pdd.orderCursor") % filtered.count
                let shifted = Array(filtered[first...]) + Array(filtered[..<first])
                self.orders = Array(shifted.prefix(10))
                UserDefaults.standard.set((first + self.orders.count) % filtered.count,
                                          forKey: "native.pdd.orderCursor")
                self.stage = .detail
                self.cursor = 0
                self.next(view)
            }
        }

        private func next(_ view: WKWebView) {
            guard !finished else { return }
            if cursor >= orders.count {
                conclude(.success(enriched, discovered))
                return
            }
            let order = orders[cursor]
            onProgress("拼多多：正在查询 \(cursor + 1)/\(orders.count) 笔订单的物流详情")
            let sn = order.orderSn
            guard sn.range(of: #"^\d{6,}-?\d{6,}$"#, options: .regularExpression) != nil else {
                cursor += 1; next(view); return
            }
            var parts = URLComponents(string: "https://mobile.yangkeduo.com/goods_express.html")!
            parts.queryItems = [.init(name: "order_sn", value: sn)]
            if !order.trackingNumber.isEmpty {
                parts.queryItems?.append(.init(name: "tracking_number", value: order.trackingNumber))
            }
            guard let url = parts.url else { cursor += 1; next(view); return }
            view.load(URLRequest(url: url))
        }

        private func readDetails(_ view: WKWebView) {
            view.evaluateJavaScript(Self.packageDetailsJS) { [weak self, weak view] value, _ in
                guard let self, let view, !self.finished, self.cursor < self.orders.count else { return }
                var p = self.orders[self.cursor]
                if let json = value as? String, let data = json.data(using: .utf8),
                   let detail = try? JSONDecoder().decode(DetailOutput.self, from: data) {
                    if detail.blocked {
                        self.conclude(.failure("拼多多物流详情需要官方安全验证，请先在拼多多 App 完成验证"))
                        return
                    }
                    if !detail.mailNo.isEmpty { p.trackingNumber = detail.mailNo }
                    p.company = detail.company
                    p.pickupCode = detail.pickupCode
                    p.station = detail.station
                    p.latest = detail.latest
                    p.tracks = detail.tracks
                }
                self.enriched.append(p)
                self.cursor += 1
                self.next(view)
            }
        }
        private func conclude(_ result: PddSyncResult) {
            guard !finished else { return }
            finished = true
            onResult(result)
        }
        private struct ListOutput: Decodable {
            let blocked: Bool
            let login: Bool
            let orders: [PddDetectedOrder]
        }
        private struct DetailOutput: Decodable {
            let blocked: Bool
            let mailNo: String
            let company: String
            let pickupCode: String
            let station: String
            let latest: String
            let tracks: [TrackNode]
        }

        private static let orderListJS = #"""
        (function(){
          var body=(document.body&&document.body.innerText||'').slice(0,1300);
          var login=/登录后查看|请登录|手机登录/.test(body)&&!/待收货|全部订单/.test(body);
          var blocked=/安全验证|访问过于频繁|滑块验证|人机验证/.test(body);
          var found={};
          function add(sn,track,title,status){
            sn=String(sn||'');if(!/^\d{6,}-?\d{6,}$/.test(sn))return;
            var v=found[sn]||{orderSn:sn,trackingNumber:'',title:'',status:''};
            if(track&&!v.trackingNumber)v.trackingNumber=String(track);
            if(title&&!v.title)v.title=String(title).slice(0,120);
            if(status&&!v.status)v.status=String(status).slice(0,100);
            found[sn]=v;
          }
          var raw=window.rawData||window.__INITIAL_STATE__||null;
          var visited=new WeakSet(),nodes=0;
          function scan(v,d){
            if(!v||typeof v!=='object'||d>14||nodes++>20000||visited.has(v))return;
            visited.add(v);
            if(!Array.isArray(v)){
              var sn=v.order_sn||v.orderSn||v.orderSN;
              if(sn)add(sn,v.tracking_number||v.trackingNumber||v.mail_no||'',
                           v.goods_name||v.goodsName||v.item_title||'',v.status_desc||v.statusDesc||'');
            }
            Object.keys(v).slice(0,90).forEach(function(k){scan(v[k],d+1)});
          }
          try{scan(raw,0)}catch(e){}
          document.querySelectorAll('a[href*="order_sn="]').forEach(function(el){
            try{
              var u=new URL(el.href,location.href);
              add(u.searchParams.get('order_sn'),u.searchParams.get('tracking_number'),
                  u.searchParams.get('goods_name')||el.innerText,'');
            }catch(e){}
          });
          return JSON.stringify({login:login,blocked:blocked,
            orders:Object.keys(found).slice(0,60).map(function(k){return found[k]})});
        })()
        """#

        private static let packageDetailsJS = #"""
        (function(){
          var raw=window.rawData||window.__INITIAL_STATE__||{};
          var store=raw.store||{}, trace=store.traceData||{}, sh=trace.shipping||{};
          var cabinet=store.cabinetData||{},body=document.body&&document.body.innerText||'';
          function string(x){return x==null?'':String(x)}
          var mail=string(sh.trackingNumber||sh.tracking_number||'');
          if(!mail){var m=body.match(/(?:运单号|快递单号)[:：\s]*([A-Za-z0-9-]{8,})/);if(m)mail=m[1]}
          var rows=(sh.traces||[]).map(function(t){
            return {time:string(t.displayTime||t.time),
                    text:string(t.info||t.desc)};
          }).filter(function(t){return t.text&&!/无需物流/.test(t.text)}).slice(0,60);
          var forecast=sh.timeForecast||{};
          var latest=string(forecast.traceStatusDesc||forecast.orderDetailStatusDesc||(rows[0]&&rows[0].text)||'');
          return JSON.stringify({
            blocked:/安全验证|滑块验证|人机验证/.test(body.slice(0,1000)),
            mailNo:mail,
            company:string(sh.shippingName||''),
            pickupCode:string(cabinet.code||''),
            station:string(cabinet.companyName||cabinet.address||''),
            latest:latest,
            tracks:rows
          });
        })()
        """#
    }
}
