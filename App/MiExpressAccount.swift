import Foundation
import SwiftUI
import WebKit
import CryptoKit
import CommonCrypto
import Security

// Native port of the supplied utils/mi.ts protocol. Endpoint, payload format,
// AES-ECB, and Xiaomi STS exchange are not official public API contracts.
// No service-token or cookie values are logged or exposed to the UI.

@MainActor enum NativeMiExpress {
    private static let host = "https://verca.xpa.assistant.miui.com"
    private static let aesKey = "d101b17c77ff93cs"
    private static let salt = "77eb2e8a5755abd016c0d69ba74b219c"
    private static let version = 25000031

    private enum KeychainData {
        static func load(_ key: String) -> String {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.muxui.ParcelHelper.xiaomi",
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        static func store(_ key: String, _ value: String) {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.muxui.ParcelHelper.xiaomi",
                kSecAttrAccount as String: key
            ]
            SecItemDelete(q as CFDictionary)
            var set = q
            set[kSecValueData as String] = Data(value.utf8)
            set[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(set as CFDictionary, nil)
        }
        static func remove(_ key: String) {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.muxui.ParcelHelper.xiaomi",
                kSecAttrAccount as String: key
            ]
            SecItemDelete(q as CFDictionary)
        }
    }
    static var hasSession: Bool { !KeychainData.load("token").isEmpty }
    static var phones: [String] {
        get { KeychainData.load("phones").split(separator: ",").map(String.init) }
        set { KeychainData.store("phones", newValue.joined(separator: ",")) }
    }
    static func clearSession() {
        ["token", "user", "phones"].forEach(KeychainData.remove)
    }
    private static func sha1(_ value: String) -> Data {
        Data(Insecure.SHA1.hash(data: Data(value.utf8)))
    }
    private static func crypt(_ data: Data, encrypt: Bool) throws -> Data {
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var length: size_t = 0
        let key = Array(aesKey.utf8)
        let status = data.withUnsafeBytes { inBytes in
            key.withUnsafeBytes { keyBytes in
                output.withUnsafeMutableBytes { outBytes in
                    CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, kCCKeySizeAES128, nil,
                            inBytes.baseAddress, data.count,
                            outBytes.baseAddress, outputCapacity, &length)
                }
            }
        }
        guard status == kCCSuccess else {
            throw NativeSyncError.badResponse("小米 AES 数据处理失败")
        }
        return Data(output.prefix(length))
    }
    private static func encrypt(_ text: String) throws -> String {
        try crypt(Data(text.utf8), encrypt: true).base64EncodedString()
    }
    private static func decrypt(_ encoded: String) throws -> String {
        guard let data = Data(base64Encoded: encoded) else {
            throw NativeSyncError.badResponse("小米返回的加密数据不是 Base64")
        }
        return String(data: try crypt(data, encrypt: false), encoding: .utf8) ?? ""
    }
    private static func json(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    private static func str(_ value: Any?) -> String {
        if let v = value as? String { return v }
        if let v = value as? NSNumber { return v.stringValue }
        return ""
    }
    private static func first(_ obj: [String: Any], _ keys: [String]) -> String {
        keys.map { str(obj[$0]) }.first(where: { !$0.isEmpty }) ?? ""
    }
    private static func isSuccess(_ response: [String: Any]) -> Bool {
        let status = json(response["status"])
        return str(response["code"]) == "0" || str(status["code"]) == "0"
    }

    private final class DoNotFollowRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func exchangeWebLogin() async throws {
        // Keep the login WebView alive while the cookie store finishes persisting.
        // deviceId is not guaranteed to be present on every Xiaomi login.
        var user = "", passToken = "", deviceID = ""
        for attempt in 0..<5 {
            let list = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            let cookies = list.filter {
                ($0.domain == "account.xiaomi.com" || $0.domain.hasSuffix(".xiaomi.com") ||
                 $0.domain == "id.mi.com") &&
                ($0.expiresDate == nil || $0.expiresDate! > Date())
            }
            user = cookies.first(where: { $0.name == "userId" })?.value ?? ""
            passToken = cookies.first(where: { $0.name == "passToken" })?.value ?? ""
            deviceID = cookies.first(where: { $0.name == "deviceId" })?.value ?? ""
            if !user.isEmpty && !passToken.isEmpty { break }
            if attempt < 4 { try await Task.sleep(for: .milliseconds(350)) }
        }
        guard !user.isEmpty, !passToken.isEmpty else {
            let missing = [user.isEmpty ? "userId" : nil,
                           passToken.isEmpty ? "passToken" : nil].compactMap { $0 }.joined(separator: "、")
            throw NativeSyncError.noLogin("尚未取得小米登录 Cookie（缺少 \(missing)），请完成网页验证后重试")
        }
        var header = "userId=\(user); passToken=\(passToken)"
        if !deviceID.isEmpty { header += "; deviceId=\(deviceID)" }
        var req = URLRequest(url: URL(string:
            "https://account.xiaomi.com/pass/serviceLogin?sid=assistant&_json=true&_appName=com.miui.personalassistant&_locale=zh_CN")!,
            timeoutInterval: 20)
        req.setValue(header, forHTTPHeaderField: "Cookie")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let _ = response as? HTTPURLResponse,
              let body = String(data: data, encoding: .utf8),
              let begin = body.firstIndex(of: "{"),
              let raw = body[begin...].data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              str(result["code"]) == "0" else {
            throw NativeSyncError.noLogin("小米 STS 登录校验失败，请在小米账号页重新登录")
        }
        let nonce = str(result["nonce"]), security = str(result["ssecurity"])
        let redirect = str(result["location"])
        guard !nonce.isEmpty, !security.isEmpty,
              let redirectURL = URL(string: redirect),
              redirectURL.scheme == "https" else {
            throw NativeSyncError.badResponse("小米 STS 返回参数不完整")
        }
        let sign = sha1("nonce=\(nonce)&\(security)").base64EncodedString()
        var parts = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false)!
        var items = parts.queryItems ?? []
        items.append(.init(name: "clientSign", value: sign))
        items.append(.init(name: "_userIdNeedEncrypt", value: "true"))
        parts.queryItems = items
        var final = URLRequest(url: parts.url!, timeoutInterval: 20)
        final.setValue(header, forHTTPHeaderField: "Cookie")
        let session = URLSession(configuration: .ephemeral, delegate: DoNotFollowRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (_, tokenResponse) = try await session.data(for: final)
        guard let http = tokenResponse as? HTTPURLResponse else {
            throw NativeSyncError.badResponse("小米 STS 响应异常")
        }
        // URLSession may normalize multiple Set-Cookie headers. Parse structured
        // cookies first, then use a targeted fallback for combined headers.
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { output, item in
            if let key = item.key as? String { output[key] = String(describing: item.value) }
        }
        let responseCookies = HTTPCookie.cookies(withResponseHeaderFields: headers,
                                                  for: http.url ?? redirectURL)
        var token = responseCookies.first(where: { $0.name == "serviceToken" })?.value ?? ""
        if token.isEmpty {
            let rawHeader = headers.first(where: { $0.key.caseInsensitiveCompare("Set-Cookie") == .orderedSame })?.value ?? ""
            if let match = rawHeader.range(of: #"(?:^|[;,\n])\s*serviceToken=([^;,\s]+)"#,
                                           options: .regularExpression) {
                let cookie = String(rawHeader[match])
                token = String(cookie.split(separator: "=", maxSplits: 1).last ?? "")
            }
        }
        if token.isEmpty {
            token = session.configuration.httpCookieStorage?.cookies?
                .first(where: { $0.name == "serviceToken" })?.value ?? ""
        }
        guard !token.isEmpty else {
            throw NativeSyncError.noLogin(
                "小米账号会话已读取，但 assistant 服务尚未签发 serviceToken（HTTP \\(http.statusCode)）。请确认账号已完成安全验证；若仍失败，可能是小米限制了第三方 WebView 的 STS 授权。"
            )
        }
        KeychainData.store("token", token)
        KeychainData.store("user", str(result["cUserId"]).isEmpty ? user : str(result["cUserId"]))
    }

    private static func wrap(_ data: [String: Any], userID: String) -> [String: Any] {
        let ts = String(Int64(Date().timeIntervalSince1970 * 1000))
        let env: [String: Any] = [
            "terminal": "phone", "assistantVersion": version, "launchVersion": 0,
            "androidVersion": "14", "androidSdkVersion": 34,
            "miuiType": "stable", "phoneModel": "2210132C", "phoneDevice": "sky",
            "connectionType": "WIFI", "miuiVersionName": "V14", "miuiVersion": "14.0.6",
            "osVersionName": "HyperOS 1.0", "osVersion": "1.0",
            "miSettingsVersionName": "", "miSettingsVersionCode": 0,
            "timeZone": "Asia/Shanghai", "language": "zh", "country": "CN",
            "screen": 1, "coordinate": "", "reqId": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            "ip": "", "cpuArchitecture": "arm64",
            "marketVersion": 0, "os": "", "clientFlag": 0, "hwVersion": ""
        ]
        return [
            "userSignal": ["oaid": "", "vaid": "", "userId": userID],
            "environmentSignal": env,
            "timeSignal": ["clientTs": ts, "timeZone": "中国标准时间"],
            "eventSignal": data
        ]
    }
    private static func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        let token = KeychainData.load("token")
        let user = KeychainData.load("user")
        guard !token.isEmpty else { throw NativeSyncError.noLogin("请先完成小米账号授权") }
        guard path.hasPrefix("/cpa/express/") else {
            throw NativeSyncError.badResponse("小米详情路径不符合预期")
        }
        let encodedPath = try encrypt(path)
        let signed = sha1("yellowpage_encparam\(encodedPath)\(salt)")
            .map { String(format: "%02X", $0) }.joined()
        var u = URLComponents(string: host + path)!
        u.queryItems = [
            .init(name: "version", value: String(version)),
            .init(name: "appkey", value: "yellowpage"),
            .init(name: "yellowpage_encparam", value: encodedPath),
            .init(name: "sign", value: signed),
            .init(name: "_encparam", value: encodedPath)
        ]
        let wrapped = wrap(body, userID: user)
        let bodyData = try JSONSerialization.data(withJSONObject: wrapped)
        let encrypted = try encrypt(String(data: bodyData, encoding: .utf8) ?? "{}")
        var request = URLRequest(url: u.url!, timeoutInterval: 22)
        request.httpMethod = "POST"
        request.httpBody = Data(encrypted.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("serviceToken=\(token); cUserId=\(user)", forHTTPHeaderField: "Cookie")
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NativeSyncError.unavailable("小米接口请求失败")
        }
        guard let root = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw NativeSyncError.badResponse("小米返回非 JSON 数据")
        }
        var result = root
        if let string = root["data"] as? String, !string.isEmpty,
           let decoded = try? decrypt(string),
           let blob = decoded.data(using: .utf8),
           let decodedJSON = try? JSONSerialization.jsonObject(with: blob) {
            result["data"] = decodedJSON
        }
        guard isSuccess(result) else {
            throw NativeSyncError.unavailable("小米业务返回失败（" + str(result["code"]) + "）")
        }
        return result
    }
    // Phone binding uses Xiaomi's remote verification and bind endpoints.
    // Update the local list only after the remote server confirms success.
    static func sendPhoneCode(_ phone: String) async throws {
        guard phone.range(of: #"^1\d{10}$"#, options: .regularExpression) != nil else {
            throw NativeSyncError.badResponse("请输入 11 位手机号")
        }
        _ = try await post("/cpa/express/phone/sendVerificationCode", body: [
            "info": ["phone": phone]
        ])
    }
    static func bindVerifiedPhone(_ phone: String, code: String) async throws {
        guard phone.range(of: #"^1\d{10}$"#, options: .regularExpression) != nil,
              code.range(of: #"^\d{4,8}$"#, options: .regularExpression) != nil else {
            throw NativeSyncError.badResponse("手机号或验证码不正确")
        }
        _ = try await post("/cpa/express/phone/checkVerificationCode", body: [
            "info": ["phone": phone, "verificationCode": code]
        ])
        let next = Array(Set(phones + [phone])).sorted()
        _ = try await post("/cpa/express/phone/bind", body: [
            "cardId": 3, "serviceKey": "express",
            "info": ["type": 1, "phone": phone, "phoneList": next]
        ])
        phones = next
    }
    static func unbindPhone(_ phone: String) async throws {
        guard phones.contains(phone) else { return }
        _ = try await post("/cpa/express/phone/bind", body: [
            "cardId": 3, "serviceKey": "express",
            "info": ["type": 2, "phone": phone, "phoneList": [phone]]
        ])
        let remaining = phones.filter { $0 != phone }
        if let first = remaining.first {
            _ = try await post("/cpa/express/phone/bind", body: [
                "cardId": 3, "serviceKey": "express",
                "info": ["type": 1, "phone": first, "phoneList": remaining]
            ])
        }
        phones = remaining
    }

    private static func traces(_ root: [String: Any]) -> [TrackNode] {
        let data = json(root["data"])
        let detail = json(data["info"])
        let collections: [Any?] = [
            data["details"], data["traceList"], data["traces"], data["list"],
            detail["traceList"], detail["list"],
            root["details"], root["traceList"], root["traces"], root["list"]
        ]
        for entry in collections {
            guard let rows = entry as? [[String: Any]], !rows.isEmpty else { continue }
            let nodes = rows.compactMap { row -> TrackNode? in
                let value = first(row, ["desc", "info", "context", "statusDesc", "text", "title"])
                guard !value.isEmpty else { return nil }
                return TrackNode(time: first(row, ["time", "date", "updateTime", "traceTime", "displayTime"]), text: value)
            }
            if !nodes.isEmpty { return nodes }
        }
        return []
    }

    static func packages() async throws -> [NativeSyncParcel] {
        let numbers = phones
        let body: [String: Any] = ["info": ["limit": 29, "phones": numbers,
                                                "deletedMailNos": [], "modifiedMailNos": []]]
        let root = try await post("/cpa/express/v2/getList", body: body)
        let data = json(root["data"])
        let info = json(data["info"])
        let list = (data["expressList"] as? [[String: Any]]) ??
            (info["list"] as? [[String: Any]]) ??
            (data["list"] as? [[String: Any]]) ?? []
        var out: [NativeSyncParcel] = []
        for row in list {
            let mail = first(row, ["mailNo", "trackingNumber"])
            guard mail.range(of: #"^[A-Za-z0-9-]{8,40}$"#, options: .regularExpression) != nil else { continue }
            var parcel = NativeSyncParcel(source: "mi")
            parcel.mailNo = mail
            parcel.company = first(row, ["cpName", "shippingName"])
            parcel.code = first(row, ["pickupCode", "code"])
            parcel.title = first(row, ["productName", "itemTitle"])
            parcel.station = first(row, ["stationName", "address"])
            parcel.latest = first(row, ["stateDesc", "statusDesc"])
            parcel.arrived = !parcel.code.isEmpty
            if out.count < 5 {
                let rawPath = first(row, ["detailPath"])
                let path = rawPath.hasPrefix("/cpa/express/") ? rawPath : "/cpa/express/v2/query"
                let b: [String: Any] = ["info": [
                    "phones": numbers,
                    "cpCode": row["cpCode"] ?? NSNull(),
                    "mailNo": mail,
                    "name": row["cpName"] ?? NSNull(),
                    "provider": row["provider"] ?? NSNull(),
                    "stateNum": row["stateNum"] ?? 0,
                    "logisticsUpdateTime": row["logisticsUpdateTime"] ?? NSNull(),
                    "phone": NSNull(), "queryChannel": NSNull(), "channel": "1"
                ]]
                if let detail = try? await post(path, body: b) {
                    parcel.tracks = traces(detail)
                    if let latest = parcel.tracks.first?.text, !latest.isEmpty { parcel.latest = latest }
                }
            }
            out.append(parcel)
        }
        return out
    }
}

private struct XiaomiWebLogin: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        // serviceLogin is an STS endpoint; it can return raw JSON instead
        // of an interactive form. Use Xiaomi's account site for sign-in.
        view.load(URLRequest(url: URL(string: "https://id.mi.com/")!))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
struct XiaomiAccountPage: View {
    @State private var webLogin = false
    @State private var loginError: String?
    @State private var busy = false
    @State private var showBind = false
    @State private var authorized = NativeMiExpress.hasSession
    @State private var boundPhones = NativeMiExpress.phones
    @State private var phone = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var cooldown = 0
    @State private var unbindTarget: String?
    @State private var askRevoke = false
    @State private var notice: String?
    @State private var lastSync = UserDefaults.standard.double(forKey: "native.sync.success.mi")
    private let blue = Color(red: 0.19, green: 0.49, blue: 0.96)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero.padding(.top, 26)
                sectionTitle("取件手机号")
                groupCard {
                    if boundPhones.isEmpty {
                        Text("未绑定手机号")
                            .font(.system(size: 16)).foregroundStyle(.secondary)
                    } else {
                        ForEach(boundPhones, id: \.self) { mobile in
                            HStack {
                                Text(mobile)
                                Spacer()
                                Button {
                                    unbindTarget = mobile
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain).disabled(busy)
                            }
                            Divider()
                        }
                    }
                    if authorized {
                        Button {
                            showBind.toggle()
                            phone = ""; code = ""; codeSent = false
                        } label: {
                            Label("绑定其他手机号", systemImage: "plus.circle")
                                .foregroundStyle(.primary)
                        }.disabled(busy)
                    }
                }
                if showBind {
                    sectionTitle("绑定取件手机号")
                    groupCard {
                        TextField("11 位手机号", text: $phone)
                            .keyboardType(.phonePad)
                            .onChange(of: phone) { _, value in
                                phone = String(value.filter(\.isNumber).prefix(11))
                            }
                        Divider()
                        HStack {
                            TextField("短信验证码", text: $code)
                                .keyboardType(.numberPad)
                                .onChange(of: code) { _, value in
                                    code = String(value.filter(\.isNumber).prefix(8))
                                }
                            Button(cooldown > 0 ? "\(cooldown)s" : "获取验证码", action: sendCode)
                                .disabled(busy || cooldown > 0 || phone.count != 11)
                                .buttonStyle(.bordered).tint(blue)
                        }
                        Divider()
                        HStack {
                            Button("收起") { showBind = false }.buttonStyle(.bordered)
                            Spacer()
                            Button("绑定", action: bindPhone)
                                .buttonStyle(.borderedProminent).tint(blue)
                                .disabled(busy || !codeSent || !(4...8).contains(code.count))
                        }
                    }
                }
                sectionTitle("同步")
                groupCard {
                    HStack(spacing: 11) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(blue).font(.system(size: 20))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("上次同步")
                            Text(lastSync > 0 ? Date(timeIntervalSince1970: lastSync)
                                .formatted(date: .numeric, time: .shortened) : "无成功记录")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(busy ? "同步中…" : "立即同步") {
                            perform {
                                let result = try await NativeParcelSync.run("mi", force: true)
                                lastSync = UserDefaults.standard.double(forKey: "native.sync.success.mi")
                                notice = result.description
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(blue)
                        .disabled(busy || !authorized || boundPhones.isEmpty)
                    }
                }
            }.padding(.horizontal, 18).padding(.bottom, 110)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("小米快递聚合")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $webLogin) {
            NavigationStack {
                XiaomiWebLogin()
                    .navigationTitle("小米账号登录")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("取消") { webLogin = false }
                                .disabled(busy)
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(busy ? "授权中…" : "完成授权") {
                                guard !busy else { return }
                                busy = true
                                Task {
                                    defer { busy = false }
                                    do {
                                        try await NativeMiExpress.exchangeWebLogin()
                                        authorized = NativeMiExpress.hasSession
                                        webLogin = false
                                        notice = "小米账号授权成功"
                                    } catch {
                                        loginError = error.localizedDescription
                                    }
                                }
                            }
                            .disabled(busy)
                        }
                    }
                    .alert("小米授权失败", isPresented: Binding(
                        get: { loginError != nil },
                        set: { if !$0 { loginError = nil } }
                    )) {
                        Button("确定", role: .cancel) { loginError = nil }
                    } message: {
                        Text(loginError ?? "")
                    }
            }
            .interactiveDismissDisabled(busy)
        }
        .confirmationDialog("解除小米授权？", isPresented: $askRevoke, titleVisibility: .visible) {
            Button("解除授权", role: .destructive) {
                NativeMiExpress.clearSession()
                authorized = false
                boundPhones = []
                notice = "已清除小米登录信息"
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("解绑此手机号？",
                            isPresented: Binding(get: { unbindTarget != nil },
                                                 set: { if !$0 { unbindTarget = nil } }),
                            titleVisibility: .visible) {
            Button("解绑", role: .destructive) {
                guard let target = unbindTarget else { return }
                unbindTarget = nil
                perform {
                    try await NativeMiExpress.unbindPhone(target)
                    boundPhones = NativeMiExpress.phones
                    notice = "已解绑手机号"
                }
            }
            Button("取消", role: .cancel) { unbindTarget = nil }
        }
        .alert("账号操作", isPresented: Binding(get: { notice != nil },
                                               set: { if !$0 { notice = nil } })) {
            Button("确定") { notice = nil }
        } message: { Text(notice ?? "") }
    }

    private var hero: some View {
        groupCard {
            HStack(spacing: 14) {
                Image("brand_mi").resizable().scaledToFill().frame(width: 46, height: 46)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("小米快递聚合").font(.system(size: 17, weight: .semibold))
                    Text(authorized ? "已授权" : "未授权")
                        .font(.caption)
                        .foregroundStyle(authorized ? blue : .secondary)
                }
                Spacer()
                Button {
                    if authorized { askRevoke = true } else { webLogin = true }
                } label: {
                    Text(authorized ? "解除授权" : "授权")
                        .foregroundStyle(authorized ? Color.red : .white)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(authorized ? Color.red.opacity(0.18) : blue, in: Capsule())
                }.buttonStyle(.plain)
            }.frame(minHeight: 74)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            .padding(.horizontal, 15).padding(.top, 27).padding(.bottom, 10)
    }
    private func groupCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13, content: content)
            .padding(.horizontal, 18).padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 25, style: .continuous))
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await action() }
            catch { notice = error.localizedDescription }
        }
    }
    private func sendCode() {
        perform {
            try await NativeMiExpress.sendPhoneCode(phone)
            codeSent = true
            cooldown = 60
            notice = "验证码已发送"
            Task {
                while cooldown > 0 {
                    try? await Task.sleep(for: .seconds(1))
                    cooldown = max(0, cooldown - 1)
                }
            }
        }
    }
    private func bindPhone() {
        perform {
            try await NativeMiExpress.bindVerifiedPhone(phone, code: code)
            boundPhones = NativeMiExpress.phones
            showBind = false
            notice = "手机号已绑定"
        }
    }
}
