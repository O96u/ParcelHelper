import Foundation
import SwiftUI
import Security
import CryptoKit

// Manual tracking ported from Scripting/kdniao.ts and ui/trackSearch.tsx.
// Native iOS client uses the API credentials the user entered, never hardcodes
// a third-party API secret or pretends to have tracked a parcel.
struct NativeTrackLookup {
    var mailNo: String
    var company: String
    var shipperCode: String
    var latest: String
    var nodes: [TrackNode]
    var receiverCity: String = ""
    var receiverAddress: String = ""
    var provider: String = ""
}
@MainActor enum NativeTracking {
    private static let service = "com.muxui.ParcelHelper.kdniao"
    static let shippers: [(String, String)] = [
        ("", "自动识别"), ("ZTO", "中通快递"), ("SF", "顺丰速运"),
        ("YTO", "圆通速递"), ("YUNDA", "韵达快递"), ("STO", "申通快递"),
        ("JT", "极兔速递"), ("EMS", "EMS"), ("YZPY", "中国邮政"),
        ("JD", "京东物流"), ("DBWL", "德邦快递"), ("HTKY", "百世快递"),
        ("DHL", "DHL"), ("FEDEX", "联邦快递"), ("UPS", "UPS")]
    private static let shippingCode: [String:String] = [
        "zhongtong":"ZTO", "shunfeng":"SF", "yuantong":"YTO",
        "yunda":"YUNDA", "shentong":"STO", "jtexpress":"JT",
        "ems":"EMS", "youzheng":"YZPY", "jd":"JD", "debang":"DBWL",
        "huitongkuaidi":"HTKY", "dhl":"DHL", "fedex":"FEDEX", "ups":"UPS"]
    static func get(_ name: String) -> String {
        let q:[String:Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var ref:CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess,
              let data = ref as? Data else { return "" }
        return String(data:data,encoding:.utf8) ?? ""
    }
    static func save(_ name:String, value:String) {
        let q:[String:Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String:name
        ]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var item = q
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary,nil)
    }

