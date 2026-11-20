import Foundation
import SwiftUI
import CryptoKit
import Security

// Based on the account verification and pickup query flow in
// utils/fengchao.ts and utils/rsa.ts from the supplied Scripting project.
// No automatic cabinet-opening operation is performed.

@MainActor enum NativeFengchao {
    private static let base = "https://consumer.fcbox.com"
    private static let op = "30b2718363204beeae98b7d03a75c3a4"

    private enum SecureStore {
        static func get(_ key: String) -> String {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.muxui.ParcelHelper.fengchao",
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var value: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
                  let data = value as? Data else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        static func set(_ key: String, _ value: String) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.muxui.ParcelHelper.fengchao",
                kSecAttrAccount as String: key
            ]
            SecItemDelete(query as CFDictionary)
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
        static func remove(_ key: String) {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.muxui.ParcelHelper.fengchao",
                kSecAttrAccount as String: key
            ]
            SecItemDelete(q as CFDictionary)
        }
        private static func accountKey(_ name: String, _ accountID: String?) -> String {
            let id = accountID ?? ParcelAccounts.activeID(for: "fengchao")
            return id == ParcelAccounts.legacyID("fengchao") ? name : id + ":" + name
        }
        static func get(_ name: String, accountID: String?) -> String {
            get(accountKey(name, accountID))
        }
        static func set(_ name: String, _ value: String, accountID: String?) {
            set(accountKey(name, accountID), value)
        }
        static func remove(_ name: String, accountID: String?) {
            remove(accountKey(name, accountID))
        }
    }
    private struct Challenge: Codable {
        var pubKey: String
        var timestamp: String
        var ip: String
        var requestCode: String
    }
    static var hasSession: Bool { !SecureStore.get("token").isEmpty }
    static var accountMobile: String { SecureStore.get("mobile") }
    static func accountMobile(for accountID: String?) -> String {
        SecureStore.get("mobile", accountID: accountID)
    }
    static func hasSession(for accountID: String?) -> Bool {
        !SecureStore.get("token", accountID: accountID).isEmpty
    }
    static func logout(for accountID: String?) {
        for key in ["token", "mobile", "pending"] {
            SecureStore.remove(key, accountID: accountID)
        }
    }
    static func logout() {
        for key in ["token", "mobile", "pending"] { SecureStore.remove(key) }
    }

    private static func md5(_ str: String) -> String {
        Insecure.MD5.hash(data: Data(str.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // SPKI SubjectPublicKeyInfo -> PKCS#1 RSAPublicKey for Security.framework.
    private static func rsaEncrypt(_ message: String, base64: String) throws -> String {
        guard let der = Data(base64Encoded: base64) else {
            throw NativeSyncError.badResponse("丰巢公钥格式错误")
        }
        let bytes = [UInt8](der)
        func readTLV(_ offset: Int) -> (Int, Int, Int)? {
            guard offset + 2 <= bytes.count else { return nil }
            var i = offset + 1
            let descriptor = Int(bytes[i]); i += 1
            var length = descriptor
            if descriptor & 0x80 != 0 {
                let count = descriptor & 0x7f
                guard count > 0, count <= 4, i + count <= bytes.count else { return nil }
                length = 0
                for _ in 0..<count { length = length * 256 + Int(bytes[i]); i += 1 }
            }
            guard length >= 0, i + length <= bytes.count else { return nil }
            return (i, i + length, i + length)
        }
        guard let outer = readTLV(0), bytes[0] == 0x30,
              let algorithm = readTLV(outer.0), bytes[outer.0] == 0x30,
              let bitString = readTLV(algorithm.2), bytes[algorithm.2] == 0x03,
              bitString.0 < bitString.1, bytes[bitString.0] == 0 else {
            throw NativeSyncError.badResponse("丰巢返回不支持的公钥编码")
        }
        let pkcs1 = Data(bytes[(bitString.0 + 1)..<bitString.1])
        let properties: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var failure: Unmanaged<CFError>?
        guard let publicKey = SecKeyCreateWithData(pkcs1 as CFData, properties as CFDictionary, &failure) else {
            throw NativeSyncError.badResponse("无法导入丰巢签名公钥")
        }
        guard SecKeyIsAlgorithmSupported(publicKey, .encrypt, .rsaEncryptionPKCS1),
              let encrypted = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionPKCS1,
                                                        Data(message.utf8) as CFData,
                                                        &failure) as Data? else {
            throw NativeSyncError.badResponse("设备不支持丰巢 RSA 签名")
        }
        return encrypted.base64EncodedString()
    }

    private static func call(_ path: String, parameters: [URLQueryItem],
                             method: String = "GET", token: String? = nil) async throws -> ([String: Any], HTTPURLResponse) {
        var url = URLComponents(string: base + path)!
        url.queryItems = parameters
        var req = URLRequest(url: url.url!, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("channel=xiaomi,ip=,os=15,deviceType=2211133C,platform=Android,resolution=1080*2296,versionCode=6007000,versionName=6.7.0,timestamp=\(Int(Date().timeIntervalSince1970 * 1000))",
                     forHTTPHeaderField: "User-Agent")
        if let token { req.setValue(token, forHTTPHeaderField: "Authorization") }
        let (data, res) = try await URLSession.shared.data(for: req)
        guard let http = res as? HTTPURLResponse else {
            throw NativeSyncError.badResponse("丰巢没有返回 HTTP 响应")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeSyncError.badResponse("丰巢接口响应异常（\(http.statusCode)）")
        }
        return (json, http)
    }
    private static func success(_ root: [String: Any]) -> Bool {
        let code = (root["code"] as? NSNumber)?.intValue ?? Int(String(describing: root["code"] ?? "")) ?? -1
        return code == 0 || code == 150100000 || root["success"] as? Bool == true
    }
    private static func field(_ root: [String: Any], _ key: String) -> String {
        if let str = root[key] as? String { return str }
        if let value = root[key] as? NSNumber { return value.stringValue }
        return ""
    }

    static func sendCode(_ phone: String, accountID: String? = nil) async throws {
        let mobile = phone.filter(\.isNumber)
        guard mobile.range(of: #"^1\d{10}$"#, options: .regularExpression) != nil else {
            throw NativeSyncError.badResponse("请输入正确的中国大陆手机号")
        }
        let baseParams: [URLQueryItem] = [
            .init(name: "mobile", value: mobile),
            .init(name: "type", value: "11"),
            .init(name: "opCode", value: op),
            .init(name: "nationCode", value: "86")
        ]
        let (response, _) = try await call("/v1/account/secureCheckMobile", parameters: baseParams)
        let details = response["data"] as? [String: Any] ?? [:]
        guard !details.isEmpty else { throw NativeSyncError.badResponse("丰巢未返回签名参数") }
        if field(details, "needSliderCode") == "true" || details["needSliderCode"] as? Bool == true {
            throw NativeSyncError.verify("请先在丰巢官方 App 完成滑块验证")
        }
        let keyOrder = field(details, "keyOrder").split(separator: ",").map(String.init)
        let publicKey = keyOrder.prefix(5).map { field(details, "key" + $0) }.joined()
        guard publicKey.count > 100 else {
            throw NativeSyncError.badResponse("丰巢签名公钥不完整")
        }
        let challenge = Challenge(pubKey: publicKey, timestamp: field(details, "timestamp"),
                                  ip: field(details, "clientIp"), requestCode: field(details, "requestCode"))
        let signature = "86" + mobile + md5("86\(mobile)11\(challenge.timestamp)\(challenge.ip)\(challenge.requestCode)\(op)")
        let crypted = try rsaEncrypt(signature, base64: publicKey)
        var params = baseParams
        params += [.init(name: "sliderTicket", value: ""),
                   .init(name: "sliderRandstr", value: ""),
                   .init(name: "sign", value: crypted)]
        let (send, _) = try await call("/v1/account/secureSendCode", parameters: params, method: "POST")
        guard success(send) else {
            throw NativeSyncError.unavailable("丰巢发送短信失败：" + field(send, "msg"))
        }
        let data = try JSONEncoder().encode(challenge)
        SecureStore.set("pending", String(data: data, encoding: .utf8) ?? "", accountID: accountID)
        SecureStore.set("mobile", mobile, accountID: accountID)
    }

    static func login(_ phone: String, smsCode: String, accountID: String? = nil) async throws {
        let mobile = phone.filter(\.isNumber)
        let code = smsCode.filter(\.isNumber)
        guard code.count >= 4 && mobile == accountMobile(for: accountID),
              let pendingData = SecureStore.get("pending", accountID: accountID).data(using: .utf8),
              let challenge = try? JSONDecoder().decode(Challenge.self, from: pendingData) else {
            throw NativeSyncError.badResponse("请先获取验证码，并确认手机号一致")
        }
        let signature = "86" + mobile +
            md5("86\(mobile)\(code)01\(challenge.timestamp)\(challenge.ip)\(challenge.requestCode)\(op)")
        let crypted = try rsaEncrypt(signature, base64: challenge.pubKey)
        let params: [URLQueryItem] = [
            .init(name: "mobile", value: mobile),
            .init(name: "verifyCode", value: code),
            .init(name: "channel", value: "0"),
            .init(name: "type", value: "1"),
            .init(name: "weiXinUser", value: ""),
            .init(name: "nationCode", value: "86"),
            .init(name: "opCode", value: op),
            .init(name: "sign", value: crypted)
        ]
        let (result, response) = try await call("/v1/account/secureLoginByPhone",
                                                parameters: params, method: "POST")
        guard let token = response.value(forHTTPHeaderField: "Authorization"), !token.isEmpty else {
            throw NativeSyncError.noLogin("丰巢授权失败：" + field(result, "msg"))
        }
        SecureStore.set("token", token, accountID: accountID)
        SecureStore.remove("pending", accountID: accountID)
    }

    static func packages(accountID: String? = nil) async throws -> [NativeSyncParcel] {
        guard hasSession(for: accountID) else { throw NativeSyncError.noLogin("请先完成丰巢短信授权") }
        let (result, response) = try await call(
            "/post/mobilePick/queryWaitPick",
            parameters: [.init(name: "channelCode", value: "ANDROID_FC_APP")],
            token: SecureStore.get("token", accountID: accountID))
        guard success(result) else {
            if response.statusCode == 401 { logout(for: accountID); throw NativeSyncError.noLogin("丰巢登录已过期") }
            throw NativeSyncError.unavailable("丰巢查询失败：" + field(result, "msg"))
        }
        let data = result["data"] as? [String: Any] ?? [:]
        let cabinets = data["cabinets"] as? [[String: Any]] ?? []
        var rows: [NativeSyncParcel] = []
        for cabinet in cabinets {
            let address = field(cabinet, "address")
            let boxes = cabinet["boxes"] as? [[String: Any]] ?? []
            for box in boxes {
                let list = box["packages"] as? [[String: Any]] ?? []
                for pkg in list {
                    var p = NativeSyncParcel(source: "fengchao")
                    p.accountID = accountID ?? ParcelAccounts.activeID(for: "fengchao")
                    p.mailNo = field(pkg, "expressId")
                    p.code = field(pkg, "code")
                    p.company = field(pkg, "companyName")
                    p.station = address.isEmpty ? "丰巢快递柜" : address
                    p.arrived = !p.code.isEmpty
                    p.latest = "已到柜，待取件"
                    rows.append(p)
                }
            }
        }
        return rows
    }
}

struct FengchaoAccountPage: View {
    @State private var loggedIn = NativeFengchao.hasSession
    @State private var loginPresented = false
    @State private var isSyncing = false
    @State private var revokeConfirmation = false
    @State private var lastSync = UserDefaults.standard.double(forKey: "native.sync.success.fengchao")
    @State private var message: String?
    private let blue = Color(red: 0.19, green: 0.49, blue: 0.96)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                card {
                    HStack(spacing: 14) {
                        Image("brand_fengchao").resizable().scaledToFill()
                            .frame(width: 46, height: 46).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("丰巢").font(.system(size: 17, weight: .semibold))
                            Text(loggedIn ? "已授权" : "未授权")
                                .font(.caption).foregroundStyle(loggedIn ? blue : .secondary)
                        }
                        Spacer()
                        Button {
                            if loggedIn { revokeConfirmation = true }
                            else { loginPresented = true }
                        } label: {
                            Text(loggedIn ? "解除授权" : "授权")
                                .foregroundStyle(loggedIn ? Color.red : .white)
                                .padding(.horizontal, 13).padding(.vertical, 8)
                                .background(loggedIn ? Color.red.opacity(0.18) : blue, in: Capsule())
                        }.buttonStyle(.plain)
                    }.frame(minHeight: 75)
                }.padding(.top, 26)
                sectionTitle("账号")
                card {
                    HStack {
                        Image(systemName: "iphone").foregroundStyle(blue)
                        Text("登录手机号")
                        Spacer()
                        Text(loggedIn ? NativeFengchao.accountMobile : "未登录")
                            .foregroundStyle(.secondary)
                    }
                }
                sectionTitle("同步")
                card {
                    HStack(spacing: 11) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(blue).font(.system(size: 20))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("上次同步")
                            Text(lastSync > 0 ?
                                Date(timeIntervalSince1970: lastSync)
                                    .formatted(date: .numeric, time: .shortened)
                                : "从未同步")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(isSyncing ? "同步中…" : "立即同步") {
                            guard !isSyncing else { return }
                            isSyncing = true
                            Task {
                                defer { isSyncing = false }
                                do {
                                    let result = try await NativeParcelSync.run("fengchao", force: true)
                                    lastSync = UserDefaults.standard.double(forKey: "native.sync.success.fengchao")
                                    message = result.description
                                } catch {
                                    message = "同步失败：" + error.localizedDescription
                                }
                            }
                        }.buttonStyle(.bordered).tint(blue)
                         .disabled(isSyncing || !loggedIn)
                    }
                }
            }.padding(.horizontal, 18).padding(.bottom, 120)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("丰巢")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $loginPresented) {
            NavigationStack {
                FengchaoSMSLoginPage {
                    loggedIn = NativeFengchao.hasSession
                    loginPresented = false
                    message = loggedIn ? "丰巢授权成功" : "未检测到授权状态"
                }
            }
        }
        .confirmationDialog("解除丰巢授权？", isPresented: $revokeConfirmation,
                            titleVisibility: .visible) {
            Button("解除授权", role: .destructive) {
                NativeFengchao.logout()
                loggedIn = false
                message = "丰巢授权已清除"
            }
            Button("取消", role: .cancel) {}
        }
        .alert("丰巢", isPresented: Binding(get: { message != nil },
                                          set: { if !$0 { message = nil } })) {
            Button("确定") { message = nil }
        } message: { Text(message ?? "") }
    }
    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            .padding(.horizontal, 15).padding(.top, 27).padding(.bottom, 10)
    }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13, content: content)
            .padding(.horizontal, 18).padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 25, style: .continuous))
    }
}

