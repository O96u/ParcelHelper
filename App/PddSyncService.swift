import Foundation
import WebKit

@MainActor extension NativeParcelSync {
    struct PddMobile: Identifiable {
        let id: String
        let masked: String
        let alias: String
        let commonlyUsed: Bool
    }
    static func maskedPddMobile(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter(\.isNumber)
        if digits.count == 11, digits.hasPrefix("1") {
            return String(digits.prefix(3)) + "****" + String(digits.suffix(4))
        }
        // The official API sometimes supplies an already-masked mobile.
        if trimmed.contains("*") || trimmed.contains("＊") {
            return String(trimmed.prefix(32))
        }
        return "已绑定手机号"
    }

    static func pddBoundMobiles(accountID: String? = nil) async throws -> [PddMobile] {
        // Read-only account detail endpoint. Binding/unbinding and SMS
        // verification take place exclusively in the official H5 screen.
        let response = try await pddJSON(
            "/api/apoc/express/detail", body: ["entry_source": 17],
            accountID: accountID)
        let result = SyncJSON.dict(response["result"])
        let data = SyncJSON.dict(response["data"])
        let layers = [response, result, data,
                      SyncJSON.dict(result["data"]),
                      SyncJSON.dict(data["data"])]
        let keys = ["new_binding_list", "newBindingList", "binding_list",
                    "bindingList", "mobile_list", "mobileList"]
        var records: [[String: Any]]?
        for layer in layers {
            for key in keys {
                if let list = layer[key] as? [[String: Any]] {
                    records = list
                    break
                }
            }
            if records != nil { break }
        }
        guard let records else {
            throw NativeSyncError.badResponse("拼多多未返回可识别的手机号列表")
        }
        return records.compactMap { record -> PddMobile? in
            let id = SyncJSON.first(record, ["mobile_id", "mobileId", "id"])
            let rawPhone = SyncJSON.first(record, ["mock_mobile", "mobile_des",
                                                   "mobile_desc", "masked_mobile", "mobile"])
            guard !id.isEmpty || !rawPhone.isEmpty else { return nil }
            let status = SyncJSON.first(record, ["commonly_used", "commonlyUsed",
                                                  "is_default", "isDefault"]).lowercased()
            return PddMobile(id: id.isEmpty ? rawPhone : id,
                             masked: maskedPddMobile(rawPhone),
                             alias: SyncJSON.first(record, ["alias", "remark", "note"]),
                             commonlyUsed: status == "true" || status == "1")
        }
    }

