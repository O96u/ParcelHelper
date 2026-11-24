import Foundation
import WebKit
import CryptoKit

@MainActor extension NativeParcelSync {
    static func mtop(_ api: String, data: [String: Any], accountID: String? = nil) async throws -> [String: Any] {
        let params = try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
        guard let json = String(data: params, encoding: .utf8) else {
            throw NativeSyncError.badResponse("请求参数编码失败")
        }
        let selected = accountID ?? ParcelAccounts.activeID(for: "taobao")
        let gateway = URL(string: "https://h5api.m.taobao.com/h5/\(api.lowercased())/1.0/")!
        var cookies = await WebCookieRequest.mtopCookies(for: gateway, accountID: selected)
        guard !cookies.isEmpty else {
            throw NativeSyncError.noLogin("未检测到当前账号的淘宝网页会话")
        }
        var lastFailure = "接口请求失败"
        // Session errors may mean a stale MTOP gateway token rather than a
        // revoked account login. Rotate the gateway token before asking the
        // user to visit account authorization. Bound total attempts to three.
        for attempt in 0..<3 {
            let token = cookies.first(where: { $0.name == "_m_h5_tk" })?.value
                .components(separatedBy: "_").first ?? ""
            let time = String(Int64(Date().timeIntervalSince1970 * 1000))
            let signed = "\(token)&\(time)&12574478&\(json)"
            let hash = Insecure.MD5.hash(data: Data(signed.utf8))
                .map { String(format: "%02x", $0) }.joined()
            var components = URLComponents(url: gateway, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                .init(name: "jsv", value: "2.7.4"),
                .init(name: "appKey", value: "12574478"),
                .init(name: "t", value: time),
                .init(name: "sign", value: hash),
                .init(name: "api", value: api),
                .init(name: "v", value: "1.0"),
                .init(name: "type", value: "originaljson"),
                .init(name: "dataType", value: "json"),
                .init(name: "data", value: json)
            ]
            var headers = try WebCookieRequest.mtopHeaders(cookies: cookies)
            headers["Referer"] = "https://h5.m.taobao.com/"
            let (result, response) = try await WebCookieRequest.request(components.url!, headers: headers)
            let returned = (result["ret"] as? [String])?.first ?? ""
            if returned.hasPrefix("SUCCESS") { return result }
            lastFailure = returned.isEmpty ? "MTOP 业务返回失败" : returned
            let failure = returned.uppercased()
            let recoverable = ["TOKEN_EMPTY", "TOKEN_EXPIRED", "TOKEN_EXOIRED",
                               "ILLEGAL_ACCESS", "SESSION_EXPIRED"]
                .contains(where: { failure.contains($0) })
            guard attempt < 2 && recoverable else { break }

            // Persist gateway-issued replacement cookies back into the
            // SAME isolated WebKit store; URLSession has another cookie jar.
            let headerFields = response.allHeaderFields.reduce(into: [String: String]()) { out, item in
                out[String(describing: item.key)] = String(describing: item.value)
            }
            let rotated = HTTPCookie.cookies(withResponseHeaderFields: headerFields,
                                              for: gateway)
            for cookie in rotated {
                let domain = cookie.domain.lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                guard domain == "taobao.com" || domain.hasSuffix(".taobao.com") else { continue }
                await WebCookieRequest.cookieStore(accountID: selected).setCookie(cookie)
            }
            cookies = await WebCookieRequest.mtopCookies(for: gateway, accountID: selected)
            let newer = cookies.first(where: { $0.name == "_m_h5_tk" })?
                .value.components(separatedBy: "_").first ?? ""
            if newer.isEmpty || newer == token {
                // Bootstrap a fresh H5 token without ever displaying a login
                // form. Never clear the user's persistent authorization data.
                await CainiaoMtopTokenRefresh(accountID: selected)
                    .run(gatewayURL: components.url!)
                cookies = await WebCookieRequest.mtopCookies(for: gateway, accountID: selected)
            }
        }
        if lastFailure.uppercased().contains("SESSION_EXPIRED") {
            throw NativeSyncError.unavailable(
                "菜鸟接口返回 SESSION_EXPIRED：网页 Cookie 仍在，但接口会话已过期且自动续期未成功。可在「账号授权 → 菜鸟」重新验证；原有包裹和 Cookie 已保留")
        }
        throw NativeSyncError.unavailable("菜鸟 MTOP 请求失败：\(lastFailure)")
    }

