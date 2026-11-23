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
        precondition(!SMSParser.isCarrierTrackingNumber("123456789012"),
                     "Bare digits must not trigger clipboard import")
        print("PASS: clipboard courier waybills, safe negatives, and pickup codes")
    }
}