    static func pddJSON(_ path: String, body: [String: Any]? = nil, referer: String? = nil, accountID: String? = nil) async throws -> [String: Any] {
        guard PddAccountProtection.webAccessAllowed else {
            throw NativeSyncError.unavailable("已关闭拼多多网页访问，以免影响官方 App 登录。")
        }
        let selected = accountID ?? ParcelAccounts.activeID(for: "pdd")
        // Pinduoduo serves its H5 on both yangkeduo.com and pinduoduo.net.
        // A newly authorized small account may only have cookies from the
        // latter. Keep cookies strictly within the selected WebKit profile.
        let oldCookies = await WebCookieRequest.cookies(domain: "yangkeduo.com",
                                                         accountID: selected)
        let modernCookies = await WebCookieRequest.cookies(domain: "pinduoduo.net",
                                                            accountID: selected)
        var cookieNames = Set<String>()
        let cookies = (modernCookies + oldCookies).filter {
            cookieNames.insert($0.name).inserted
        }
        var headers: [String: String] = [
            "Referer": referer ?? "https://m.pinduoduo.net/mdkd/package?pr_page_from=scheme",
            "Content-Type": "application/json;charset=UTF-8",
            "Accept": "application/json",
            "User-Agent": "Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 Version/17.5 Mobile/15E148 Safari/604.1"
        ]
        if !cookies.isEmpty {
            headers["Cookie"] = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
        let token = cookies.first(where: { $0.name == "PDDAccessToken" })?.value ??
                    PddSessionVault.token(for: selected)
        guard !token.isEmpty || !cookies.isEmpty else {
            throw NativeSyncError.noLogin("未找到拼多多有效网页登录会话")
        }
        if !token.isEmpty { headers["AccessToken"] = token }
        let requestBody = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        let url = URL(string: "https://api.pinduoduo.com" + path)!
        let (json, _) = try await WebCookieRequest.request(url, method: body == nil ? "GET" : "POST",
                                                          headers: headers, body: requestBody)
        let code = SyncJSON.str(json["error_code"])
        if code == "40001" { throw NativeSyncError.noLogin("拼多多登录已失效，请重新授权") }
        if code == "54001" { throw NativeSyncError.verify("拼多多要求安全验证，请在官方 App 中完成验证后重试") }
        if !code.isEmpty && code != "0" && code != "1000000" {
            throw NativeSyncError.unavailable(SyncJSON.str(json["error_msg"]).isEmpty ?
                "拼多多接口错误 \(code)" : SyncJSON.str(json["error_msg"]))
        }
        return json
    }

    static func pddPackages(accountID: String) async throws -> [NativeSyncParcel] {
        let json = try await pddJSON("/api/express_trackbox/station/package",
                                     body: ["entry_source": "9", "dynamic_qrcode": false,
                                            "install_token": "", "dp_source": "", "redirect_app": false], accountID: accountID)
        let root = SyncJSON.dict(json["result"])
        let groups = SyncJSON.list(root["combine_list"])
        var output: [NativeSyncParcel] = []
        for group in groups {
            let station = SyncJSON.first(group, ["company_name", "station_name"])
            let list = SyncJSON.list(group["combine_track_list"]).isEmpty ?
                       SyncJSON.list(group["list"]) : SyncJSON.list(group["combine_track_list"])
            for item in list {
                var p = NativeSyncParcel(source: "pdd")
                p.accountID = accountID
                p.mailNo = SyncJSON.first(item, ["tracking_number", "mail_no"])
                p.company = SyncJSON.first(item, ["shipping_name", "shipping_company",
                                                   "shipping_company_name", "express_company_name"])
                if p.company.isEmpty {
                    p.company = SyncJSON.first(SyncJSON.dict(item["shipping"]),
                                                ["shipping_name", "shipping_company_name", "name"])
                }
                p.station = station
                p.code = SyncJSON.pickup(SyncJSON.str(item["pick_code"]))
                p.arrived = !p.code.isEmpty
                if SyncJSON.isMail(p.mailNo) {
                    // Detailed route is fetched only for a small, bounded batch.
                    if output.count < 12 {
                        do {
                            let jump = SyncJSON.str(item["jump_url"])
                            let params = URLComponents(string: jump)?.queryItems ?? []
                            let order = params.first(where: { $0.name == "order_sn" })?.value ?? ""
                            let sourceType = params.first(where: { $0.name == "source_type" })?.value ?? SyncJSON.str(item["source_type"])
                            let (name, tracks, eta) = try await pddTrack(p.mailNo, accountID: accountID, orderSN: order, sourceType: sourceType)
                            if !name.isEmpty { p.company = name }
                            p.tracks = tracks
                            p.latest = tracks.first?.text ?? ""
                            p.eta = eta
                        } catch {
                            // An individual shipment must not abort other packages.
                            ParcelRunLog.record("拼多多", "单件物流查询未完成，保留驿站包裹", level: "警告")
                        }
                    }
                }
                output.append(p)
            }
        }
        return output
    }

    static func pddTrack(_ mail: String, accountID: String? = nil, orderSN: String = "", sourceType: String = "") async throws -> (String, [TrackNode], String) {
        guard var parts = URLComponents(string: "https://api.pinduoduo.com/api/express/shipping/track") else {
            throw NativeSyncError.badResponse("运单接口不可用")
        }
        parts.queryItems = [URLQueryItem(name: "tracking_number", value: mail),
                            URLQueryItem(name: "entry_source", value: "9")]
        // Same request error handling as station API, but query is GET.
        let path = "/api/express/shipping/track?" + (parts.percentEncodedQuery ?? "")
        var response: [String: Any]
        if !orderSN.isEmpty {
            var body: [String: Any] = ["order_sn": orderSN, "entry_source": NSNull(), "query_type": 1]
            if let type = Int(sourceType), type != 0 { body["source_type"] = type } else { body["source_type"] = NSNull() }
            do {
                response = try await pddJSON("/api/express/dsd/trackbox/shipping/track", body: body, accountID: accountID)
            } catch let error as NativeSyncError {
                switch error {
                case .noLogin, .verify: throw error
                default: response = [:]
                }
            }
            if SyncJSON.list(SyncJSON.dict(response["shipping"])["traces"]).isEmpty {
                try Task.checkCancellation()
                response = try await pddJSON(path, accountID: accountID)
            }
        } else {
            response = try await pddJSON(path, accountID: accountID)
        }
        let shipping = SyncJSON.dict(response["shipping"])
        let nodes = SyncJSON.list(shipping["traces"]).compactMap { o -> TrackNode? in
            let text = SyncJSON.first(o, ["info", "desc"])
            guard !text.isEmpty else { return nil }
            return TrackNode(time: SyncJSON.str(o["time"]), text: text)
        }
        let forecast = SyncJSON.dict(shipping["time_forecast"])
        return (SyncJSON.str(shipping["shipping_name"]), nodes,
                SyncJSON.str(forecast["time_forecast_desc"]))
    }

}
