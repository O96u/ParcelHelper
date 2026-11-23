import Foundation

struct ParsedSMS {
    var code: String = ""
    var trackingNumber: String = ""
    var station: String = ""
    var address: String = ""
    var company: String = ""
}

/// Parses explicitly supplied delivery messages on-device. No OCR/network call.
enum SMSParser {
    static func capture(_ text: String, _ pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return "" }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only high-confidence waybill styles trigger a pasteboard suggestion.
    /// Carrier API identifiers (ZTO/STO/HTKY/jtexpress/yuantong etc.)
    /// are NOT guaranteed prefixes of actual tracking numbers.
    /// Unknown/numeric-only numbers require explicit "运单号" context.
    private static let waybillPattern =
        #"(?:SF[0-9]{10,15}|JD[A-Z]{0,2}[0-9]{10,15}|JT[0-9]{10,15}|YT[0-9]{10,15}|E[A-Z][0-9]{9}CN)"#
    static func isCarrierTrackingNumber(_ value: String) -> Bool {
        value.range(of: "^" + waybillPattern + "$",
                    options: [.caseInsensitive, .regularExpression]) != nil
    }

    static func parse(_ original: String) -> ParsedSMS {
        let text = (original.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? original)
            .replacingOccurrences(of: "－", with: "-")
            .replacingOccurrences(of: "—", with: "-")
        var result = ParsedSMS()

        // Full pickup identifiers may have multiple dashes: 10-6-15-6153.
        let codePatterns = [
            #"(?:取件码|取货码|提货码|取件密码|取件凭证|开柜码|自提码)\s*(?:为|是)?\s*[:：]?\s*([A-Za-z0-9]+(?:-[A-Za-z0-9]+){0,5})"#,
            #"(?:请凭|凭码|凭)\s*[:：]?\s*([A-Za-z0-9]+(?:-[A-Za-z0-9]+){0,5})\s*(?:到|前往|取件|领取)"#,
            #"(?:柜号|格口号|格口)\s*[:：]?\s*([0-9]{3,8})"#
        ]
        for pattern in codePatterns {
            let code = capture(text, pattern)
            let normalized = code.trimmingCharacters(in: CharacterSet(charactersIn: "，。；,; "))
            if (3...24).contains(normalized.count),
               normalized.range(of: #"^[A-Za-z0-9]+(?:-[A-Za-z0-9]+){0,5}$"#,
                                options: .regularExpression) != nil {
                result.code = normalized
                break
            }
        }

        for pattern in [
            #"(?:运单号|快递单号|物流单号|包裹单号|单号)\s*[:：]?\s*([A-Za-z0-9-]{8,40})"#,
            #"(?:运单|物流)\s*号码\s*[:：]?\s*([A-Za-z0-9-]{8,40})"#,
            // Recognize a full, high-confidence waybill token; never guess
            // a company from an API code or a random alphanumeric string.
            "(?:^|[^A-Za-z0-9])(" + waybillPattern + ")(?![A-Za-z0-9])"
        ] {
            let value = capture(text, pattern)
            if !value.isEmpty {
                result.trackingNumber = value.uppercased()
                break
            }
        }

        // Only explicit courier references identify the actual shipper.
        // "兔喜生活" and "妈妈驿站" are collection-point brands, not carriers.
        let carriers: [(String, String)] = [
            ("中通", "中通快递"), ("圆通", "圆通快递"), ("申通", "申通快递"),
            ("韵达", "韵达快递"), ("顺丰", "顺丰速运"), ("极兔", "极兔速递"),
            ("京东快递", "京东快递"), ("京东物流", "京东物流"),
            ("德邦", "德邦快递"), ("邮政", "中国邮政"),
            ("EMS", "中国邮政EMS"), ("百世", "百世快递")
        ]
        for (keyword, label) in carriers where text.localizedCaseInsensitiveContains(keyword) {
            result.company = label
            break
        }
        if result.company.isEmpty && isCarrierTrackingNumber(result.trackingNumber) {
            let mail = result.trackingNumber
            if mail.hasPrefix("SF") { result.company = "顺丰速运" }
            else if mail.hasPrefix("JD") { result.company = "京东快递" }
            else if mail.hasPrefix("JT") { result.company = "极兔速递" }
            else if mail.hasPrefix("YT") { result.company = "圆通速递" }
            else if mail.hasPrefix("E") && mail.hasSuffix("CN") {
                result.company = "中国邮政EMS"
            }
        }

        // Address is not interchangeable with the pickup station name.
        result.address = capture(text, #"地址\s*[:：]\s*([^，,。；;\n]{4,120})"#)
            .trimmingCharacters(in: CharacterSet(charactersIn: " 。；;"))

        let stationPatterns = [
            // 【中通快递】请凭10-3-2323到成都市上东一号全又佳便利店取件
            #"(?:请凭|凭码|凭)\s*[A-Za-z0-9-]{3,24}\s*(?:到|前往)\s*([^，,。；;\n]{2,65}?)(?:取件|领取包裹|领取)"#,
            // 【兔喜生活】包裹已到达上东一号一期14栋店，取件码为...
            #"(?:包裹|快递)?\s*已(?:到达|送达|存入|放入|存放在)\s*([^，,。；;\n]{3,65})"#,
            // 【妈妈驿站】...，已到上东三期建设银行斜对面圆通快递
            #"已到\s*([^，,。；;\n]{3,65})"#,
            #"(?:(?:请到|前往|存放于|存放至|取件地点|取件地址|取件点)\s*[:：]?\s*)([^，,。；;\n]{3,65})"#,
            #"([\p{Han}A-Za-z0-9·（）()\-]{3,50}(?:驿站|快递柜|自提点|代收点|快递超市|便利店))"#
        ]
        for pattern in stationPatterns {
            var name = capture(text, pattern)
            // Remove trailing instructions rather than changing the location.
            for suffix in ["，请", "请及时", "请尽快", "取件码", "取货码", "地址:", "地址："] {
                if let range = name.range(of: suffix) { name = String(name[..<range.lowerBound]) }
            }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: " ，,。；;"))
            let invalid = ["其他驿站", "快递驿站", "分拨中心", "转运中心",
                           "集散中心", "运转中心", "物流中心"]
            if name.count >= 3 && name.count <= 65 &&
               !invalid.contains(where: name.contains) &&
               !(name == result.address) {
                result.station = name
                break
            }
        }
        return result
    }
}
