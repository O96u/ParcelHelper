import Foundation

/// Run: swiftc App/Parser.swift Tests/ClipboardParserTests.swift -o /tmp/clipboard-tests
///      /tmp/clipboard-tests
@main
struct ClipboardParserTests {
    static func main() {
        let examples: [(String, String, String)] = [
            ("SF1234567890123", "SF1234567890123", "顺丰速运"),
            ("sf1234567890123", "SF1234567890123", "顺丰速运"),
            ("JT1234567890123", "JT1234567890123", "极兔速递"),
            ("jt1234567890123", "JT1234567890123", "极兔速递"),
            ("JDVA123456789012", "JDVA123456789012", "京东快递"),
            ("jd123456789012", "JD123456789012", "京东快递"),
            ("YT1234567890123", "YT1234567890123", "圆通速递"),
            ("EA123456789CN", "EA123456789CN", "中国邮政EMS"),
            ("已发货，运单：SF1234567890123，请查收", "SF1234567890123", "顺丰速运"),
            ("【中通快递】快递单号 753123456789，正在运输", "753123456789", "中通快递"),
            ("快递单号 123456789012，物流已揽收", "123456789012", ""),
            ("【中通快递】请凭10-3-2323到某便利店取件", "", "中通快递")
        ]
        for (text, expected, company) in examples {
            let parsed = SMSParser.parse(text)
            precondition(parsed.trackingNumber == expected,
                         "Wrong tracking number for \(text)")
            if !company.isEmpty {
                precondition(parsed.company == company,
                             "Wrong carrier for \(text)")
            }
        }
        precondition(SMSParser.parse("13800138000").trackingNumber.isEmpty,
                     "A phone number is not a waybill")
        precondition(SMSParser.parse("订单号码 123456789012").trackingNumber.isEmpty,
                     "An order ID is not a waybill")
        precondition(SMSParser.parse("取件码：10-3-2323").code == "10-3-2323",
                     "Pickup codes must continue to work")
        precondition(SMSParser.isCarrierTrackingNumber("SF1234567890123"),
                     "Prefixed waybill must be accepted")
        for prefix in ["SF", "JD", "JT", "YT"] {
            precondition(SMSParser.isCarrierTrackingNumber(prefix + "1234567890123"),
                         "Recognized waybill: \(prefix)")
            precondition(SMSParser.isCarrierTrackingNumber(prefix.lowercased() + "1234567890123"),
                         "Lowercase recognized waybill: \(prefix)")
        }
        for alias in ["ZTO", "STO", "HTKY", "JTSD", "jtexpress",
                      "yuantong", "zhongtong", "shunfeng", "huitongkuaidi"] {
            precondition(!SMSParser.isCarrierTrackingNumber(alias + "123456789012"),
                         "API carrier alias must not trigger standalone import: \(alias)")
            precondition(SMSParser.parse(alias + "123456789012").trackingNumber.isEmpty,
                         "Alias must not be parsed as a standalone waybill: \(alias)")
        }
        precondition(SMSParser.isCarrierTrackingNumber("EA123456789CN"),
                     "EMS S10 waybill must be accepted")
        precondition(!SMSParser.isCarrierTrackingNumber("SFABC"), "No digits must be rejected")
        precondition(!SMSParser.isCarrierTrackingNumber("SF1234"), "Short token must be rejected")
        precondition(!SMSParser.isCarrierTrackingNumber("123456789012"),
                     "Bare digits must not trigger standalone clipboard import")
        print("PASS: clipboard courier waybills, safe negatives, and pickup codes")
    }
}
