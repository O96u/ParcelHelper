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
    var link: String? = nil
    var summary: String? = nil
    var code: String? = nil
    var station: String? = nil
    var verified: Bool? = nil
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
    // A WebKit task may time out after some orders were already parsed.
    // Keep verified parcels for the *current generation*, never discard them.
    private var partialPackages: [NativeSyncParcel] = []

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

    func checkpoint(_ parcel: NativeSyncParcel, platform: String,
                    accountID: String, generation: Int) {
        guard activePlatform == platform, activeAccountID == accountID,
              sequence == generation,
              ParcelAccounts.accounts(for: platform).contains(where: { $0.id == accountID })
        else { return }
        if let index = partialPackages.firstIndex(where: {
            $0.orderID == parcel.orderID &&
            ($0.mailNo.isEmpty ||
             $0.mailNo.caseInsensitiveCompare(parcel.mailNo) == .orderedSame)
        }) {
            if !parcel.mailNo.isEmpty || partialPackages[index].mailNo.isEmpty {
                partialPackages[index] = parcel
            }
            return
        }
        partialPackages.append(parcel)
        ParcelRunLog.record(platform, "已暂存第 \(partialPackages.count) 件有效订单物流；整轮超时仍会导入")
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
        partialPackages = []
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
                try await Task.sleep(nanoseconds: platform == "pdd" ? 60_000_000_000 : 150_000_000_000)
            } catch { return }
            guard let self,
                  activePlatform == platform && activeAccountID == accountID &&
                  sequence == requestNumber else { return }
            ParcelRunLog.record(platform, "网页同步超时，任务已结束")
            if platform == "pdd" {
                finishPdd("拼多多购物订单：网页读取超时，请稍后重试", succeeded: false)
            } else {
                finish(platform, packages: partialPackages, failure: "网页同步超时，请稍后重试或打开官方订单页检查")
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
        partialPackages = []
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
        // A partial capture is useful work, not a completely failed account.
        // Keep normal foreground retries available on the next refresh cycle.
        let recovered = partialPackages.isEmpty ? packages : partialPackages
        if retained {
            recordOutcome(platform: platform, accountID: activeAccountID,
                          success: failure == nil || !recovered.isEmpty)
        }
        if failure != nil, recovered.isEmpty, retained, let accountID = activeAccountID {
            Task { await ParcelNotifications.notifySyncFailure(
                platform: platform, accountID: accountID) }
        }
        let description: String
        // A failed/expired WebKit read may still have captured valid shipments.
        // Persist these without claiming the *entire account* was synced.
        if !retained {
            description = "账号已解除授权，忽略滞后的网页同步结果"
        } else {
            var scoped = recovered
            let accountID = activeAccountID ?? ParcelAccounts.activeID(for: platform)
            for index in scoped.indices { scoped[index].accountID = accountID }
            let baselineKey = "native.sync.baseline.web." + platform + "." + accountID
            let syncedAt = Date().timeIntervalSince1970
            let merged = scoped.isEmpty ? 0 :
                NativeParcelSync.merge(scoped,
                    notifyNewArrival: failure == nil &&
                        UserDefaults.standard.bool(forKey: baselineKey))
            ParcelRunLog.record(platform,
                (failure == nil ? "同步成功" : "同步未完整结束") +
                "：读取有效物流 \(scoped.count) 件，新增或更新 \(merged) 件" +
                (failure == nil ? "；已完成或重复包裹不会作为新件导入" : "；已保留有效结果"))
            if failure == nil {
                if merged == 0 { ParcelStore.shared.persist() }
                UserDefaults.standard.set(syncedAt, forKey: "native.home.lastRefresh")
                UserDefaults.standard.set(true, forKey: baselineKey)
                UserDefaults.standard.set(syncedAt, forKey: "native.sync.success." + platform)
                UserDefaults.standard.set(syncedAt,
                                          forKey: "native.sync.success." + platform + "." + accountID)
                description = "\(platform == "jd" ? "京东" : "淘宝")：识别 \(scoped.count) 件，导入或更新 \(merged) 件。"
            } else if let failure {
                description = "\(platform == "jd" ? "京东" : "淘宝")：本轮已保留 \(scoped.count) 件有效物流（合并 \(merged) 件），但仍有订单未完成：" + failure
                ParcelRunLog.record(platform, "本轮网页读取未完整结束；已保存的包裹不会回滚")
            } else {
                description = "同步任务未完成"
            }
        }
        partialPackages = []
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
                        NativeWebOrderReader(
                            platform: platform, accountID: accountID,
                            onProgress: { _ in },
                            onComplete: { packages, error in
                                Task { @MainActor in
                                    sync.finish(platform, packages: packages, failure: error,
                                                expectedAccountID: accountID,
                                                expectedSequence: generation)
                                }
                            },
                            onParcel: { parcel in
                                Task { @MainActor in
                                    sync.checkpoint(parcel, platform: platform,
                                                    accountID: accountID, generation: generation)
                                }
                            }
                        )
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
                    var scoped = packages
                    let selected = accountID ?? ParcelAccounts.activeID(for: platform)
                    for index in scoped.indices { scoped[index].accountID = selected }
                    let baselineKey = "native.sync.baseline.web." + platform + "." + selected
                    let syncedAt = Date().timeIntervalSince1970
                    // Even when some later order needs verification, save
                    // already verified shipments rather than discarding them.
                    let count = scoped.isEmpty ? 0 :
                        NativeParcelSync.merge(scoped,
                            notifyNewArrival: failure == nil &&
                                UserDefaults.standard.bool(forKey: baselineKey))
                    ParcelRunLog.record(platform, "手动读取：有效运单 \(scoped.count) 件，成功合并 \(count) 件")
                    if let failure {
                        detail = scoped.isEmpty ? failure :
                            "已保留 \(scoped.count) 件有效物流（合并 \(count) 件）；其余订单：" + failure
                        ParcelRunLog.record(platform, "手动网页读取未完整结束，已保留有效包裹")
                    } else {
                        if count == 0 { ParcelStore.shared.persist() }
                        UserDefaults.standard.set(syncedAt, forKey: "native.home.lastRefresh")
                        UserDefaults.standard.set(true, forKey: baselineKey)
                        UserDefaults.standard.set(syncedAt, forKey: "native.sync.success." + platform)
                        UserDefaults.standard.set(syncedAt,
                                                  forKey: "native.sync.success." + platform + "." + selected)
                        detail = "\(platform == "jd" ? "京东" : "淘宝")：读取 \(scoped.count) 件有效物流包裹，导入或更新 \(count) 件。"
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
    var onParcel: ((NativeSyncParcel) -> Void)? = nil


    // Follow HandyCode's document-start response capture and parcly's
    // structured logistics metadata, without exporting raw account JSON.
    // The local snapshot is normalized to safe order fields only.
    static let jdDocumentHook = #"""
    (function(){
      if (window.top!==window || !/(^|\.)jd\.com$/i.test(location.hostname)) return;
      if (window.ParcelHelperJD) return;
      var stored=[], structured=false, logistics=null, revision=0;
      function clean(v,n){return typeof v==='string'?v.slice(0,n):String(v==null?'':v).slice(0,n);}
      function jdURL(raw){
        if(typeof raw!=='string'||!raw)return '';
        try{
          var url=new URL(raw,location.href);
          return url.protocol==='https:'&&/(^|\.)jd\.com$/i.test(url.hostname)
            ? url.href.slice(0,900) : '';
        }catch(e){return ''}
      }
      function pickup(value){
        var t=clean(value,1800);
        var m=t.match(/(?:取件码|提货码|取货码|自提码|开箱码|取件密码)\s*(?:为|是)?\s*[:：\s【\[\(（]*([A-Za-z0-9-]{3,16})(?![A-Za-z0-9-])/);
        if(m)return m[1];
        m=t.match(/(?:请凭|凭码)\s*([A-Za-z0-9-]{4,14})\s*(?:到|前往|取件|领取)/);
        return m?m[1]:'';
      }
      function station(value){
        var t=clean(value,1500).replace(/\s+/g,' ');
        var m=t.match(/【([^】]{2,60}(?:驿站|自提点|代收点|快递柜|自提柜|超市)[^】]{0,25})】/);
        return m?m[1].slice(0,80):'';
      }
      function isInstant(o,progress){
        var deals=o.specialDealList||[];
        if(Array.isArray(deals)&&deals.some(function(v){return v&&(v.isStore2Home===true||v.isStore2Home===1||v.isStore2Home==='1')}))return true;
        var u=clean(progress.progressLink,500).toLowerCase();
        if(/store2home|daojia|instant/.test(u))return true;
        var msg=[o.message,o.messageTitle,progress.content,progress.tip].join(' ');
        return /秒送|京东到家|即时配送|分钟送达|分钟达/.test(msg);
      }
      function order(o){
        if(!o||typeof o!=='object')return null;
        var id=clean(o.orderId||o.orderid||o.dealId,80);
        if(!/^\d{8,}$/.test(id))return null;
        var info=o.orderStatusInfo||{},p=o.progressInfo||{};
        var status=clean(info.orderStatusName||o.orderStatusName||o.orderStatus,90);
        if(/取消|关闭|退款|cancel|close|refund/i.test(status)||isInstant(o,p))return null;
        var goods=Array.isArray(o.wareInfoList)?o.wareInfoList[0]||{}:{};
        var sku=clean(goods.skuId||goods.skuid||o.skuId,50);
        var shop=clean((o.shopInfo||{}).shopId||o.shopId,50);
        var msg=clean(p.content||p.subContent||p.tip||p.title||o.messageTitle||o.message,1200);
        var prompt=o.promptInfo||{},promptValue=clean(prompt.content,250);
        if(Array.isArray(prompt.variableList)){
          var k=0;
          promptValue=promptValue.replace(/%%%/g,function(){return clean(prompt.variableList[k++],40)});
        }
        var desc=[msg,promptValue,clean(p.tip,200),status].join(' ');
        var code=pickup(desc);
        var link=jdURL(p.progressLink);
        var detailLink=jdURL(o.orderDetailLink);
        if(!link&&/deal_wuliu|logistics|ordertrack|expressdetail/i.test(detailLink))link=detailLink;
        var courierProgress=/配送中|正在配送|配送途中|派送中|正在派送|运输中|已揽收|已发货|已出库|快递员|配送员|物流运输/.test(desc);
        var verified=p.progressId==='logistics'||/deal_wuliu|logistics|ordertrack|expressdetail/i.test(link)||courierProgress||/待收货|等待收货|待取件|待自提|待提货/.test(status);
        var active=/待发货|待收货|待出库|运输|配送|派送|待取|已出库|正在出库|waitreceive|shipping|delivering/i.test(status);
        // Ignore unrelated orders: a structured courier link/track or an
        // active shipping state/pickup code is required.
        if(!verified&&!active&&!code)return null;
        return {id:id,title:clean(goods.wareName||o.wareName||'京东订单',170),
          status:status,sku:sku,shop:shop,link:link,
          summary:msg||promptValue||clean(p.tip,200)||status,code:code,
          station:station(desc),verified:verified};
      }
      function consume(root){
        var lists=[],steps=0;
        function walk(node,depth){
          if(!node||typeof node!=='object'||depth>12||steps++>5000)return;
          if(Array.isArray(node)){
            for(var i=0;i<Math.min(node.length,50);i++)walk(node[i],depth+1);
            return;
          }
          if(Array.isArray(node.orderList)&&node.orderList.some(function(x){return x&&(x.orderId||x.orderid||x.dealId)})){
            lists.push(node.orderList.slice(0,100));
          }
          Object.keys(node).slice(0,60).forEach(function(key){
            try{walk(node[key],depth+1)}catch(e){}
          });
        }
        walk(root,0);
        if(!lists.length)return;
        structured=true;
        var rows={},count=0;
        lists.forEach(function(list){list.forEach(function(item){
          var out=order(item);
          if(!out)return;
          count++;
          var old=rows[out.id];
          if(!old||(!old.link&&out.link))rows[out.id]=out;
        })});
        var normalized=Object.keys(rows).map(function(k){return rows[k]});
        // Do not let a later unrelated empty result erase a richer snapshot.
        var merged={};
        stored.forEach(function(x){merged[x.id]=x});
        normalized.forEach(function(x){
          var old=merged[x.id];
          merged[x.id]=old?Object.assign({},old,x,{link:x.link||old.link}):x;
        });
        var next=Object.keys(merged).map(function(k){return merged[k]});
        if(JSON.stringify(next)!==JSON.stringify(stored)){stored=next.slice(0,200);revision++}
      }
      function consumeLogistics(root){
        var steps=0,found=null;
        function scan(node,depth){
          if(!node||typeof node!=='object'||depth>9||steps++>5000||found)return;
          if(Array.isArray(node)){node.slice(0,45).forEach(function(x){scan(x,depth+1)});return}
          if(Array.isArray(node.tracePointVOList)&&node.tracePointVOList.length){
            var tracks=node.tracePointVOList.slice(0,45).map(function(x){
              if(!x||typeof x!=='object')return null;
              var date=clean(x.createTime,40),desc=clean(x.wlStateDesc,450);
              if(!date||!desc)return null;
              if(/^\d{12,13}$/.test(date)){
                var dt=new Date(Number(date));
                if(!isNaN(dt.getTime())){
                  var pad=function(v){return String(v).padStart(2,'0')};
                  date=dt.getFullYear()+'-'+pad(dt.getMonth()+1)+'-'+pad(dt.getDate())+' '+
                    pad(dt.getHours())+':'+pad(dt.getMinutes())+':'+pad(dt.getSeconds());
                }
              }
              return {time:date,text:desc};
            }).filter(Boolean);
            if(tracks.length){
              tracks.sort(function(a,b){return b.time.localeCompare(a.time)});
              found={mail:clean(node.carriageId||node.waybillCode||node.mailNo,40),
                company:clean(node.carrier,50),latest:tracks[0].text,pickup:'',station:'',tracks:tracks};
              return;
            }
          }
          Object.keys(node).slice(0,60).forEach(function(k){scan(node[k],depth+1)});
        }
        scan(root,0);
        if(found)logistics=found;
      }
      function capture(raw){
        try{
          var str=typeof raw==='string'?raw:JSON.stringify(raw);
          if(!str||str.length>1800000)return;
          var hasOrders=str.indexOf('"orderList"')>=0;
          var hasLogs=str.indexOf('"tracePointVOList"')>=0;
          if(!hasOrders&&!hasLogs)return;
          var root=typeof raw==='string'?JSON.parse(raw):raw;
          if(hasOrders)consume(root);
          if(hasLogs)consumeLogistics(root);
        }catch(e){}
      }
      var originalSend=XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send=function(){
        this.addEventListener('load',function(){
          try{
            var u=new URL(this.responseURL,location.href);
            if(u.protocol!=='https:'||!/(^|\.)jd\.com$/i.test(u.hostname))return;
            if(this.responseType==='json')capture(this.response);
            else if(!this.responseType||this.responseType==='text')capture(this.responseText);
          }catch(e){}
        });
        return originalSend.apply(this,arguments);
      };
      var originalFetch=window.fetch;
      if(originalFetch)window.fetch=function(){
        var result=originalFetch.apply(this,arguments);
        if(result&&typeof result.then==='function'){
          result.then(function(res){
            try{
              var u=new URL(res.url,location.href);
              if(u.protocol==='https:'&&/(^|\.)jd\.com$/i.test(u.hostname)){
                res.clone().text().then(capture).catch(function(){});
              }
            }catch(e){}
          }).catch(function(){});
        }
        return result;
      };
      window.ParcelHelperJD={
        snapshot:function(){return {received:structured,orders:stored.slice(0,200),revision:revision}},
        logistics:function(){return logistics}
      };
    })()
    """#

    func makeCoordinator() -> Coordinator {
        Coordinator(platform: platform, accountID: accountID, onProgress: onProgress,
                    onComplete: onComplete, onParcel: onParcel)
    }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = ParcelAccounts.webStore(for: platform, accountID: accountID)
        if platform == "jd" {
            // Document-start hook captures only JD's own structured
            // order/logistics responses in the signed-in WKWebView.
            // No raw response, cookie or token crosses into Swift.
            config.userContentController.addUserScript(WKUserScript(
                source: Self.jdDocumentHook,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        }
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        let url = platform == "jd" ?
            "https://trade.m.jd.com/order/orderlist_jdm.shtml?sceneval=2" :
            "https://h5.m.taobao.com/mlapp/olist.html"
        view.load(URLRequest(url: URL(string: url)!))
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
        uiView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = action.request.url?.scheme?.lowercased()
            decisionHandler(scheme == "https" || scheme == "http" ||
                            scheme == "about" ? .allow : .cancel)
        }

        // JD's mobile order entry may open in target=_blank/window.open.
        // Keep official H5 navigation in this signed-in session instead of
        // silently losing the page or handing off to another installed app.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard action.targetFrame == nil,
                  let url = action.request.url,
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host?.lowercased(),
                  (platform == "jd"
                    ? (host == "jd.com" || host.hasSuffix(".jd.com"))
                    : (host == "taobao.com" || host.hasSuffix(".taobao.com") ||
                       host == "tmall.com" || host.hasSuffix(".tmall.com")))
            else { return nil }
            webView.load(action.request)
            return nil
        }
        enum Stage { case orderList, tracking }
        let platform: String
        let accountID: String?
        let onProgress: (String) -> Void
        let onComplete: ([NativeSyncParcel], String?) -> Void
        let onParcel: ((NativeSyncParcel) -> Void)?
        var stage = Stage.orderList
        var orders: [WebOrder] = []
        var loaded: [NativeSyncParcel] = []
        var position = 0
        var scanning = false
        var finished = false
        var usedJDFallback = false
        private var orderPageVersion = 0
        var emptyReadAttempts = 0
        private var usedTaobaoPC = false
        private var taobaoReadAttempts = 0
        var structuredReadWaits = 0
        private var jdPageReads = 0
        private var jdPreviousCount = 0
        private var jdStableReads = 0
        private var jdPendingTabAttempted = false
        private var jdAccumulated: [String: WebOrder] = [:]
        var trackingReadAttempts = 0
        var missingTracking = 0
        private var trackingPageSerial = 0
        private var trackingPageTimeout: DispatchWorkItem?

        private func record(_ stage: String) {
            let category = platform == "jd" ? "京东网页" : "淘宝网页"
            Task { @MainActor in ParcelRunLog.record(category, stage) }
        }

        init(platform: String, accountID: String?,
             onProgress: @escaping (String) -> Void,
             onComplete: @escaping ([NativeSyncParcel], String?) -> Void,
             onParcel: ((NativeSyncParcel) -> Void)?) {
            self.platform = platform
            self.accountID = accountID
            self.onProgress = onProgress
            self.onComplete = onComplete
            self.onParcel = onParcel
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).domain == NSURLErrorDomain &&
                (error as NSError).code == NSURLErrorCancelled { return }
            if stage == .tracking {
                trackingPageTimeout?.cancel()
                record("物流详情页无法打开：已跳过第 \(position + 1) 笔")
                if position < orders.count { preserveJDOrderSummary(orders[position]) }
                missingTracking += 1
                position += 1
                next(webView)
            } else {
                record("订单页打开失败（网络或页面访问错误）")
                complete("页面加载失败：\(error.localizedDescription)")
            }
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            if stage == .orderList {
                orderPageVersion += 1
                scanning = false
                structuredReadWaits = 0
                emptyReadAttempts = 0
            }
        }
        private func scheduleOrderRead(_ webView: WKWebView, after delay: TimeInterval) {
            let version = orderPageVersion
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                guard let self, let view = webView, !self.finished,
                      self.stage == .orderList, self.orderPageVersion == version else { return }
                self.readOrders(view)
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !finished else { return }
            if stage == .orderList && !scanning {
                scanning = true
                if platform == "jd" &&
                   webView.url?.host?.lowercased() == "my.m.jd.com" {
                    let version = orderPageVersion
                    webView.evaluateJavaScript(Self.openJDOrders) { [weak self, weak webView] value, _ in
                        guard let self, let view = webView, !self.finished,
                              self.stage == .orderList, self.orderPageVersion == version else { return }
                        if value as? Bool == true {
                            self.record("个人首页已触发待收货或全部订单入口，等待页面切换")
                            self.scheduleOrderRead(view, after: 4.0)
                        } else {
                            self.record("个人首页未找到订单入口，改用官方订单列表")
                            self.usedJDFallback = true
                            if let url = URL(string: "https://trade.m.jd.com/order/orderlist_jdm.shtml?sceneval=2") {
                                view.load(URLRequest(url: url))
                            }
                        }
                    }
                } else {
                    scheduleOrderRead(webView, after: 3.0)
                }
            } else if stage == .tracking {
                let serial = trackingPageSerial
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self, weak webView] in
                    guard let self, let view = webView, !self.finished,
                          self.trackingPageSerial == serial else { return }
                    self.readTracking(view, pageVersion: serial)
                }
            }
        }
        private func readOrders(_ webView: WKWebView) {
            guard !finished, stage == .orderList else { return }
            let version = orderPageVersion
            let script = platform == "jd" ? Self.jdOrdersJS : Self.taobaoOrdersJS
            webView.evaluateJavaScript(script) { [weak self, weak webView] value, error in
                guard let self, let webView, !self.finished,
                      self.stage == .orderList, self.orderPageVersion == version else { return }
                guard error == nil, let text = value as? String, let data = text.data(using: .utf8),
                      let result = try? JSONDecoder().decode(OrdersResponse.self, from: data) else {
                    self.record("订单页脚本无法解析：官方页面结构可能已变化")
                    self.complete("订单列表解析失败，页面可能已变更")
                    return
                }
                if self.platform == "jd" && self.emptyReadAttempts == 0 && self.structuredReadWaits == 0 {
                    self.record("订单页环境：\(result.page ?? "未知")，官方接口：\(result.structured == true ? "已识别" : "未识别")")
                }
                self.record("订单页检查：候选 \(result.orders.count) 笔，来源 \(result.source ?? "网页")")
                // JD's asynchronous order_list_m response can arrive after
                // the first DOM render. Let the document-start hook settle
                // before treating a fragile DOM guess as the order list.
                if self.platform == "jd" && result.structured != true &&
                   self.structuredReadWaits < 3 && !result.login && !result.verify {
                    self.structuredReadWaits += 1
                    self.scheduleOrderRead(webView, after: 1.5)
                    return
                }
                if self.platform == "jd" && result.page == "登录页" {
                    self.record("京东订单请求重定向到登录页")
                    self.complete("京东订单页面仍要求登录，请完成账号验证后再同步")
                    return
                }
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
                if self.platform == "jd", result.page == "订单页", !self.jdPendingTabAttempted {
                    self.jdPendingTabAttempted = true
                    webView.evaluateJavaScript(Self.jdSelectPending) { [weak self, weak webView] value, _ in
                        guard let self, let webView, !self.finished,
                              self.stage == .orderList, self.orderPageVersion == version else { return }
                        if value as? Bool == true {
                            self.jdAccumulated.removeAll()
                            self.record("已切换官方待收货筛选")
                        }
                        self.scheduleOrderRead(webView, after: 2.5)
                    }
                    return
                }
                var available = result.orders
                if self.platform == "jd" && (!result.orders.isEmpty || !self.jdAccumulated.isEmpty) {
                    for order in result.orders {
                        if self.jdAccumulated[order.id]?.verified == true && order.verified != true { continue }
                        self.jdAccumulated[order.id] = order
                    }
                    available = self.jdAccumulated.values.sorted { $0.id > $1.id }
                    let grew = available.count > self.jdPreviousCount
                    self.jdStableReads = grew ? 0 : self.jdStableReads + 1
                    self.jdPreviousCount = available.count
                    if self.jdPageReads < 8 && self.jdStableReads < 2 && available.count < 200 {
                        self.jdPageReads += 1
                        webView.evaluateJavaScript(Self.jdLoadNextPage) { [weak self, weak webView] _, _ in
                            guard let self, let webView, !self.finished,
                                  self.stage == .orderList, self.orderPageVersion == version else { return }
                            self.record("京东订单翻页检查：已累计 \(self.jdAccumulated.count) 笔")
                            self.scheduleOrderRead(webView, after: 1.8)
                        }
                        return
                    }
                }
                if self.platform == "taobao" && available.isEmpty && self.taobaoReadAttempts < 8 {
                    self.taobaoReadAttempts += 1
                    webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight)") { [weak self, weak webView] _, _ in
                        guard let self, let webView, !self.finished,
                              self.stage == .orderList, self.orderPageVersion == version else { return }
                        self.scheduleOrderRead(webView, after: 1.0)
                    }
                    return
                }
                if self.platform == "taobao" && available.isEmpty && !self.usedTaobaoPC {
                    self.usedTaobaoPC = true
                    self.taobaoReadAttempts = 0
                    self.record("淘宝移动订单页无结果，尝试官方电脑版订单页")
                    if let url = URL(string: "https://buyertrade.taobao.com/trade/itemlist/list_bought_items.htm") {
                        webView.load(URLRequest(url: url))
                        return
                    }
                }
                if self.platform == "jd" && !available.isEmpty {
                    let account = self.accountID ?? ParcelAccounts.activeID(for: "jd")
                    let prefix = (account == ParcelAccounts.legacyID("jd") ? "jd" : "jd:" + account) + ":"
                    var knownIDs = Set(available.map(\.id))
                    let existing = ParcelStore.shared.snapshot.parcels.filter {
                        ($0.isTransit || $0.isPending) && ($0.orderId ?? "").hasPrefix(prefix)
                    }.sorted { ($0.trackUpdatedAt ?? 0) < ($1.trackUpdatedAt ?? 0) }
                    for parcel in existing.prefix(5) {
                        let id = String((parcel.orderId ?? "").dropFirst(prefix.count))
                        guard id.range(of: #"^\d{8,}$"#, options: .regularExpression) != nil,
                              knownIDs.insert(id).inserted else { continue }
                        available.insert(WebOrder(id: id, title: parcel.itemTitle ?? "", status: "", sku: "", shop: ""), at: 0)
                    }
                }
                let eligible = available.filter { order in
                    guard order.id.range(of: #"^\d{8,}$"#, options: .regularExpression) != nil else { return false }
                    let account = self.accountID ?? ParcelAccounts.activeID(for: self.platform)
                    let prefix = account == ParcelAccounts.legacyID(self.platform) ? self.platform : self.platform + ":" + account
                    let known = ParcelStore.shared.snapshot.parcels.contains {
                        $0.orderId == prefix + ":" + order.id && !$0.isDone && !$0.isSigned
                    }
                    if known { return true }
                    return !["退款", "已关闭", "已完成", "交易成功", "已收货", "已取件", "确认收货"].contains {
                        order.status.contains($0)
                    } && (!order.status.contains("已签收") ||
                        (self.platform == "jd" && (!(order.code ?? "").isEmpty || Parcel.isStationArrival(order.summary ?? ""))))
                }
                let limit = self.platform == "jd" ? 15 : 10
                let cursorKey = "native.web.orderCursor." + self.platform + "." + (self.accountID ?? "default")
                let cursor = eligible.isEmpty ? 0 : max(0, UserDefaults.standard.integer(forKey: cursorKey)) % eligible.count
                let rotated = Array(eligible.dropFirst(cursor)) + Array(eligible.prefix(cursor))
                if self.platform == "jd" {
                    // Preserve all verified active summaries before applying the detail-query budget.
                    for order in eligible where order.verified == true {
                        self.preserveJDOrderSummary(order)
                    }
                }
                self.orders = Array(rotated.prefix(limit))
                UserDefaults.standard.set(eligible.isEmpty ? 0 : (cursor + self.orders.count) % eligible.count, forKey: cursorKey)
                self.record("筛选后可查询 \(self.orders.count) 笔订单")
                if self.orders.isEmpty && result.structured == true && self.usedJDFallback {
                    self.record("官方结构化订单列表已返回，但没有传统快递或待取订单；不把秒送等 DOM 内容误当快递")
                    self.complete("京东官方订单列表没有可导入的传统物流订单。请在京东核对是否为秒送、虚拟商品或已完成订单。")
                    return
                }
                if self.orders.isEmpty {
                    if self.emptyReadAttempts < 2 {
                        self.emptyReadAttempts += 1
                        self.scheduleOrderRead(webView, after: 2.0)
                        return
                    }
                    if self.platform == "jd" && result.page == "个人首页" && self.usedJDFallback {
                        self.record("备用入口仍停留在个人首页")
                        self.complete("京东个人首页未成功进入订单列表，请检查账号登录状态")
                        return
                    }
                    if self.platform == "jd" && !self.usedJDFallback {
                        self.record("官方订单列表无结果，尝试个人中心备用入口")
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
                    if self.platform == "jd" && result.structured == true {
                        for order in self.orders {
                            self.preserveJDOrderSummary(order)
                        }
                    }
                    self.stage = .tracking
                    self.position = 0
                    self.next(webView)
                }
            }
        }
        private func preserveJDOrderSummary(_ order: WebOrder,
                                            tracks: [TrackNode] = [],
                                            note: String? = nil) {
            guard platform == "jd" else { return }
            let code = (order.code ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = (note ?? order.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let isVerified = order.verified == true
            guard !code.isEmpty || (isVerified && !summary.isEmpty) else { return }
            // A verified courier status or pickup code may exist before JD
            // generates a waybill. Never use the order number as a fake waybill.
            if let slot = loaded.firstIndex(where: {
                $0.orderID == order.id && $0.mailNo.isEmpty
            }) {
                if !tracks.isEmpty {
                    loaded[slot].tracks = tracks
                    if !summary.isEmpty { loaded[slot].latest = summary }
                    onParcel?(loaded[slot])
                    record("官方物流轨迹已补齐（尚无有效运单号）")
                }
                return
            }
            var item = NativeSyncParcel(source: "jd")
            item.accountID = accountID ?? ""
            item.orderID = order.id
            item.orderStatus = order.status
            item.verifiedJDOrderLogistics = isVerified
            item.title = order.title
            item.code = code
            item.station = order.station ?? ""
            item.latest = summary
            item.tracks = tracks
            item.arrived = !code.isEmpty || Parcel.isStationArrival(summary)
            loaded.append(item)
            onParcel?(item)
            record("订单物流进度已保留（官方结构化订单，暂无有效运单号）")
        }

        private func next(_ webView: WKWebView) {
            guard !finished else { return }
            trackingPageTimeout?.cancel()
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
                // Structured order_list_m includes the *real* progressLink.
                // Do not hard-code dealState=7/orderType=22 or guess SKU IDs.
                let official = order.link.flatMap(URL.init(string:))
                let allowed = official?.scheme?.lowercased() == "https" &&
                    (official?.host?.lowercased() == "jd.com" ||
                     official?.host?.lowercased().hasSuffix(".jd.com") == true)
                if allowed, let official {
                    url = official.absoluteString
                } else {
                    var components = URLComponents(string:
                        "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml")!
                    components.queryItems = [
                        URLQueryItem(name: "from", value: "orderdetail"),
                        URLQueryItem(name: "dealState", value: "7"),
                        URLQueryItem(name: "dealId", value: order.id),
                        URLQueryItem(name: "orderType", value: "22"),
                        URLQueryItem(name: "skuid", value: order.sku),
                        URLQueryItem(name: "shopid", value: order.shop),
                        URLQueryItem(name: "source", value: "m_inner_orderList.track_orderTrack")
                    ]
                    url = components.url!.absoluteString
                }
            } else {
                url = "https://pages-g.m.taobao.com/wow/z/app/mtb/logisticsV2/h5-detail?x-ssr=true&bizOrderId=\(order.id)&viewLogisticDetail=true&skipEnterAnimation=true&forceThemis=true&disableNav=YES"
            }
            guard let parsed = URL(string: url) else { position += 1; next(webView); return }
            trackingPageSerial += 1
            if platform == "jd" {
                let version = trackingPageSerial
                let index = position
                let watchdog = DispatchWorkItem { [weak self, weak webView] in
                    guard let self, let view = webView, !self.finished,
                          self.position == index, self.trackingPageSerial == version else { return }
                    self.record("第 \(index + 1) 笔：京东物流页单笔等待超时，继续下一笔")
                    self.preserveJDOrderSummary(self.orders[index])
                    self.missingTracking += 1
                    self.position += 1
                    self.next(view)
                }
                trackingPageTimeout = watchdog
                DispatchQueue.main.asyncAfter(deadline: .now() + 11, execute: watchdog)
            }
            webView.load(URLRequest(url: parsed))
        }
        private func readTracking(_ webView: WKWebView, pageVersion: Int) {
            guard !finished, position < orders.count,
                  trackingPageSerial == pageVersion else { return }
            let expectedIndex = position
            let script = platform == "jd" ? Self.jdTrackingJS : Self.taobaoTrackingJS
            webView.evaluateJavaScript(script) { [weak self, weak webView] value, scriptError in
                guard let self, let webView, !self.finished,
                      self.position == expectedIndex,
                      self.trackingPageSerial == pageVersion,
                      self.position < self.orders.count else { return }
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
                        if self.platform == "jd", !shipment.tracks.isEmpty {
                            self.preserveJDOrderSummary(self.orders[self.position],
                                tracks: shipment.tracks, note: shipment.latest)
                            self.position += 1
                            self.next(webView)
                        } else {
                            self.retryTracking(webView, pageVersion: pageVersion)
                        }
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
                    item.latest = shipment.latest.isEmpty ? (order.summary ?? order.status) : shipment.latest
                    if Parcel.isStationArrival(order.summary ?? "") &&
                        !Parcel.confirmsFinalDelivery(item.latest) && !Parcel.confirmsRecipientPickup(item.latest) &&
                        !Parcel.isReturn(item.latest) {
                        item.latest = order.summary ?? item.latest
                    }
                    item.code = shipment.pickup
                    item.station = shipment.station
                    item.tracks = shipment.tracks
                    item.arrived = !shipment.pickup.isEmpty || Parcel.isStationArrival(item.latest) || Parcel.isStationArrival(order.summary ?? "")
                    if let slot = self.loaded.firstIndex(where: {
                        $0.orderID == item.orderID && $0.mailNo.isEmpty
                    }) {
                        self.loaded[slot] = item
                    } else {
                        self.loaded.append(item)
                    }
                    self.trackingPageTimeout?.cancel()
                    self.onParcel?(item)
                    self.record("第 \(self.position + 1) 笔：已识别有效运单及 \(shipment.tracks.count) 条轨迹")
                    self.position += 1
                    self.next(webView)
                    return
                }
                self.retryTracking(webView, pageVersion: pageVersion)
            }
        }

        private func retryTracking(_ webView: WKWebView, pageVersion: Int) {
            guard !finished, trackingPageSerial == pageVersion else { return }
            if trackingReadAttempts < 2 {
                trackingReadAttempts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { [weak self, weak webView] in
                    guard let self, let view = webView, !self.finished,
                          self.trackingPageSerial == pageVersion else { return }
                    self.readTracking(view, pageVersion: pageVersion)
                }
                return
            }
            trackingPageTimeout?.cancel()
            record("第 \(position + 1) 笔：物流页无有效运单号或解析失败（重试后）")
            if position < orders.count { preserveJDOrderSummary(orders[position]) }
            missingTracking += 1
            position += 1
            next(webView)
        }
        private func complete(_ error: String) {
            guard !finished else { return }
            trackingPageTimeout?.cancel()
            finished = true
            onComplete(loaded, error)
        }
        struct OrdersResponse: Decodable {
            let login: Bool
            let verify: Bool
            let orders: [WebOrder]
            let source: String?
            let structured: Bool?
            let page: String?
        }
        private static let openJDOrders = #"""
        (function(){
          var nodes=Array.from(document.querySelectorAll('a,div,span'));
          var el=nodes.find(function(x){
            return /^(待收货|进行中)$/.test((x.textContent||'').trim()) && x.children.length<3 && x.getClientRects().length;
          });
          if(!el)el=document.querySelector('.my_order_entrance.type_orders');
          if(!el)el=nodes.find(function(x){return (x.textContent||'').trim()==='全部订单'&&x.children.length<3&&x.getClientRects().length});
          if(el) { el.click(); return true; } return false;
        })()
        """#
        // JD uses multiple H5 layouts: old data-eparam cards, newer anchor
        // links, and client-side initial state. Read only the current signed-in
        // official page; no private API calls or login/session bypass.
        private static let jdSelectPending = #"""
        (function(){
          var candidates=Array.from(document.querySelectorAll('a,button,[role="tab"],[class*="tab"]'));
          var tab=candidates.find(function(el){
            return /^(待收货|等待收货)$/.test((el.textContent||'').trim()) && el.getClientRects().length &&
              !/active|selected|current/i.test(el.className||'') && el.getAttribute('aria-selected')!=='true';
          });
          if(!tab)return false;
          tab.click();return true;
        })()
        """#
        private static let jdLoadNextPage = #"""
        (function(){
          var candidates=Array.from(document.querySelectorAll('button,a,[role="button"]'));
          var more=candidates.find(function(el){
            return /^(加载更多|查看更多订单|下一页|更多订单)$/.test((el.textContent||'').trim())
              && !el.disabled && el.getAttribute('aria-disabled')!=='true' && el.getClientRects().length;
          });
          if(more){more.click();return true}
          var scroll=document.scrollingElement||document.documentElement;
          if(scroll){scroll.scrollTop=scroll.scrollHeight;window.dispatchEvent(new Event('scroll'))}
          return !!scroll;
        })()
        """#
        private static let jdOrdersJS = #"""
        (function(){
          var body=(document.body&&document.body.innerText||'').slice(0,4500);
          var path=(location.pathname||'').toLowerCase();
          var page=/login|passport|plogin/.test(location.hostname+path)?'登录页':
            /orderlist|order\/list/.test(path)?'订单页':
            location.hostname==='my.m.jd.com'||/myjd|index\.html|\/home/.test(path)?'个人首页':'其他页面';
          var hooked=null;
          try{hooked=window.ParcelHelperJD&&window.ParcelHelperJD.snapshot()}catch(e){}
          var orders=[],seen={},stats={attrs:0,links:0,state:0};
          if(hooked&&hooked.received){
            (hooked.orders||[]).forEach(function(o){seen[o.id]=orders.length+1;orders.push(o)});
          }
          function cardOf(el){
            if(!el||!el.closest) return document.body;
            return el.closest('[class*="order-card"],[class*="order_item"],[class*="orderItem"],[class*="order_list"],[data-orderid],[data-order-id]')||
                   el.closest('li,article,section')||el.parentElement||el;
          }
          function add(id,el,raw,source){
            id=String(id||'').trim();
            if(!/^\d{8,}$/.test(id))return;
            var previous=seen[id]?orders[seen[id]-1]:null;
            var card=cardOf(el),extra=raw||{};
            var sku=(extra.orderSkus&&extra.orderSkus[0])||{};
            var titleNode=card&&card.querySelector&&card.querySelector(
              '[class*="goods_name"],[class*="product_name"],[class*="goodsName"],[class*="desc"],[class*="sku_name"]');
            var statusNode=card&&card.querySelector&&card.querySelector(
              '[class*="order_state"],[class*="orderStatus"],[class*="status"],[class*="state"]');
            var title=titleNode?(titleNode.innerText||titleNode.textContent||'').trim().slice(0,120):'';
            var status=statusNode?(statusNode.innerText||statusNode.textContent||'').trim().slice(0,80):
                       String(extra.orderStatusName||extra.statusName||extra.orderStatus||'').slice(0,80);
            var logisticsNode=el&&card&&card.querySelector&&card.querySelector('[class*="order_wuliubar"]');
            var summary=logisticsNode?String(logisticsNode.innerText||logisticsNode.textContent||'').trim().slice(0,1200):'';
            var verified=!!el&&/待收货|等待收货|待取件|待自提|运输|派送|配送|已发货|已出库/.test(status+' '+summary)&&!/秒送|京东到家|即时配送/.test(status+' '+summary);
            var row={id:id,title:title,status:status,
              sku:String(sku.skuid||sku.skuId||extra.skuid||extra.skuId||''),
              shop:String(extra.shopId||extra.shopid||sku.shopid||''),
              summary:summary||status,verified:verified};
            if(previous){
              ['title','status','sku','shop','summary'].forEach(function(k){if(!previous[k]&&row[k])previous[k]=row[k]});
              if(summary&&!previous.verified){previous.summary=summary;previous.verified=verified}
            }else{
              seen[id]=orders.length+1;orders.push(row);
            }
            stats[source]++;
          }
          document.querySelectorAll('[class*="order_state"]').forEach(function(st){
            var card=st;
            while(card&&card.parentElement){
              card=card.parentElement;
              if(card.querySelector&&card.querySelector('[class*="order_item"]'))break;
            }
            var ep=card&&card.querySelector&&card.querySelector('[data-eparam]');
            if(!ep)return;
            var raw={};
            try{raw=JSON.parse((ep.getAttribute('data-eparam')||'').replace(/&quot;/g,'"'))}catch(e){}
            add(raw.orderid||raw.orderId||raw.dealId,ep,raw,'attrs');
          });
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
            source:(hooked&&hooked.received?'官方接口 + ':'')+'属性'+stats.attrs+' 链接'+stats.links+' 页面状态'+stats.state,
            structured:!!(hooked&&hooked.received),page:page,orders:orders.slice(0,200)
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
          try{
            var blob=JSON.stringify(raw)||'';
            var re=/(?:bizOrderId=|"orderId"\s*:\s*"?|"bizOrderId"\s*:\s*"?)(\d{10,})/g,m;
            while((m=re.exec(blob))&&o.length<80)add(m[1],'','');
          }catch(e){}
          document.querySelectorAll('a[href]').forEach(function(el){
            var href=el.getAttribute('href')||'';
            var match=href.match(/(?:bizOrderId|orderId|biz_order_id)=(\d{10,})/i);
            if(match)add(match[1],'','');
          });
          var html=document.documentElement&&document.documentElement.outerHTML||'';
          (html.match(/bizOrderId[=%:"\\]+[0-9]{10,}/g)||[]).forEach(function(v){
            var m=v.match(/\d{10,}/);if(m)add(m[0],'','');
          });
          var s=(document.body&&document.body.innerText||'').slice(0,1200);
          return JSON.stringify({login:/请登录|登录后查看/.test(s)&&!o.length,
            verify:/滑块验证|人机验证|安全验证/.test(s),orders:o.slice(0,40)});
        })()
        """#
        private static let jdTrackingJS = #"""
        (function(){
          try{
            var hooked=window.ParcelHelperJD&&window.ParcelHelperJD.logistics();
            if(hooked&&hooked.tracks&&hooked.tracks.length){
              hooked.login=false;hooked.verify=false;
              return JSON.stringify(hooked);
            }
          }catch(e){}
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