struct FengchaoSMSLoginPage: View {
    var accountID: String? = nil
    let onAuthorized: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var phone = ""
    @State private var code = ""
    @State private var cooldown = 0
    @State private var busy = false
    @State private var message: String?
    private let blue = Color(red: 0.19, green: 0.49, blue: 0.96)
    private var validPhone: Bool { phone.range(of: #"^1\d{10}$"#, options: .regularExpression) != nil }
    var body: some View {
        Form {
            Section("手机号登录") {
                HStack {
                    Text("手机号").frame(width: 65, alignment: .leading)
                    TextField("11 位手机号", text: $phone)
                        .keyboardType(.phonePad)
                        .onChange(of: phone) { _, value in
                            phone = String(value.filter(\.isNumber).prefix(11))
                        }
                }
                HStack {
                    Text("验证码").frame(width: 65, alignment: .leading)
                    TextField("短信验证码", text: $code)
                        .keyboardType(.numberPad)
                        .onChange(of: code) { _, value in
                            code = String(value.filter(\.isNumber).prefix(8))
                        }
                    Button(cooldown > 0 ? "\(cooldown)s" : "获取验证码", action: send)
                        .buttonStyle(.bordered).tint(blue)
                        .disabled(busy || cooldown > 0 || !validPhone)
                }
                Button(busy ? "处理中…" : "登录", action: login)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !validPhone || !(4...8).contains(code.count))
            }
        }
        .navigationTitle("授权丰巢")
        .onAppear { phone = NativeFengchao.accountMobile(for: accountID) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("取消") { dismiss() }
            }
        }
        .alert("丰巢登录", isPresented: Binding(get: { message != nil },
                                             set: { if !$0 { message = nil } })) {
            Button("确定") { message = nil }
        } message: { Text(message ?? "") }
    }
    private func send() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await NativeFengchao.sendCode(phone, accountID: accountID)
                message = "验证码已发送"
                cooldown = 60
                Task {
                    while cooldown > 0 {
                        try? await Task.sleep(for: .seconds(1))
                        cooldown = max(0, cooldown - 1)
                    }
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }
    private func login() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await NativeFengchao.login(phone, smsCode: code, accountID: accountID)
                onAuthorized()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