    static func cainiaoPackages(accountID: String) async throws -> [NativeSyncParcel] {
        var out: [NativeSyncParcel] = []
        let api = "mtop.cainiao.lpc.packageservice.queryPdsPackageDataList"
        var seen = Set<String>()
        for page in 1...10 {
            try Task.checkCancellation()
            let json: [String: Any]
            do {
                json = try await mtop(api, data: [
                "pageSize": 50, "currentPage": page,
                "needTemporality": false,
                "needDynInfo": "{'needFindTemporality':true,'needAppointment':true}"
                ], accountID: accountID)
            } catch {
                guard !out.isEmpty, !Task.isCancelled else { throw error }
                ParcelRunLog.record("菜鸟", "后续分页未完成，保留已获取的包裹", level: "警告")
                break
            }
            let outer = SyncJSON.dict(json["data"])
            let body = SyncJSON.dict(outer["data"]).isEmpty ? outer : SyncJSON.dict(outer["data"])
            let entries = SyncJSON.list(body["packages"])
            for pkg in entries {
                let mail = SyncJSON.first(pkg, ["mailNo", "mail_no"])
                guard SyncJSON.isMail(mail), seen.insert(mail.uppercased()).inserted else { continue }
                let station = SyncJSON.dict(pkg["packageStation"])
                let feature = SyncJSON.dict(pkg["feature"])
                let items = SyncJSON.list(pkg["packageItem"])
                let firstItem = items.first ?? [:]
                var parcel = NativeSyncParcel(source: "cainiao")
                parcel.accountID = accountID
                parcel.mailNo = mail
                let carrier = SyncJSON.dict(pkg["cpInfo"])
                let logistics = SyncJSON.dict(pkg["logisticsCompany"])
                parcel.company = SyncJSON.first(pkg, ["cpName", "cp_name", "companyName",
                    "cpCode", "logisticsCompanyName", "expressCompanyName", "expressName"])
                if parcel.company.isEmpty {
                    parcel.company = SyncJSON.first(carrier, ["cpName", "companyName", "name", "cpCode"])
                }
                if parcel.company.isEmpty {
                    parcel.company = SyncJSON.first(logistics, ["name", "companyName", "cpName"])
                }
                parcel.title = SyncJSON.first(feature, ["recommendPackageTitle", "recommend_package_title"])
                if parcel.title.isEmpty { parcel.title = SyncJSON.first(firstItem, ["itemTitle", "item_title"]) }
                parcel.station = SyncJSON.first(station, ["pointName", "point_name", "stationName", "name"])
                parcel.code = SyncJSON.pickup(SyncJSON.first(station, ["authCode", "auth_code", "showPickupCode", "pickUpCode", "pickupCode"]))
                if parcel.code.isEmpty {
                    parcel.code = SyncJSON.pickup(SyncJSON.first(feature, ["stationOrderPickUpCode", "station_order_pick_up_code"]))
                }
                let status = SyncJSON.first(pkg, ["statusDesc", "status", "packageStatus"])
                let upperStatus = status.uppercased()
                if ["CANCEL", "REJECT", "RETURN", "LOST"].contains(upperStatus) &&
                   parcel.code.isEmpty { continue }
                // SIGN is delivered/picked, not an in-transit parcel. Propagate
                // it to the merge layer so an existing parcel is marked picked,
                // but do not insert historical signed parcels as new packages.
                parcel.latest = upperStatus == "SIGN" ? "已签收" : status
                parcel.arrived = !parcel.code.isEmpty
                out.append(parcel)
            }
            let total = Int(SyncJSON.str(body["totalPage"])) ?? 1
            if page >= total || entries.isEmpty { break }
        }
        let candidates = out.indices.filter { index in
            let status = out[index].latest.uppercased()
            return !["SIGN", "已签收", "已取件"].contains(status) ||
                ParcelStore.shared.snapshot.parcels.contains { $0.mailNo == out[index].mailNo && !$0.isDone && !$0.isSigned }
        }
        let key = "native.cainiao.trackCursor." + accountID
        if !candidates.isEmpty {
            let cursor = max(0, UserDefaults.standard.integer(forKey: key)) % candidates.count
            let rotated = Array(candidates.dropFirst(cursor)) + Array(candidates.prefix(cursor))
            var attempted = 0
            for index in rotated.prefix(4) {
                try Task.checkCancellation()
                attempted += 1
                if let detail = await cainiaoTrack(out[index].mailNo, accountID: accountID) {
                    if !detail.company.isEmpty { out[index].company = detail.company }
                    if !detail.nodes.isEmpty {
                        out[index].tracks = detail.nodes
                        if out[index].latest != "已签收" {
                            out[index].latest = detail.status.isEmpty ? (detail.nodes.first?.text ?? out[index].latest) : detail.status
                        }
                    }
                }
            }
            UserDefaults.standard.set((cursor + attempted) % candidates.count, forKey: key)
        }
        return out
    }

