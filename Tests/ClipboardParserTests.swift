import Foundation

/// Run: swiftc App/Parser.swift Tests/ClipboardParserTests.swift -o /tmp/clipboard-tests
///      /tmp/clipboard-tests
@main
struct ClipboardParserTests {
    static func main() {
        let examples: [(String, String, String)] = [
            ("SF1234567890123", "SF1234567890123", "顺丰速运"),
            ("zt123456789012", "ZT123456789012", "中通快递"),
            ("JT1234567890123", "JT1234567890123", "极兔速递"),
            ("JDVA123456789012", "JDVA123456789012", "京东物流"),
            ("ZTO123456789012", "ZTO123456789012", "中通快递"),
            ("YTO123456789012", "YTO123456789012", "圆通快递"),
            ("STO123456789012", "STO123456789012", "申通快递"),
            ("YD123456789012", "YD123456789012", "韵达快递"),
            ("EMS123456789012", "EMS123456789012", "中国邮政EMS"),
            ("JTSD123456789012", "JTSD123456789012", "极兔速递"),
            ("HTKY123456789012", "HTKY123456789012", "百世快递"),
            ("shunfeng123456789012", "SHUNFENG123456789012", "顺丰速运"),
            ("jtexpress123456789012", "JTEXPRESS123456789012", "极兔速递"),
            ("zhongtong123456789012", "ZHONGTONG123456789012", "中通快递"),
            ("yuantong123456789012", "YUANTONG123456789012", "圆通快递"),
            ("shentong123456789012", "SHENTONG123456789012", "申通快递"),
            ("yunda123456789012", "YUNDA123456789012", "韵达快递"),
            ("huitongkuaidi123456789012", "HUITONGKUAIDI123456789012", "百世快递"),
            ("jd123456789012", "JD123456789012", "京东快递"),
            ("已发货，运单：SF1234567890123，请查收", "SF1234567890123", "顺丰速运"),
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
        for prefix in ["SF", "JD", "JTSD", "ZTO", "YTO", "STO", "YD", "HTKY", "EMS",
                       "shunfeng", "jd", "jtexpress", "zhongtong", "yuantong",
                       "shentong", "yunda", "huitongkuaidi", "ems"] {
            precondition(SMSParser.isCarrierTrackingNumber(prefix + "123456789012"),
                         "Carrier prefix should be accepted: \(prefix)")
        }
        precondition(!SMSParser.isCarrierTrackingNumber("SFABC"), "Prefix without digits is not a waybill")
        precondition(!SMSParser.isCarrierTrackingNumber("SF1234"), "Short token is not a waybill")
        precondition(SMSParser.parse("订单A-ZTO123456789012").trackingNumber == "ZTO123456789012",
                     "Standalone prefixed tracking token should be extracted")
        precondition(!SMSParser.isCarrierTrackingNumber("123456789012"),
                     "Bare digits must not trigger clipboard import")
        print("PASS: clipboard courier waybills, safe negatives, and pickup codes")
    }
}
