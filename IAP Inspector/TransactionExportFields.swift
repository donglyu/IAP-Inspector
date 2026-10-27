import Foundation

/// Columns derived from the already fetched transaction, without auxiliary API calls.
enum TransactionExportFields {
    static let headers = [
        "Apple_国家二位码", "Apple_商品名称（本机映射）", "Apple_购买日期UTC", "Apple_购买日期上海",
        "Apple_购买日期洛杉矶", "Apple_交易原因", "Apple_订阅到期时间UTC",
        "Apple_优惠类型", "Apple_优惠ID", "Apple_优惠支付方式", "Apple_优惠周期",
        "Apple_退款撤销类型", "Apple_退款撤销比例百分数", "Apple_购买归属", "Apple_是否订阅升级",
        "Apple_签名时间UTC", "Apple_webOrderLineItemId", "Apple_订阅组ID", "Apple_appTransactionId", "IAP_补充字段来源"
    ]

    static func values(for outcome: BatchOutcome?) -> [String] {
        guard let outcome, let summary = outcome.summary else { return Array(repeating: "", count: headers.count) }
        var payload: [String: Any] = [:]
        if let data = outcome.evidence.data(using: .utf8),
           let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = (response["signedTransactionInfo"] ?? response["signedTransaction"]) as? String,
           let decoded = try? AppleJWT.decodePayload(token),
           decoded["transactionId"] as? String == summary.transactionID,
           decoded["bundleId"] as? String == summary.bundleID {
            // The live response was verified by reconciliationTransaction. Reimported files are
            // historical cached data, not a fresh signature or current-status verification.
            payload = decoded
        }
        func string(_ key: String) -> String { payload[key] as? String ?? "" }
        func date(_ key: String) -> Date? {
            guard let value = payload[key] as? NSNumber else { return nil }
            return Date(timeIntervalSince1970: value.doubleValue / 1000)
        }
        func iso(_ date: Date?) -> String { date.map { ISO8601DateFormatter().string(from: $0) } ?? "" }
        func day(_ date: Date?, zone: String) -> String {
            guard let date else { return "" }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(identifier: zone)
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
        func fallback(_ value: String, _ existing: String) -> String { value.isEmpty ? existing : value }
        let purchase = date("purchaseDate") ?? summary.purchasedAt
        let country = fallback(string("storefront"), summary.storefront)
        let canonicalCountry = Locale(identifier: "und_" + country).region?.identifier ?? ""
        let alpha2 = canonicalCountry.count == 2 && Locale.Region.isoRegions.contains(where: { $0.identifier == canonicalCountry }) ? canonicalCountry : ""
        let reason = fallback(string("transactionReason"), summary.transactionReason)
        let reasonName = ["PURCHASE": "用户购买", "RENEWAL": "自动续费"][reason] ?? reason
        let offerType = (payload["offerType"] as? NSNumber)?.stringValue ?? ""
        let offerName = ["1": "首购优惠", "2": "促销优惠", "3": "优惠码", "4": "挽回优惠"][offerType] ?? offerType
        let percentage = (payload["revocationPercentage"] as? NSNumber).map { NSDecimalNumber(decimal: $0.decimalValue / 1000).stringValue } ?? ""
        let ownership = string("inAppOwnershipType")
        let ownershipName = ["PURCHASED": "本人购买", "FAMILY_SHARED": "家庭共享"][ownership] ?? ownership
        let upgraded = (payload["isUpgraded"] as? Bool).map { $0 ? "是" : "否" } ?? ""
        var values = [alpha2, ProductCatalog.lookupName(for: summary.productID), day(purchase, zone: "UTC"),
                      day(purchase, zone: "Asia/Shanghai"), day(purchase, zone: "America/Los_Angeles"), reasonName,
                      iso(date("expiresDate")), fallback(offerName, summary.offerType), fallback(string("offerIdentifier"), summary.offerIdentifier),
                      string("offerDiscountType"), string("offerPeriod"), fallback(string("revocationType"), summary.refundType), percentage,
                      fallback(ownershipName, summary.ownership), upgraded, iso(date("signedDate")), string("webOrderLineItemId"),
                      string("subscriptionGroupIdentifier"), string("appTransactionId"), payload.isEmpty ? "已保存字段；签名载荷不可用" : "已保存交易载荷（导入文件不重新验签）"]
        for index in headers.indices where values[index].isEmpty {
            values[index] = outcome.supplementalFields?[headers[index]] ?? ""
        }
        return values
    }
}