    // Original utils/cainiao.ts: trackMailNo() with a PID query first, falling
    // back to carrier detection + queryalltrace. A failed trace lookup does not
    // invalidate the rest of the order-list import.
    static func cainiaoTrack(
        _ mail: String, accountID: String? = nil
    ) async -> (company: String, nodes: [TrackNode], status: String)? {
        func parse(_ result: [String: Any]) -> (company: String, nodes: [TrackNode], status: String) {
            let data = SyncJSON.dict(result["data"])
            let payload = SyncJSON.dict(data["data"]).isEmpty ? data : SyncJSON.dict(data["data"])
            var containers: [[String: Any]] = []
            if let first = SyncJSON.list(payload["result"]).first { containers.append(first) }
            let resultObject = SyncJSON.dict(payload["result"])
            if !resultObject.isEmpty { containers.append(resultObject) }
            containers.append(payload)
            containers.append(data)
            let company = containers.lazy.map {
                SyncJSON.first($0, ["cpName", "cp_name", "companyName",
                                    "logisticsCompanyName", "cpCode"])
            }.first(where: { !$0.isEmpty }) ?? ""
            var nodes: [TrackNode] = []
            for container in containers {
                for key in ["detailList", "traceList", "transitList", "traces", "routeList"] {
                    let list = SyncJSON.list(container[key])
                    let found = list.compactMap { item -> TrackNode? in
                        let text = SyncJSON.first(item, ["standerdDesc", "standardDesc",
                            "statusDesc", "desc", "content", "description", "action", "status"])
                        guard !text.isEmpty else { return nil }
                        return TrackNode(time: SyncJSON.first(item,
                            ["time", "ocurrTimeStr", "occurTimeStr", "gmtCreate", "statusTime"]),
                            text: text)
                    }
                    if !found.isEmpty {
                        nodes = Array(found.prefix(60))
                        break
                    }
                }
                if !nodes.isEmpty { break }
            }
            // SIGN from the official Cainiao package-detail response means
            // signed/delivered, not necessarily collected by the recipient.
            let raw = containers.lazy.map {
                SyncJSON.first($0, ["statusDesc", "packageStatus", "status",
                                    "latestStatus", "logisticsStatus"])
            }.first(where: { !$0.isEmpty }) ?? ""
            let normalized = raw.uppercased()
            let status: String
            if normalized == "SIGN" { status = "已签收" }
            else if Parcel.confirmsRecipientPickup(raw) ||
                    ["已签收", "签收成功", "待取件", "到站", "已妥投"]
                        .contains(where: { raw.contains($0) }) {
                status = raw
            } else {
                status = ""
            }
            return (company, nodes, status)
        }

        // An HTTP/MTOP SUCCESS with no trace nodes is still an empty result.
        // Fall back to the receiver trace API in that case as well.
        let primary = try? await mtop(
            "mtop.cainiao.logisticsdetail.packages.pid.orderCode.mailNo.get",
            data: ["mailNo": mail], accountID: accountID)
        let first = primary.map(parse)
        if let first, !first.nodes.isEmpty { return first }

        var companyCode = ""
        if let cp = try? await mtop("mtop.taobao.logisticsDetailTraceQueryService.queryCpByMailNo",
                                      data: ["mailNo": mail], accountID: accountID) {
            let data = SyncJSON.dict(cp["data"])
            let list = SyncJSON.list(data["result"])
            companyCode = SyncJSON.first(list.first ?? [:], ["tpCode", "cpCode"])
        }
        let alternate = try? await mtop(
            "mtop.taobao.logisticstracedetailservice.queryalltrace",
            data: [
                "mailNo": mail, "cpCode": companyCode, "actor": "RECEIVER",
                "isShowAllDetail": true, "isShowExceptionDetail": true,
                "isShowExpressMan": true, "isShowConsignDetail": true,
                "isShowDeliveryProgress": true, "isShowStationProxyOrder": true,
                "isShowServiceProvider": true, "isStandard": true,
                "isUnique": true, "ignoreInvalidNode": true
            ], accountID: accountID)
        if let alternate {
            let second = parse(alternate)
            if !second.nodes.isEmpty || !second.status.isEmpty {
                return (second.company.isEmpty ? first?.company ?? "" : second.company,
                        second.nodes, second.status.isEmpty ? first?.status ?? "" : second.status)
            }
        }
        if let first, !first.status.isEmpty || !first.company.isEmpty { return first }
        return nil
    }

}
