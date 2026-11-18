import Foundation

/// Local parser for text manually copied from Douyin Shop's order/logistics UI.
/// No login, cookies, private API, or background scraping is involved.
struct DouyinImportResult {
    var title = ""
    var orderID = ""
    var trackingNumber = ""
    var company = ""
    var pickupCode = ""
    var station = ""
    var latestStatus = ""
    var recipient = ""
    var rawText = ""

    var isValid: Bool { !trackingNumber.isEmpty || !pickupCode.isEmpty }

    func asParcel() -> Parcel {
        var p = Parcel()
        p.source = "douyin"
        p.srcApp = SourceApp(id: "douyin", name: "抖音商城")
        p.userTitle = title.isEmpty ? "抖音商城包裹" : title
        p.orderId = orderID.isEmpty ? nil : orderID
        p.mailNo = trackingNumber.isEmpty ? nil : trackingNumber
        p.trackCompany = company.isEmpty ? nil : company
        p.code = pickupCode
        p.courierStationName = station
        p.trackLatest = latestStatus.isEmpty ? nil : latestStatus
        p.smsContent = rawText
        if !pickupCode.isEmpty || latestStatus.contains("待取") || latestStatus.contains("已入柜") || latestStatus.contains("已到站") {
            p.arrivedAt = Date().timeIntervalSince1970 * 1000
        }
        return p
    }
}

enum DouyinTextParser {
    private static func match(_ text: String, patterns: [String]) -> String {
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
                  let hit = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  hit.numberOfRanges > 1,
                  let range = Range(hit.range(at: 1), in: text) else { continue }
            let v = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { return v }
        }
        return ""
    }

    static func parse(_ input: String) -> DouyinImportResult {
        let text = input.replacingOccurrences(of: "\r\n", with: "\n")
        var r = DouyinImportResult()
        r.rawText = String(text.prefix(12000))
        r.trackingNumber = match(text, patterns: [
            #"(?:快递单号|物流单号|运单号码|运单号|快递编号|物流编号|物流运单号)\s*[：:\s#]*([A-Za-z0-9][A-Za-z0-9-]{7,31})"#,
            #"(?:复制单号|复制运单号)\s*[：:\s]*([A-Za-z0-9][A-Za-z0-9-]{7,31})"#
        ])
        // Do not blindly treat an arbitrary long digit sequence as a tracking number:
        // it might be an order ID, address, or phone number.
        r.orderID = match(text, patterns: [#"(?:订单编号|订单号|订单ID|订单编号为)\s*[：:\s#]*([A-Za-z0-9-]{6,40})"#])
        r.pickupCode = match(text, patterns: [
            #"(?:取件码|提货码|取货码|开柜码|取件凭证)\s*[：:\s]*([A-Za-z0-9-]{3,16})"#,
            #"(?:凭码取件|凭此码取件)\s*[：:\s]*([A-Za-z0-9-]{3,16})"#
        ])
        r.station = match(text, patterns: [
            #"(?:取件地址|代收点|自提点|驿站名称|存放地点|取件地点)\s*[：:\s]*([^\n，。；;]{2,60})"#,
            #"([^\n，。；;]{2,32}(?:菜鸟驿站|快递驿站|丰巢快递柜|快递柜))"#
        ])
        r.company = match(text, patterns: [
            #"(?:物流公司|快递公司|承运公司|承运商)\s*[：:\s]*([^\n，。；;]{2,24})"#
        ])
        if r.company.isEmpty {
            for company in ["顺丰速运", "顺丰", "中通快递", "中通", "圆通速递", "圆通", "申通快递", "申通", "韵达快递", "韵达", "极兔速递", "极兔", "京东物流", "京东快递", "邮政EMS", "EMS", "中国邮政", "德邦快递", "德邦"] {
                if text.contains(company) { r.company = company; break }
            }
        }
        r.title = match(text, patterns: [
            #"(?:商品名称|商品标题|商品信息|商品)\s*[：:\s]*([^\n]{2,75})"#
        ])
        r.latestStatus = match(text, patterns: [
            #"(?:最新物流|最新状态|物流状态|物流信息|运输状态)\s*[：:\s]*([^\n]{2,100})"#
        ])
        if r.latestStatus.isEmpty {
            for line in text.split(separator: "\n") {
                let s = String(line).trimmingCharacters(in: .whitespaces)
                if s.count <= 120 && ["已签收", "派送中", "运输中", "已揽收", "待取件", "已入柜", "已到站", "已送达"].contains(where: s.contains) {
                    r.latestStatus = s
                    break
                }
            }
        }
        return r
    }
}