    // The bundled Scripting project's kdniao.ts obtains a short-lived login
    // token from the user's official WebView session and exchanges it for
    // EBusinessID / AppKey. Persist only the resulting credentials in Keychain.
    static func configureFromOfficialLogin(token: String) async throws {
        let accessToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard accessToken.count >= 12 && accessToken.count < 4096 else {
            throw NativeSyncError.noLogin("快递鸟官方网页登录尚未完成")
        }
        var request = URLRequest(
            url: URL(string: "https://coporate.kdniao.com/user-api/user/queryApiSecretKey")!,
            timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue(accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json;charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("https://biz.kdniao.com", forHTTPHeaderField: "Origin")
        request.setValue("https://biz.kdniao.com/", forHTTPHeaderField: "Referer")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "pageIndex": 1, "pageSize": 10
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw NativeSyncError.unavailable("快递鸟密钥接口连接失败，请稍后重试")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw NativeSyncError.badResponse("快递鸟返回了无法解析的密钥数据")
        }
        let root = json as? [String: Any] ?? [:]
        let entries = (root["data"] as? [[String: Any]]) ?? (json as? [[String: Any]]) ?? []
        func value(_ object: [String: Any], _ key: String) -> String {
            if let text = object[key] as? String { return text }
            if let number = object[key] as? NSNumber { return number.stringValue }
            return ""
        }
        guard let first = entries.first(where: {
            !value($0, "secretId").isEmpty || !value($0, "appKey").isEmpty
        }) else {
            throw NativeSyncError.unavailable(
                "快递鸟账号尚无 API 密钥，请先到官方后台创建，然后重新登录或手动填写")
        }
        let business = value(first, "userId").isEmpty
            ? value(first, "eBusinessId") : value(first, "userId")
        let secret = value(first, "secretId").isEmpty
            ? value(first, "appKey") : value(first, "secretId")
        try setCredential(businessID: business, apiKey: secret)
    }

    static var isConfigured:Bool { !get("businessID").isEmpty && !get("apiKey").isEmpty }
    // A documented public no-key tracking endpoint can disappear or throttle.
    // Do not send cookies or recipient phone numbers to public fallback APIs.
    private static let publicFallbackKey = "native.track.publicFallback.enabled"
    static var publicFallbackEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: publicFallbackKey) as? Bool) ?? false }
        set { UserDefaults.standard.set(newValue, forKey: publicFallbackKey) }
    }
    static var isKuaidi100Configured: Bool {
        !get("kuaidi100Customer").isEmpty && !get("kuaidi100Key").isEmpty
    }
    static func setKuaidi100(customer: String, key: String) throws {
        let id = customer.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...100).contains(id.count), (8...160).contains(secret.count),
              !id.contains(where: \.isWhitespace),
              !secret.contains(where: \.isWhitespace) else {
            throw NativeSyncError.badResponse("请填写有效的快递100 Customer 与 Key")
        }
        save("kuaidi100Customer", value: id)
        save("kuaidi100Key", value: secret)
    }
    static func clearKuaidi100() {
        save("kuaidi100Customer", value: "")
        save("kuaidi100Key", value: "")
    }
    private static let kuaidi100Codes: [String: String] = [
        "ZTO": "zhongtong", "SF": "shunfeng", "YTO": "yuantong",
        "YUNDA": "yunda", "STO": "shentong", "JT": "jtexpress",
        "EMS": "ems", "JD": "jd", "DBWL": "debangwuliu",
        "HTKY": "huitongkuaidi"
    ]
    private static var publicLastAttempt: [String: Date] = [:]
    private static var publicSuccessCache: [String: (Date, NativeTrackLookup)] = [:]
    // Kuaidi100's realtime API documents at least 30 minutes between
    // queries for the same waybill. Cache success and suppress repeats.
    private static var kuaidi100LastAttempt: [String: Date] = [:]
    private static var kuaidi100SuccessCache: [String: (Date, NativeTrackLookup)] = [:]

    // Login provenance is separate from API configuration. The official web
    // login token and unmasked phone are never persisted.
    static var hasOfficialLogin: Bool {
        isConfigured && get("officialLogin") == "1"
    }
    static var maskedOfficialPhone: String {
        hasOfficialLogin ? get("maskedOfficialPhone") : ""
    }
    static var accountStatus: String {
        if hasOfficialLogin {
            return maskedOfficialPhone.isEmpty
                ? "官方账号已登录" : maskedOfficialPhone + " · 已登录"
        }
        return isConfigured ? "API 已配置" : "未授权"
    }
    static func rememberOfficialLogin(maskedPhone: String?) {
        guard isConfigured else { return }
        let phone = maskedPhone ?? ""
        let valid = phone.range(of: #"^1[3-9][0-9]\*{4}[0-9]{4}$"#,
                                options: .regularExpression) != nil
        save("officialLogin", value: "1")
        save("maskedOfficialPhone", value: valid ? phone : "")
    }
    static func setCredential(businessID:String, apiKey:String) throws {
        let id = businessID.trimmingCharacters(in:.whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in:.whitespacesAndNewlines)
        guard id.range(of:#"^[0-9A-Za-z]{4,40}$"#,options:.regularExpression) != nil,
              key.count >= 8 && key.count <= 160 else {
            throw NativeSyncError.badResponse("请输入有效的快递鸟 EBusinessID 与 API Key")
        }
        save("businessID",value:id);save("apiKey",value:key)
        save("officialLogin",value:"");save("maskedOfficialPhone",value:"")
    }
    static func clearCredential() {
        save("businessID",value:"");save("apiKey",value:"")
        save("officialLogin",value:"");save("maskedOfficialPhone",value:"")
    }
    static func history() -> [String] {
        UserDefaults.standard.stringArray(forKey:"native.track.history") ?? []
    }
    static func remember(_ mail:String) {
        UserDefaults.standard.set(Array(([mail] + history().filter{$0 != mail}).prefix(9)),
                                  forKey:"native.track.history")
    }
    static func forget(_ mail:String) {
        UserDefaults.standard.set(history().filter{$0 != mail},forKey:"native.track.history")
    }
    static func clearHistory() {
        UserDefaults.standard.removeObject(forKey:"native.track.history")
    }
    static func phone(for mail:String) -> String {
        UserDefaults.standard.string(forKey:"native.track.phone."+mail) ?? ""
    }
    static func savePhone(_ phone:String, mail:String) {
        UserDefaults.standard.set(phone, forKey:"native.track.phone."+mail)
    }
    private static func detect(_ mail:String) async throws -> (String,String) {
        var component = URLComponents(string:"https://www.kuaidi100.com/autonumber/autoComNum")!
        component.queryItems = [
            URLQueryItem(name:"resultv2",value:"1"),
            URLQueryItem(name:"text",value:mail)]
        var request = URLRequest(url:component.url!,timeoutInterval:15)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1",forHTTPHeaderField:"User-Agent")
        request.setValue("https://www.kuaidi100.com/",forHTTPHeaderField:"Referer")
        let (data,response) = try await URLSession.shared.data(for:request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let entry = (json["auto"] as? [[String:Any]])?.first,
              let original = entry["comCode"] as? String else {
            throw NativeSyncError.unavailable("无法识别快递公司，请手动选择快递公司")
        }
        return (shippingCode[original.lowercased()] ?? original.uppercased(),
                entry["name"] as? String ?? "")
    }
    private static func formEscape(_ value:String)->String {
        value.addingPercentEncoding(withAllowedCharacters:.alphanumerics) ?? value
    }
    private static func flatten(_ object:Any?, depth:Int=0)->String {
        guard let object, depth < 5 else { return "" }
        if let s = object as? String { return s }
        if let n = object as? NSNumber { return n.stringValue }
        if let a = object as? [Any] {
            return a.map{flatten($0,depth:depth+1)}.filter{ !$0.isEmpty }.joined(separator:" ")
        }
        if let d = object as? [String:Any] {
            let fav = ["Desc","AcceptStation","Station","Content","Text","Description","Remark"]
                .compactMap{d[$0]}.map{flatten($0,depth:depth+1)}.filter{ !$0.isEmpty }
            return (fav.isEmpty ? d.values.map{flatten($0,depth:depth+1)}.filter{ !$0.isEmpty } : fav)
                .joined(separator:" ")
        }
        return ""
    }
    static func lookup(_ mailRaw:String, source:String?=nil, shipperCode:String="",
                       phone:String="", accountIDs: [String] = []) async throws -> NativeTrackLookup {
        let mail=mailRaw.trimmingCharacters(in:.whitespacesAndNewlines)
            .replacingOccurrences(of:" ",with:"")
        guard mail.range(of:#"^[A-Za-z0-9-]{8,40}$"#,options:.regularExpression) != nil else {
            throw NativeSyncError.badResponse("请填写有效的运单号（8 至 40 位字母、数字或短横线）")
        }
        var failures: [String] = []
        var statusOnly: NativeTrackLookup?
        // User-configured provider gets absolute priority. Only a missing or
        // invalid route triggers the next source; no concurrent API storms.
        if isConfigured {
            do {
                let found = try await kdniaoLookup(mail, shipperCode: shipperCode, phone: phone)
                remember(mail)
                return found
            } catch {
                failures.append("快递鸟：" + error.localizedDescription)
            }
        }

        // Use the selected parcel's own platform account before sending its
        // number to another third party; this also covers friend parcels.
        if let native = await NativeParcelSync.lookupShipment(
            mail, source: source, accountIDs: accountIDs) {
            if !native.nodes.isEmpty {
                remember(mail)
                return native
            }
            if !native.latest.isEmpty { statusOnly = native }
        }

        if isKuaidi100Configured {
            do {
                let found = try await kuaidi100Lookup(
                    mail, shipperCode: shipperCode, phone: phone)
                remember(mail)
                return found
            } catch {
                failures.append("快递100：" + error.localizedDescription)
            }
        }

        if publicFallbackEnabled {
            do {
                let found = try await publicLookup(mail)
                remember(mail)
                return found
            } catch {
                failures.append("公开接口：" + error.localizedDescription)
            }
        }

        // A verified first-party status is more useful than an error when
        // none of the backup providers supplies a full event timeline.
        if let statusOnly {
            remember(mail)
            return statusOnly
        }
        let detail = failures.isEmpty ? "" :
            "；" + failures.prefix(3).joined(separator: "；")
        if !publicFallbackEnabled && !isConfigured && !isKuaidi100Configured {
            throw NativeSyncError.unavailable(
                "已授权平台没有返回有效物流轨迹。可在快递鸟设置中配置 API 或开启公开接口兜底。")
        }
        throw NativeSyncError.unavailable(
            "已尝试可用物流接口，但未获得有效轨迹" + detail)
    }

    private static func kdniaoLookup(_ mail: String,
                                     shipperCode: String,
                                     phone: String) async throws -> NativeTrackLookup {
        let id=get("businessID"),secret=get("apiKey")
        var chosen=shipperCode.trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
        var company=shippers.first(where:{$0.0 == chosen})?.1 ?? ""
        if chosen.isEmpty {
            (chosen,company) = try await detect(mail)
        }
        let tail=phone.isEmpty ? self.phone(for:mail) : phone.trimmingCharacters(in:.whitespacesAndNewlines)
        if !tail.isEmpty {
            guard tail.range(of:#"^\d{4}$"#,options:.regularExpression) != nil else {
                throw NativeSyncError.badResponse("手机号尾号应为 4 位数字")
            }
        }
        var data:[String:Any] = ["LogisticCode":mail,"ShipperCode":chosen]
        if !tail.isEmpty { data["CustomerName"]=tail }
        let encoded=try JSONSerialization.data(withJSONObject:data,options:[.sortedKeys])
        guard let requestData=String(data:encoded,encoding:.utf8) else {
            throw NativeSyncError.badResponse("无法生成快递鸟请求参数")
        }
        let rawSign=requestData + secret
        let hex=Insecure.MD5.hash(data:Data(rawSign.utf8))
            .map{String(format:"%02x",$0)}.joined()
        let sign=Data(hex.utf8).base64EncodedString()
        let body="RequestData=" + formEscape(requestData) +
            "&EBusinessID=" + formEscape(id) +
            "&RequestType=8001&DataSign=" + formEscape(sign) + "&DataType=2"
        let url=URL(string:"https://api.kdniao.com/Ebusiness/EbusinessOrderHandle.aspx")!
        var req=URLRequest(url:url,timeoutInterval:25)
        req.httpMethod="POST"
        req.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type")
        req.setValue("application/json",forHTTPHeaderField:"Accept")
        req.httpBody=Data(body.utf8)
        let (responseData,response)=try await URLSession.shared.data(for:req)
        guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode) else {
            throw NativeSyncError.unavailable("快递鸟网络请求失败")
        }
        guard let json=try? JSONSerialization.jsonObject(with:responseData) as? [String:Any] else {
            throw NativeSyncError.badResponse("快递鸟返回无法解析的数据")
        }
        let success=json["Success"] as? Bool ?? false
        if !success {
            let reason=json["Reason"] as? String ?? "查询失败"
            if reason.contains("手机尾号") {
                throw NativeSyncError.verify(reason+"，请填写收件人手机号后四位")
            }
            throw NativeSyncError.unavailable("快递鸟："+reason)
        }
        let traces=(json["Traces"] as? [[String:Any]] ?? [])
            .map{($0["AcceptTime"] as? String ?? "", flatten($0["AcceptStation"]))}
            .filter{ !$0.1.isEmpty }
            .sorted{$0.0 > $1.0}
            .prefix(60)
            .map{TrackNode(time:$0.0,text:$0.1)}
        let latest=traces.first?.text ?? ""
        // Only a genuine trace is a successful result for failover.
        // A state code without route events must not hide other providers.
        guard !traces.isEmpty else {
            throw NativeSyncError.unavailable("快递鸟没有返回这笔运单的有效物流轨迹")
        }
        if !tail.isEmpty { savePhone(tail,mail:mail) }
        remember(mail)
        return NativeTrackLookup(mailNo:mail,company:company,shipperCode:chosen,
                                 latest:latest,nodes:Array(traces),provider:"快递鸟")
    }
    // Official Kuaidi100 realtime API: POST /poll/query.do, MD5 of
    // param + key + customer, uppercase hex. Requires the user's own keys.
    // Docs: https://api.kuaidi100.com/document/5f0ffb5ebc8da837cbd8aefc.html
    private static func kuaidi100Lookup(_ mail: String,
                                        shipperCode: String,
                                        phone: String) async throws -> NativeTrackLookup {
        let now = Date()
        if let cached = kuaidi100SuccessCache[mail],
           now.timeIntervalSince(cached.0) < 1800 {
            var found = cached.1
            found.provider = "快递100（30分钟内缓存）"
            return found
        }
        let persisted = UserDefaults.standard.double(
            forKey: "native.track.kuaidi100.last." + mail)
        let previous = kuaidi100LastAttempt[mail] ??
            (persisted > 0 ? Date(timeIntervalSince1970: persisted) : nil)
        if let previous, now.timeIntervalSince(previous) < 1800 {
            throw NativeSyncError.unavailable("该运单查询间隔需不少于30分钟")
        }
        var selected = shipperCode.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if selected.isEmpty, let detected = try? await detect(mail) {
            selected = detected.0
        }
        guard let code = kuaidi100Codes[selected] else {
            throw NativeSyncError.unavailable("没有可确认的快递公司编码")
        }
        let fullPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        // Kuaidi100 documents a full phone for SF / ZTO, not four digits.
        if (selected == "SF" || selected == "ZTO") && fullPhone.count != 11 {
            throw NativeSyncError.verify("此快递公司查询需要完整号码，已跳过备选接口")
        }
        var query: [String: String] = [
            "com": code, "num": mail, "show": "0", "order": "desc"
        ]
        if fullPhone.range(of: #"^1[3-9][0-9]{9}$"#,
                           options: .regularExpression) != nil {
            query["phone"] = fullPhone
        }
        let blob = try JSONSerialization.data(withJSONObject: query, options: [.sortedKeys])
        guard let param = String(data: blob, encoding: .utf8) else {
            throw NativeSyncError.badResponse("快递100请求编码失败")
        }
        let customer = get("kuaidi100Customer")
        let key = get("kuaidi100Key")
        let checksum = param + key + customer
        let sign = Insecure.MD5.hash(data: Data(checksum.utf8))
            .map { String(format: "%02X", $0) }.joined()
        let body = "customer=" + formEscape(customer) +
            "&sign=" + formEscape(sign) + "&param=" + formEscape(param)
        var req = URLRequest(url: URL(string: "https://poll.kuaidi100.com/poll/query.do")!,
                             cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: 13)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded",
                     forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        req.httpShouldHandleCookies = false
        kuaidi100LastAttempt[mail] = now
        UserDefaults.standard.set(now.timeIntervalSince1970,
            forKey: "native.track.kuaidi100.last." + mail)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count < 500_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeSyncError.unavailable("快递100网络请求失败")
        }
        let status = String(describing: json["status"] ?? "")
        guard status == "200" else {
            throw NativeSyncError.unavailable(
                (json["message"] as? String) ?? "快递100未提供有效轨迹")
        }
        if let returned = json["nu"] as? String, !returned.isEmpty,
           returned.caseInsensitiveCompare(mail) != .orderedSame {
            throw NativeSyncError.badResponse("快递100运单号不匹配")
        }
        let nodes = (json["data"] as? [[String: Any]] ?? [])
            .compactMap { item -> TrackNode? in
                let content = item["context"] as? String ?? ""
                guard !content.isEmpty else { return nil }
                return TrackNode(time: item["time"] as? String ?? "", text: content)
            }
        guard !nodes.isEmpty else {
            throw NativeSyncError.unavailable("快递100未返回物流轨迹")
        }
        let result = NativeTrackLookup(mailNo: mail,
            company: shippers.first(where: { $0.0 == selected })?.1 ?? "",
            shipperCode: selected, latest: nodes[0].text,
            nodes: Array(nodes.prefix(60)), provider: "快递100")
        kuaidi100SuccessCache[mail] = (Date(), result)
        return result
    }

    // Publicly documented free endpoint. As third-party availability is not
    // guaranteed, throttle it independently and accept ONLY matching
    // waybill numbers plus timestamped textual tracking events.
    // Docs: https://api.aa1.cn/api.aa1.cn/doc/szx-express-tracking.html
    private static func publicLookup(_ mail: String) async throws -> NativeTrackLookup {
        if let cached = publicSuccessCache[mail],
           Date().timeIntervalSince(cached.0) < 180 {
            var data = cached.1
            data.provider = "公开接口（短时缓存）"
            return data
        }
        if let previous = publicLastAttempt[mail],
           Date().timeIntervalSince(previous) < 180 {
            throw NativeSyncError.unavailable("免费接口限频中，请稍后查询")
        }
        publicLastAttempt[mail] = Date()
        var parts = URLComponents(string:
            "https://api.songzixian.com/api/express/tracking")!
        parts.queryItems = [
            .init(name: "dataSource", value: "nationwide_express"),
            .init(name: "trackingNumber", value: mail)
        ]
        guard let url = parts.url, url.host == "api.songzixian.com" else {
            throw NativeSyncError.badResponse("公开接口地址异常")
        }
        var req = URLRequest(url: url,
                             cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: 10)
        req.httpShouldHandleCookies = false
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200, data.count < 500_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["code"] as? Int) == 200,
              let payload = json["data"] as? [String: Any] else {
            throw NativeSyncError.unavailable("公开接口暂不可用")
        }
        guard let responseMail = payload["trackingNumber"] as? String,
              responseMail.caseInsensitiveCompare(mail) == .orderedSame else {
            throw NativeSyncError.badResponse("公开接口返回运单号不匹配")
        }
        let nodes = (payload["trackingDetails"] as? [[String: Any]] ?? [])
            .compactMap { node -> TrackNode? in
                let text = node["description"] as? String ?? ""
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return TrackNode(time: node["time"] as? String ?? "", text: text)
            }
            .sorted { $0.time > $1.time }
        guard !nodes.isEmpty else {
            throw NativeSyncError.unavailable("公开接口暂无物流轨迹")
        }
        let result = NativeTrackLookup(mailNo: mail,
            company: payload["courierName"] as? String ?? "",
            shipperCode: payload["courierCode"] as? String ?? "",
            latest: nodes[0].text, nodes: Array(nodes.prefix(60)),
            provider: "公开接口（Songzixian）")
        publicSuccessCache[mail] = (Date(), result)
        return result
    }
}
