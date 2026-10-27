import Foundation
import Security
import CryptoKit

enum AppleEnvironment: String, Codable, CaseIterable {
    case production, sandbox
    var baseURL: URL { URL(string: self == .production ? "https://api.storekit.apple.com" : "https://api.storekit-sandbox.apple.com")! }
    var title: String { self == .production ? "Production" : "Sandbox" }
}

struct InspectorSettings: Codable, Equatable {
    var bundleID = ""
    var issuerID = ""
    var keyID = ""
    var isConfigured: Bool { !bundleID.isEmpty && !issuerID.isEmpty && !keyID.isEmpty }
    static let empty = InspectorSettings()
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "inspector.settings"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return .empty }
        return value
    }
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: "inspector.settings")
    }
}

// MARK: - Product Catalog
struct ProductItem: Identifiable, Codable, Equatable {
    var id: String { productID }
    var productID: String
    var displayName: String
}

enum ProductCatalog {
    private static let key = "inspector.product_catalog"
    private static var cachedItems: [ProductItem]?
    private static var cachedMap: [String: String]?
    private static let lock = NSLock()

    static let defaultItems: [ProductItem] = [
        ProductItem(productID: "gg.epal.buff_0001", displayName: "Buff_3.00 USD_4.99"),
        ProductItem(productID: "gg.epal.buff_0002", displayName: "Buff_6.00 USD_9.99"),
        ProductItem(productID: "gg.epal.buff_0003", displayName: "Buff_12.00 USD_19.99"),
        ProductItem(productID: "gg.epal.buff_0005", displayName: "Buff_36.00 USD_59.99"),
        ProductItem(productID: "gg.epal.buff_0004", displayName: "Buff_24.00 USD_39.99"),
        ProductItem(productID: "gg.epal.buff_0008", displayName: "V2 Buff_3.00 USD_4.99"),
        ProductItem(productID: "gg.epal.buff_0010", displayName: "V2 Buff_15.00 USD_24.99"),
        ProductItem(productID: "gg.epal.buff_0011", displayName: "V2 Buff_21.00 USD_34.99"),
        ProductItem(productID: "gg.epal.ios.buff_0207", displayName: "Buff_30.00 USD_49.99"),
        ProductItem(productID: "gg.epal.ios.buff_0206", displayName: "Buff_60.00 USD_99.99"),
        ProductItem(productID: "gg.epal.autorenew.newvip1month", displayName: "E-Pal VIP 1 Month"),
        ProductItem(productID: "gg.epal.autorenew.newvip3months", displayName: "E-Pal VIP 3 Months"),
        ProductItem(productID: "gg.epal.autorenew.newvip12months", displayName: "E-Pal VIP 12 Months"),
        ProductItem(productID: "gg.epal.autorenew.newvip1month.v2", displayName: "E-Pal 1 Month VIP")
    ]

    static func load() -> [ProductItem] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    static func save(_ items: [ProductItem]) {
        lock.lock()
        cachedItems = items
        updateMapLocked(items)
        lock.unlock()
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func resetToDefault() {
        save(defaultItems)
    }

    static func lookupName(for productID: String) -> String {
        if productID.isEmpty { return "Apple 应用内购买" }
        lock.lock()
        if cachedMap == nil {
            _ = loadLocked()
        }
        let name = cachedMap?[productID]
        lock.unlock()
        return name ?? productID
    }

    private static func updateMapLocked(_ items: [ProductItem]) {
        var map: [String: String] = [:]
        map.reserveCapacity(items.count)
        for item in items {
            map[item.productID] = item.displayName
        }
        cachedMap = map
    }

    private static func loadLocked() -> [ProductItem] {
        if let cached = cachedItems { return cached }
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([ProductItem].self, from: data) else {
            cachedItems = defaultItems
            updateMapLocked(defaultItems)
            return defaultItems
        }
        cachedItems = list
        updateMapLocked(list)
        return list
    }
}

// MARK: - Transaction Models
struct TransactionSummary: Identifiable, Codable {
    var id: String { transactionID }
    var transactionID = ""
    var originalTransactionID = ""
    var bundleID = ""
    var productID = ""
    var productName = ""
    var status = ""
    var purchaseDate = ""          // 本次交易/续订发生时间
    var originalPurchaseDate = ""  // 首次购买时间
    var expirationDate = ""
    var revocationDate = ""
    var price = ""
    var storefront = ""
    var ownership = ""
    var productType = ""
    var billingPlanType = ""
    var commitmentInfo = ""
    var transactionReason = ""
    var refundType = ""
    var refundReason = ""
    var refundPercentage = ""
    var offerType = ""
    var offerIdentifier = ""
    var appAccountToken = ""
    var quantity = ""
    var isSubscription = false
    var environment = ""
    var refundCaveat: String?
    var purchasedAt: Date?
    var originalPurchasedAt: Date?
    var revokedAt: Date?
}

struct SubscriptionSummary: Identifiable {
    var id: String { "\(productID)-\(status)-\(expirationDate)" }
    var productID: String
    var status: String
    var expirationDate: String
    var billingPlanType = ""
    var renewalBillingPlanType = ""
    var renewalCommitmentInfo = ""
}

struct NotificationSummary: Identifiable {
    var id: String { "\(date)-\(type)-\(subtype)-\(deliveryStatus)" }
    var date: String
    var occurredAt: Date?
    var type: String
    var subtype: String
    var deliveryStatus: String
    var isFailure: Bool { deliveryStatus.contains("投递失败") || (deliveryStatus != "已送达" && deliveryStatus != "状态未知") }
    var rawPayload: String
}

struct TimelineEvent: Identifiable {
    var id: String { "\(occurredAt.timeIntervalSince1970)-\(title)-\(identifier)" }
    var occurredAt: Date
    var title: String
    var detail: String
    var identifier: String
    var secondaryIdentifier: String
    var symbol: String
    var isWarning: Bool
}

struct InspectorResult {
    var environment: AppleEnvironment
    var summary: TransactionSummary
    var history: [TransactionSummary]
    var refunds: [TransactionSummary]
    var subscriptions: [SubscriptionSummary]
    var notifications: [NotificationSummary]
    var appTransaction: AppTransactionSummary?
    var paginationIncomplete: Bool
    var timeline: [TimelineEvent]
    var rawJSON: String
    var diagnosticIssues: [DiagnosticIssue]
    var notificationFailuresOnly: Bool
    var subscriptionStatuses: [Int]

    init(
        environment: AppleEnvironment,
        summary: TransactionSummary,
        history: [TransactionSummary],
        refunds: [TransactionSummary],
        subscriptions: [SubscriptionSummary],
        notifications: [NotificationSummary],
        appTransaction: AppTransactionSummary?,
        paginationIncomplete: Bool,
        timeline: [TimelineEvent],
        rawJSON: String,
        notificationFailuresOnly: Bool = false,
        subscriptionStatuses: [Int] = []
    ) {
        self.environment = environment
        self.summary = summary
        self.history = history
        self.refunds = refunds
        self.subscriptions = subscriptions
        self.notifications = notifications
        self.appTransaction = appTransaction
        self.paginationIncomplete = paginationIncomplete
        self.timeline = timeline
        self.rawJSON = rawJSON
        self.notificationFailuresOnly = notificationFailuresOnly
        self.subscriptionStatuses = subscriptionStatuses
        self.diagnosticIssues = DiagnosticAnalyzer.analyze(notifications: notifications, summary: summary, refunds: refunds, subscriptions: subscriptions)
    }
}

struct AppTransactionSummary {
    var appTransactionID = ""
    var bundleID = ""
    var appPurchaseDate = ""
    var originalAppVersion = ""
    var originalPlatform = ""
}

enum QueryType: String, Hashable, Codable, CaseIterable {
    case transaction, appTransaction, order

    var title: String {
        switch self {
        case .transaction: "交易 ID"
        case .appTransaction: "App Transaction ID"
        case .order: "订单号"
        }
    }
}

struct QueryHistoryItem: Identifiable, Codable {
    var id: String { "\(queryType.rawValue):\(identifier)" }
    var identifier: String
    var date: Date
    var environment: String?
    var queryType: QueryType = .transaction
    var note: String? = nil

    private enum CodingKeys: String, CodingKey { case identifier, date, environment, queryType, note }

    init(identifier: String, date: Date, environment: String?, queryType: QueryType, note: String? = nil) {
        self.identifier = identifier
        self.date = date
        self.environment = environment
        self.queryType = queryType
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(String.self, forKey: .identifier)
        date = try container.decode(Date.self, forKey: .date)
        environment = try container.decodeIfPresent(String.self, forKey: .environment)
        queryType = try container.decodeIfPresent(QueryType.self, forKey: .queryType) ?? .transaction
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}

enum QueryHistory {
    private static let key = "inspector.history"
    private static let maximumCountKey = "inspector.history.maximumCount"
    private static let retentionDaysKey = "inspector.history.retentionDays"
    static let defaultMaximumCount = 100
    static let defaultRetentionDays = 90

    static var maximumCount: Int {
        UserDefaults.standard.object(forKey: maximumCountKey) as? Int ?? defaultMaximumCount
    }

    static var retentionDays: Int {
        UserDefaults.standard.object(forKey: retentionDaysKey) as? Int ?? defaultRetentionDays
    }

    static func setPolicy(maximumCount: Int, retentionDays: Int) {
        UserDefaults.standard.set(maximumCount, forKey: maximumCountKey)
        UserDefaults.standard.set(retentionDays, forKey: retentionDaysKey)
    }

    private static func filtered(_ items: [QueryHistoryItem]) -> [QueryHistoryItem] {
        let filteredByAge: [QueryHistoryItem]
        if retentionDays == 0 {
            filteredByAge = items
        } else {
            let cutoff = Date.now.addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
            filteredByAge = items.filter { $0.date >= cutoff }
        }
        return maximumCount == 0 ? filteredByAge : Array(filteredByAge.prefix(maximumCount))
    }

    static func load() -> [QueryHistoryItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([QueryHistoryItem].self, from: data) else { return [] }
        let retained = filtered(items)
        if retained.count != items.count { save(retained) }
        return retained
    }
    static func save(_ items: [QueryHistoryItem]) {
        let retained = filtered(items)
        guard let data = try? JSONEncoder().encode(retained) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - Smart Diagnostic
enum DiagnosticSeverity { case info, warning, critical }

struct DiagnosticIssue: Identifiable {
    var id: String { "\(title)-\(detail)" }
    var severity: DiagnosticSeverity
    var title: String
    var detail: String
    var suggestion: String?
}

enum DiagnosticAnalyzer {
    static func analyze(
        notifications: [NotificationSummary],
        summary: TransactionSummary,
        refunds: [TransactionSummary],
        subscriptions: [SubscriptionSummary]
    ) -> [DiagnosticIssue] {
        var issues: [DiagnosticIssue] = []

        // 1. 检查通知投递失败 (HTTP != 200)
        let failedNotifications = notifications.filter { $0.isFailure }
        if !failedNotifications.isEmpty {
            issues.append(DiagnosticIssue(
                severity: .critical,
                title: "存在 \(failedNotifications.count) 条通知投递失败",
                detail: "Apple 发送 Server Notification 回调时，业务服务器未响应 200。",
                suggestion: "请检查业务服务器日志与 Webhook 接口，确认是否漏发货或未及时同步退款/续费状态。"
            ))
        }

        // 2. 检查退款与撤销
        if !summary.revocationDate.isEmpty || !refunds.isEmpty {
            let reasonText = summary.refundReason.isEmpty ? "退款已批准" : "退款原因：\(summary.refundReason)"
            issues.append(DiagnosticIssue(
                severity: .warning,
                title: "此交易包含已撤销 / 退款记录",
                detail: "\(reasonText)（撤销时间：\(summary.revocationDate.isEmpty ? "见退款记录" : summary.revocationDate)）。",
                suggestion: "建议核实业务数据库中该用户的道具/权益是否已完成扣减。"
            ))
        }

        // 3. 检查订阅状态（计费宽限期 / 账单重试）
        for sub in subscriptions {
            if sub.status == "计费宽限期" {
                issues.append(DiagnosticIssue(
                    severity: .warning,
                    title: "订阅处于计费宽限期 (Billing Grace Period)",
                    detail: "商品 [\(sub.productID)] 扣款失败，Apple 正在宽限期内尝试重试扣款。",
                    suggestion: "根据 App Store 指南，宽限期内通常建议保留用户权益；若宽限期后仍未扣款成功再停权。"
                ))
            } else if sub.status == "账单重试" {
                issues.append(DiagnosticIssue(
                    severity: .warning,
                    title: "订阅处于账单重试 (Billing Retry)",
                    detail: "商品 [\(sub.productID)] 扣款失败且无宽限期或宽限期已过，Apple 正在持续尝试扣款。",
                    suggestion: "建议暂停用户权益，等待 Apple 扣款恢复通知 (DID_RENEW)。"
                ))
            }
        }

        return issues
    }

    static func analyze(result: InspectorResult) -> [DiagnosticIssue] {
        analyze(notifications: result.notifications, summary: result.summary, refunds: result.refunds, subscriptions: result.subscriptions)
    }
}

// MARK: - Report Generator
enum ReportGenerator {
    private static let zhLocale = Locale(identifier: "zh_CN")

    static func generateMarkdown(result: InspectorResult) -> String {
        var lines: [String] = []
        lines.append("# Apple 交易排查报告")
        lines.append("- **生成时间**: \(Date().formatted(.dateTime.locale(zhLocale).year().month().day().hour().minute().second()))")
        lines.append("- **环境**: \(result.environment.title)")
        lines.append("- **商品名称**: \(result.summary.productName)")
        lines.append("- **Product ID**: `\(result.summary.productID)`")
        lines.append("- **Bundle ID**: `\(result.summary.bundleID)`")
        lines.append("- **交易状态**: \(result.summary.status)")
        lines.append("- **本次交易时间**: \(result.summary.purchaseDate.isEmpty ? "—" : result.summary.purchaseDate)")
        if !result.summary.originalPurchaseDate.isEmpty {
            lines.append("- **首次购买时间**: \(result.summary.originalPurchaseDate)")
        }
        lines.append("- **交易 ID**: `\(result.summary.transactionID)`")
        if !result.summary.originalTransactionID.isEmpty {
            lines.append("- **原始交易 ID**: `\(result.summary.originalTransactionID)`")
        }
        if !result.summary.price.isEmpty {
            lines.append("- **金额**: \(result.summary.price)")
        }
        if !result.summary.appAccountToken.isEmpty {
            lines.append("- **App Account Token**: `\(result.summary.appAccountToken)`")
        }
        if !result.summary.revocationDate.isEmpty {
            lines.append("- **退款/撤销时间**: \(result.summary.revocationDate)")
            lines.append("- **退款原因**: \(result.summary.refundReason)")
        }

        let issues = result.diagnosticIssues
        if !issues.isEmpty {
            lines.append("\n## 诊断与风险发现")
            for issue in issues {
                lines.append("- **[\(issue.severity == .critical ? "严重" : "提醒")] \(issue.title)**: \(issue.detail)")
                if let sug = issue.suggestion {
                    lines.append("  - *建议*: \(sug)")
                }
            }
        }

        if !result.history.isEmpty {
            lines.append("\n## 关联交易记录 (\(result.history.count) 笔)")
            for item in result.history {
                lines.append("- `\(item.transactionID)` | \(item.purchaseDate) | \(item.status) | \(item.productName)")
            }
        }

        if !result.notifications.isEmpty {
            lines.append("\n## Apple 通知历史 (\(result.notifications.count) 条)")
            for notif in result.notifications {
                lines.append("- \(notif.date) | \(notif.type) \(notif.subtype) | \(notif.deliveryStatus)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - JWS Inspection Result
struct JWSInspectionResult {
    var isValidSignature: Bool
    var isAppleRootTrusted: Bool
    var headerJSON: String
    var payloadJSON: String
    var summaryItems: [(key: String, value: String)]
    var certificateChainSummaries: [String]
    var errorMessage: String?
}

// MARK: - API Error
enum AppleAPIError: LocalizedError {
    case missingConfiguration, invalidKey, invalidSignedData, badResponse, invalidTransactionID, notFound(String)
    case authorizationRejected(statusCode: Int, code: String, message: String, endpoint: String, environment: String)
    case apiRejected(statusCode: Int, code: String, message: String, endpoint: String, environment: String)
    case rateLimited(retryAt: Date?, code: String)
    case rejected(Int, String), network(String)
    var errorDescription: String? {
        switch self {
        case .missingConfiguration: return "请先在设置中配置 Apple API 凭证。"
        case .invalidKey: return "无法读取 .p8 私钥，请确认使用 App Store Connect In-App Purchase API 私钥。"
        case .invalidSignedData: return "Apple 签名数据未通过证书链或签名校验，已停止解析。"
        case .badResponse: return "Apple 返回了无法识别的数据。"
        case .invalidTransactionID: return "交易 ID 格式无效，请确认输入的是 Apple 交易 ID（4000006 Invalid transaction id）。"
        case .notFound(let code): return code == "4040010" ? "未找到该交易，请确认 ID 是否正确。" : "Apple 没有找到对应数据（\(code)）。"
        case .authorizationRejected(let statusCode, let code, let message, let endpoint, let environment):
            let statusName = statusCode == 401 ? "Unauthorized" : "Forbidden"
            let suggestion = statusCode == 401
                ? "检查 In-App Purchase 密钥是否有效，以及 Issuer ID、Key ID、私钥是否属于同一把密钥；同时确认 Bundle ID 正确。"
                : "检查该密钥是否仍有效、应用是否属于对应开发者团队，以及该操作是否适用于当前环境。"
            return "Apple 拒绝了授权请求（HTTP \(statusCode) \(statusName)）。\n接口：\(endpoint)\n环境：\(environment)\nApple 错误码：\(code)\nApple 返回：\(message)\n建议：\(suggestion)"
        case .apiRejected(let statusCode, let code, let message, let endpoint, let environment):
            let explanation = AppleAPIError.localizedMessage(code: code, status: statusCode)
            return "\(explanation)\nHTTP 状态：\(statusCode)\n接口：\(endpoint)\n环境：\(environment)\nApple 错误码：\(code)\nApple 返回：\(message)"
        case .rejected(let code, let message):
            let appleCode = message.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            return "\(AppleAPIError.localizedMessage(code: appleCode, status: code))（\(message)）"
        case .rateLimited(let retryAt, let code): return "Apple 请求限流（\(code)），\(retryAt.map { "请于 " + ISO8601DateFormatter().string(from: $0) + " 后重试" } ?? "请稍后重试")。"
        case .network(let message): return "连接 Apple 失败：\(message)"
        }
    }
    static func localizedMessage(code: String, status: Int) -> String {
        switch code {
        case "4040003": return "未找到对应 App，请检查 Bundle ID 和 API Key 的 App 权限"
        case "4000002": return "Bundle ID 无效，请检查设置中的 Bundle ID"
        case "4000005", "4000017": return "分页标记已失效，请重新发起查询"
        case "4000006": return "交易 ID 格式无效，请确认输入的是 Apple 交易 ID"
        case "4000008": return "原始交易 ID 无效，请确认输入内容"
        case "4000018": return "通知筛选条件无效，请检查请求参数"
        default:
            if status == 429 { return "Apple API 请求过于频繁，请稍后重试" }
            if (500...599).contains(status) { return "Apple 服务暂时不可用，请稍后重试" }
            if code == "4000000" { return "请求参数无效，请确认标识类型和内容" }
            return "Apple API 请求失败"
        }
    }
}

// MARK: - Apple API Service
final class AppleAPIService {
    private let session = URLSession.shared
    private static let zhCNLocale = Locale(identifier: "zh_CN")
    private static let currencyFormattersLock = NSLock()
    private static var currencyFormatters: [String: NumberFormatter] = [:]

    /// 单笔核验不依赖订阅、通知等辅助接口；环境由操作者明确选择。
    func reconciliationTransaction(_ identifier: String, environment: AppleEnvironment, settings: InspectorSettings) async throws -> (TransactionSummary, Decimal?, String, String) {
        guard !identifier.isEmpty, identifier.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw AppleAPIError.invalidTransactionID }
        guard settings.isConfigured, KeychainStore.read() != nil else { throw AppleAPIError.missingConfiguration }
        let raw = try await request(path: "/inApps/v1/transactions/\(identifier)", environment: environment, settings: settings)
        let parsed = try parseTransaction(raw, fallbackID: identifier, expectedBundleID: settings.bundleID)
        let amount = (parsed.payload["price"] as? NSNumber).map { $0.decimalValue / 1000 }
        let json = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        return (parsed.summary, amount, parsed.payload["currency"] as? String ?? "", String(decoding: json, as: UTF8.self))
    }

    func lookup(_ identifier: String, settings: InspectorSettings, subscriptionStatuses: [Int] = [], notificationsOnlyFailures: Bool = false) async throws -> InspectorResult {
        guard settings.isConfigured, KeychainStore.read() != nil else { throw AppleAPIError.missingConfiguration }
        var environments: [AppleEnvironment] = [.production, .sandbox]
        var lastNotFound: Error = AppleAPIError.notFound("4040010")
        while let environment = environments.first {
            environments.removeFirst()
            do {
                let raw = try await request(path: "/inApps/v1/transactions/\(identifier)", environment: environment, settings: settings)
                let parsed = try parseTransaction(raw, fallbackID: identifier, expectedBundleID: settings.bundleID)
                let subjectID = parsed.summary.originalTransactionID.isEmpty ? identifier : parsed.summary.originalTransactionID
                async let historyRaw = paginatedGET(path: "/inApps/v2/history/\(subjectID)", environment: environment, settings: settings, resultKey: "signedTransactions", tokenKey: "revision")
                async let refundsRaw = paginatedGET(path: "/inApps/v2/refund/lookup/\(subjectID)", environment: environment, settings: settings, resultKey: "signedTransactions", tokenKey: "revision")
                let statusQuery = subscriptionStatuses.sorted().map { URLQueryItem(name: "status", value: String($0)) }
                async let subscriptionsRaw = request(path: "/inApps/v1/subscriptions/\(subjectID)", environment: environment, settings: settings, queryItems: statusQuery)
                async let notificationsRaw = notificationHistory(transactionID: subjectID, environment: environment, settings: settings, onlyFailures: notificationsOnlyFailures)
                let auxiliary = try await (historyRaw, refundsRaw, subscriptionsRaw, notificationsRaw)
                let history = try parseTransactionList(auxiliary.0, key: "signedTransactions", expectedBundleID: settings.bundleID)
                let refunds = try parseTransactionList(auxiliary.1, key: "signedTransactions", expectedBundleID: settings.bundleID)
                let subscriptions = parseSubscriptions(auxiliary.2, expectedBundleID: settings.bundleID)
                let notifications = try parseNotifications(auxiliary.3, expectedBundleID: settings.bundleID)
                let timeline = buildTimeline(transactions: history, refunds: refunds, notifications: notifications)
                let paginationIncomplete = [auxiliary.0, auxiliary.1, auxiliary.3].contains { $0["hasMore"] as? Bool == true }
                let combined: [String: Any] = ["transactionInfo": raw, "history": auxiliary.0, "refundHistory": auxiliary.1, "subscriptionStatus": auxiliary.2, "notificationHistory": auxiliary.3]
                let rawData = (try? JSONSerialization.data(withJSONObject: combined, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                var finalSummary = parsed.summary
                finalSummary.environment = environment.title
                return InspectorResult(environment: environment, summary: finalSummary, history: history, refunds: refunds, subscriptions: subscriptions, notifications: notifications, appTransaction: nil, paginationIncomplete: paginationIncomplete, timeline: timeline, rawJSON: String(data: rawData, encoding: .utf8) ?? "{}", notificationFailuresOnly: notificationsOnlyFailures, subscriptionStatuses: subscriptionStatuses)
            } catch let error as AppleAPIError {
                if case .notFound = error { lastNotFound = error; continue }
                throw error
            }
        }
        throw lastNotFound
    }

    func lookupAppTransactionID(_ identifier: String, settings: InspectorSettings, subscriptionStatuses: [Int] = [], notificationsOnlyFailures: Bool = false) async throws -> InspectorResult {
        guard settings.isConfigured, KeychainStore.read() != nil else { throw AppleAPIError.missingConfiguration }
        var lastNotFound: Error = AppleAPIError.notFound("4040010")
        for environment in [AppleEnvironment.production, .sandbox] {
            do {
                let raw = try await request(path: "/inApps/v1/transactions/appTransactions/\(identifier)", environment: environment, settings: settings)
                guard let signed = raw["signedAppTransactionInfo"] as? String else { throw AppleAPIError.badResponse }
                let payload = try AppleJWT.verifyAndDecodePayload(signed, expectedBundleID: settings.bundleID)
                let appTransaction = AppTransactionSummary(
                    appTransactionID: payload["appTransactionId"] as? String ?? identifier,
                    bundleID: payload["bundleId"] as? String ?? settings.bundleID,
                    appPurchaseDate: dateValue(payload["originalPurchaseDate"]),
                    originalAppVersion: payload["originalApplicationVersion"] as? String ?? "",
                    originalPlatform: payload["originalPlatform"] as? String ?? ""
                )
                let historyRaw = try await paginatedGET(path: "/inApps/v2/history/\(identifier)", environment: environment, settings: settings, resultKey: "signedTransactions", tokenKey: "revision")
                let history = try parseTransactionList(historyRaw, key: "signedTransactions", expectedBundleID: settings.bundleID)
                async let refundsRaw = paginatedGET(path: "/inApps/v2/refund/lookup/\(identifier)", environment: environment, settings: settings, resultKey: "signedTransactions", tokenKey: "revision")
                let statusQuery = subscriptionStatuses.sorted().map { URLQueryItem(name: "status", value: String($0)) }
                async let subscriptionsRaw = request(path: "/inApps/v1/subscriptions/\(identifier)", environment: environment, settings: settings, queryItems: statusQuery)
                let auxiliary = try await (refundsRaw, subscriptionsRaw)
                let refunds = try parseTransactionList(auxiliary.0, key: "signedTransactions", expectedBundleID: settings.bundleID)
                let subscriptions = parseSubscriptions(auxiliary.1, expectedBundleID: settings.bundleID)
                let notificationSubject = history.first.map { $0.originalTransactionID.isEmpty ? $0.transactionID : $0.originalTransactionID }
                let notificationsRaw: [String: Any]
                if let notificationSubject, !notificationSubject.isEmpty {
                    notificationsRaw = try await notificationHistory(transactionID: notificationSubject, environment: environment, settings: settings, onlyFailures: notificationsOnlyFailures)
                } else {
                    notificationsRaw = ["notificationHistory": [], "hasMore": false, "pagesFetched": 0]
                }
                let notifications = try parseNotifications(notificationsRaw, expectedBundleID: settings.bundleID)
                let summary = history.first ?? TransactionSummary(transactionID: identifier, productID: "App Transaction", productName: "App 下载记录", status: "已查询", purchaseDate: appTransaction.appPurchaseDate, environment: environment.title)
                let completeRaw: [String: Any] = ["appTransactionInfo": raw, "history": historyRaw, "refundHistory": auxiliary.0, "subscriptionStatus": auxiliary.1, "notificationHistory": notificationsRaw]
                let json = try JSONSerialization.data(withJSONObject: completeRaw, options: [.prettyPrinted, .sortedKeys])
                let paginationIncomplete = [historyRaw, auxiliary.0, notificationsRaw].contains { $0["hasMore"] as? Bool == true }
                return InspectorResult(environment: environment, summary: summary, history: history, refunds: refunds, subscriptions: subscriptions, notifications: notifications, appTransaction: appTransaction, paginationIncomplete: paginationIncomplete, timeline: buildTimeline(transactions: history, refunds: refunds, notifications: notifications), rawJSON: String(data: json, encoding: .utf8) ?? "{}", notificationFailuresOnly: notificationsOnlyFailures, subscriptionStatuses: subscriptionStatuses)
            } catch let error as AppleAPIError {
                if case .notFound = error { lastNotFound = error; continue }
                throw error
            }
        }
        throw lastNotFound
    }

    func lookupOrderID(_ orderID: String, settings: InspectorSettings) async throws -> InspectorResult {
        guard settings.isConfigured, KeychainStore.read() != nil else { throw AppleAPIError.missingConfiguration }
        let escaped = orderID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? orderID
        let raw = try await request(path: "/inApps/v1/lookup/\(escaped)", environment: .production, settings: settings)
        let signedTransactions = raw["signedTransactions"] as? [String] ?? []
        let transactions = signedTransactions.compactMap { token -> TransactionSummary? in
            guard let payload = try? AppleJWT.verifyAndDecodePayload(token, expectedBundleID: settings.bundleID) else { return nil }
            return makeSummary(payload, fallbackID: "", fallbackBundleID: settings.bundleID)
        }
        guard let first = transactions.first else { throw AppleAPIError.badResponse }
        let json = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
        return InspectorResult(environment: .production, summary: first, history: transactions, refunds: [], subscriptions: [], notifications: [], appTransaction: nil, paginationIncomplete: false, timeline: buildTimeline(transactions: transactions, refunds: [], notifications: []), rawJSON: String(data: json, encoding: .utf8) ?? "{}")
    }

    func testConnection(settings: InspectorSettings) async throws {
        guard settings.isConfigured, KeychainStore.read() != nil else { throw AppleAPIError.missingConfiguration }
        do { _ = try await request(path: "/inApps/v1/transactions/0", environment: .production, settings: settings) }
        catch let error as AppleAPIError {
            // Apple 接受凭证后会继续校验测试用的占位交易 ID，并以 4000006 拒绝它。
            // 这与 4040010 一样，说明认证已通过；其他错误仍应显示给用户。
            switch error { case .notFound, .invalidTransactionID: return; default: throw error }
        }
    }

    // MARK: - Test Notification APIs
    func requestTestNotification(environment: AppleEnvironment, settings: InspectorSettings) async throws -> String {
        guard settings.isConfigured, KeychainStore.read() != nil else { throw AppleAPIError.missingConfiguration }
        let response = try await request(path: "/inApps/v1/notifications/test", environment: environment, settings: settings, method: "POST", body: nil)
        guard let token = response["testNotificationToken"] as? String else { throw AppleAPIError.badResponse }
        return token
    }

    func getTestNotificationStatus(token: String, environment: AppleEnvironment, settings: InspectorSettings) async throws -> [String: Any] {
        guard settings.isConfigured, KeychainStore.read() != nil else { throw AppleAPIError.missingConfiguration }
        let escaped = token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? token
        return try await request(path: "/inApps/v1/notifications/test/\(escaped)", environment: environment, settings: settings)
    }

    private func paginatedGET(path: String, environment: AppleEnvironment, settings: InspectorSettings, resultKey: String, tokenKey: String) async throws -> [String: Any] {
        var all: [String] = []
        var page: [String: Any] = [:]
        var token: String?
        var hasMore = true
        var pageCount = 0
        while hasMore && pageCount < 500 {
            var components = URLComponents(url: URL(string: path, relativeTo: environment.baseURL)!, resolvingAgainstBaseURL: true)!
            if let token { components.queryItems = [URLQueryItem(name: tokenKey, value: token)] }
            page = try await request(url: components.url!, method: "GET", body: nil, environment: environment, settings: settings)
            all.append(contentsOf: page[resultKey] as? [String] ?? [])
            hasMore = page["hasMore"] as? Bool ?? false
            token = page[tokenKey] as? String
            pageCount += 1
            if hasMore && (token == nil || token?.isEmpty == true) { throw AppleAPIError.badResponse }
        }
        page[resultKey] = all
        page["hasMore"] = hasMore
        page["pagesFetched"] = pageCount
        page["paginationIncomplete"] = hasMore
        return page
    }

    private func notificationHistory(transactionID: String, environment: AppleEnvironment, settings: InspectorSettings, onlyFailures: Bool = false) async throws -> [String: Any] {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let days: Double = environment == .production ? 179 : 29
        var body: [String: Any] = ["startDate": now - Int(days * 24 * 60 * 60 * 1000), "endDate": now, "transactionId": transactionID]
        if onlyFailures { body["onlyFailures"] = true }
        var records: [[String: Any]] = []
        var page: [String: Any] = [:]
        var token: String?
        var hasMore = true
        var pageCount = 0
        while hasMore && pageCount < 500 {
            if let token { body["paginationToken"] = token } else { body.removeValue(forKey: "paginationToken") }
            page = try await request(path: "/inApps/v1/notifications/history", environment: environment, settings: settings, method: "POST", body: body)
            records.append(contentsOf: page["notificationHistory"] as? [[String: Any]] ?? [])
            hasMore = page["hasMore"] as? Bool ?? false
            token = page["paginationToken"] as? String
            pageCount += 1
            if hasMore && (token == nil || token?.isEmpty == true) { throw AppleAPIError.badResponse }
        }
        page["notificationHistory"] = records
        page["hasMore"] = hasMore
        page["pagesFetched"] = pageCount
        page["paginationIncomplete"] = hasMore
        return page
    }

    private func request(path: String, environment: AppleEnvironment, settings: InspectorSettings, method: String = "GET", body: [String: Any]? = nil, queryItems: [URLQueryItem] = []) async throws -> [String: Any] {
        guard let baseURL = URL(string: path, relativeTo: environment.baseURL),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else { throw AppleAPIError.badResponse }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw AppleAPIError.badResponse }
        return try await request(url: url, method: method, body: body, environment: environment, settings: settings)
    }

    private func request(url: URL, method: String, body: [String: Any]?, environment: AppleEnvironment, settings: InspectorSettings) async throws -> [String: Any] {
        guard let key = KeychainStore.read() else { throw AppleAPIError.missingConfiguration }
        let token = try AppleJWT.make(settings: settings, privateKey: key)
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw AppleAPIError.badResponse }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard (200..<300).contains(response.statusCode) else {
                let code = body["errorCode"].map { String(describing: $0) } ?? String(response.statusCode)
                let message = (body["errorMessage"] as? String) ?? (body["message"] as? String) ?? "请求未成功"
                let endpoint = Self.endpointDescription(url.path)
                let environmentName = environment.title
                if response.statusCode == 429 {
                    throw AppleAPIError.rateLimited(retryAt: BatchRetryPolicy.retryDate(response.value(forHTTPHeaderField: "Retry-After")), code: code)
                }
                if response.statusCode == 401 || response.statusCode == 403 {
                    throw AppleAPIError.authorizationRejected(statusCode: response.statusCode, code: code, message: message, endpoint: endpoint, environment: environmentName)
                }
                if code == "4040010" { throw AppleAPIError.notFound(code) }
                if code == "4000006" { throw AppleAPIError.invalidTransactionID }
                throw AppleAPIError.apiRejected(statusCode: response.statusCode, code: code, message: message, endpoint: endpoint, environment: environmentName)
            }
            return body
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as AppleAPIError { throw error }
        catch { throw AppleAPIError.network("\(Self.endpointDescription(url.path)) · \(environment.title)：\(error.localizedDescription)") }
    }

    private static func endpointDescription(_ path: String) -> String {
        if path.contains("/transactions/appTransactions/") { return "Get App Transaction Info（App 交易信息）" }
        if path.contains("/transactions/") { return "Get Transaction Info（交易详情）" }
        if path.contains("/v2/history/") { return "Get Transaction History（购买历史）" }
        if path.contains("/v2/refund/lookup/") { return "Get Refund History（退款记录）" }
        if path.contains("/v1/subscriptions/") { return "Get All Subscription Statuses（订阅状态）" }
        if path.contains("/v1/lookup/") { return "Look Up Order ID（订单号查询）" }
        if path.contains("/v1/notifications/history") { return "Get Notification History（通知历史）" }
        if path.contains("/v1/notifications/test") { return "Request Test Notification（测试通知）" }
        return path
    }

    private func parseTransaction(_ raw: Any, fallbackID: String, expectedBundleID: String) throws -> (summary: TransactionSummary, payload: [String: Any]) {
        guard let object = raw as? [String: Any] else { throw AppleAPIError.badResponse }
        let signed = (object["signedTransactionInfo"] as? String) ?? (object["signedTransaction"] as? String)
        guard let signed else { throw AppleAPIError.badResponse }
        let payload = try AppleJWT.verifyAndDecodePayload(signed, expectedBundleID: expectedBundleID)
        return (makeSummary(payload, fallbackID: fallbackID, fallbackBundleID: expectedBundleID), payload)
    }

    private func parseTransactionList(_ raw: Any?, key: String, expectedBundleID: String) throws -> [TransactionSummary] {
        guard let object = raw as? [String: Any], let tokens = object[key] as? [String] else { return [] }
        return try tokens.map { token in
            let payload = try AppleJWT.verifyAndDecodePayload(token, expectedBundleID: expectedBundleID)
            return makeSummary(payload, fallbackID: "", fallbackBundleID: expectedBundleID)
        }
    }

    private func parseSubscriptions(_ raw: Any?, expectedBundleID: String) -> [SubscriptionSummary] {
        guard let object = raw as? [String: Any], let groups = object["data"] as? [[String: Any]] else { return [] }
        return groups.flatMap { group -> [SubscriptionSummary] in
            let items = group["lastTransactions"] as? [[String: Any]] ?? []
            return items.map { item in
                let state = (item["status"] as? Int).map(subscriptionStatus) ?? "未知"
                let transaction = ((item["signedTransactionInfo"] as? String).flatMap { try? AppleJWT.verifyAndDecodePayload($0, expectedBundleID: expectedBundleID) }) ?? [:]
                let renewal = ((item["signedRenewalInfo"] as? String).flatMap { try? AppleJWT.verifyAndDecodePayload($0, expectedBundleID: expectedBundleID) }) ?? [:]
                return SubscriptionSummary(
                    productID: transaction["productId"] as? String ?? "",
                    status: state,
                    expirationDate: dateValue(transaction["expiresDate"]),
                    billingPlanType: localizedBillingPlan(transaction["billingPlanType"] as? String),
                    renewalBillingPlanType: localizedBillingPlan(renewal["renewalBillingPlanType"] as? String),
                    renewalCommitmentInfo: commitmentDescription(renewal["renewalCommitmentInfo"], currency: renewal["currency"] as? String)
                )
            }
        }
    }

    private func parseNotifications(_ raw: [String: Any], expectedBundleID: String) throws -> [NotificationSummary] {
        let records = raw["notificationHistory"] as? [[String: Any]] ?? []
        return try records.map { item in
            let signed = item["signedPayload"] as? String ?? ""
            let payload = try AppleJWT.verifyAndDecodePayload(signed, expectedBundleID: "")
            if let bundleID = (payload["data"] as? [String: Any])?["bundleId"] as? String, bundleID != expectedBundleID { throw AppleAPIError.invalidSignedData }
            let type = payload["notificationType"] as? String ?? "通知"
            let subtype = payload["subtype"] as? String ?? ""
            let attempts = item["sendAttempts"] as? [[String: Any]] ?? []
            let date = dateValue(payload["signedDate"] ?? attempts.first?["attemptDate"])
            let responseCode = attempts.last?["responseCode"] as? Int
            let delivery = responseCode.map { $0 == 200 ? "已送达" : "投递失败（\($0)）" } ?? "状态未知"
            return NotificationSummary(date: date, occurredAt: parseDate(payload["signedDate"] ?? attempts.first?["attemptDate"]), type: notificationTypeName(type), subtype: notificationSubtypeName(subtype), deliveryStatus: delivery, rawPayload: signed)
        }
    }

    private func notificationTypeName(_ type: String) -> String {
        ["SUBSCRIBED": "订阅开始", "DID_RENEW": "订阅续订", "DID_FAIL_TO_RENEW": "续订失败", "EXPIRED": "订阅到期", "REFUND": "退款", "REFUND_DECLINED": "退款被拒", "CONSUMPTION_REQUEST": "消费信息请求", "ONE_TIME_CHARGE": "一次性购买", "DID_CHANGE_RENEWAL_STATUS": "续订状态变更", "DID_CHANGE_RENEWAL_PREF": "续订方案变更", "REVOKE": "家庭共享撤销", "OFFER_REDEEMED": "已兑换订阅优惠", "GRACE_PERIOD_EXPIRED": "计费宽限期结束", "RENEWAL_EXTENDED": "续订日期已延长", "RENEWAL_EXTENSION": "续订日期延长处理", "PRICE_INCREASE": "订阅价格调整", "TEST": "测试通知", "EXTERNAL_PURCHASE_TOKEN": "外部购买令牌", "RESCIND_CONSENT": "监护人撤回同意"][type] ?? type
    }

    private func notificationSubtypeName(_ subtype: String) -> String {
        ["INITIAL_BUY": "首次订阅", "RESUBSCRIBE": "重新订阅", "AUTO_RENEW_DISABLED": "已关闭自动续订", "AUTO_RENEW_ENABLED": "已开启自动续订", "BILLING_RECOVERY": "扣款恢复", "BILLING_RETRY": "账单重试后到期", "DOWNGRADE": "降级", "UPGRADE": "升级", "GRACE_PERIOD": "计费宽限期", "VOLUNTARY": "主动取消后到期", "PRICE_INCREASE": "未同意价格调整", "PRODUCT_NOT_FOR_SALE": "商品已停售", "ACCEPTED": "已接受价格调整", "PENDING": "等待确认", "SUMMARY": "汇总", "FAILURE": "处理失败", "CREATED": "已创建", "UNREPORTED": "尚未上报", "ACTIVE_TOKEN_REMINDER": "有效令牌提醒"][subtype] ?? subtype
    }

    private func buildTimeline(transactions: [TransactionSummary], refunds: [TransactionSummary], notifications: [NotificationSummary]) -> [TimelineEvent] {
        var events: [TimelineEvent] = []
        events.reserveCapacity(transactions.count + refunds.count + notifications.count)

        for transaction in transactions {
            if let date = transaction.purchasedAt {
                events.append(TimelineEvent(
                    occurredAt: date,
                    title: "购买",
                    detail: transactionTimelineDetail(transaction, isRefund: false),
                    identifier: transaction.transactionID.isEmpty ? "" : "Transaction ID: \(transaction.transactionID)",
                    secondaryIdentifier: transaction.originalTransactionID.isEmpty ? "" : "Original Transaction ID: \(transaction.originalTransactionID)",
                    symbol: "cart",
                    isWarning: false
                ))
            }
        }
        for transaction in refunds {
            if let date = transaction.revokedAt {
                events.append(TimelineEvent(
                    occurredAt: date,
                    title: "Apple 已批准退款",
                    detail: transactionTimelineDetail(transaction, isRefund: true),
                    identifier: transaction.transactionID.isEmpty ? "" : "Transaction ID: \(transaction.transactionID)",
                    secondaryIdentifier: transaction.originalTransactionID.isEmpty ? "" : "Original Transaction ID: \(transaction.originalTransactionID)",
                    symbol: "arrow.uturn.backward.circle",
                    isWarning: true
                ))
            }
        }
        for notification in notifications {
            if let date = notification.occurredAt {
                let title = notification.subtype.isEmpty ? notification.type : "\(notification.type) · \(notification.subtype)"
                events.append(TimelineEvent(
                    occurredAt: date,
                    title: title,
                    detail: "Apple 通知 · \(notification.deliveryStatus)",
                    identifier: "",
                    secondaryIdentifier: "",
                    symbol: "bell",
                    isWarning: notification.isFailure
                ))
            }
        }

        var seen = Set<String>()
        seen.reserveCapacity(events.count)
        return events.sorted { $0.occurredAt < $1.occurredAt }.filter { event in
            seen.insert(event.id).inserted
        }
    }

    private func transactionTimelineDetail(_ transaction: TransactionSummary, isRefund: Bool) -> String {
        var parts = ["商品：\(transaction.productName.isEmpty ? transaction.productID : transaction.productName)"]
        if !transaction.productID.isEmpty { parts.append("Product ID: \(transaction.productID)") }
        if isRefund {
            if !transaction.refundType.isEmpty { parts.append("退款类型：\(transaction.refundType)") }
            if !transaction.refundReason.isEmpty { parts.append("退款原因：\(transaction.refundReason)") }
            if !transaction.refundPercentage.isEmpty { parts.append("退款比例：\(transaction.refundPercentage)") }
        } else {
            if !transaction.price.isEmpty { parts.append("金额：\(transaction.price)") }
            if !transaction.quantity.isEmpty { parts.append("数量：\(transaction.quantity)") }
            if !transaction.transactionReason.isEmpty { parts.append("交易原因：\(transaction.transactionReason)") }
        }
        return parts.joined(separator: "  ·  ")
    }

    private func makeSummary(_ payload: [String: Any], fallbackID: String, fallbackBundleID: String) -> TransactionSummary {
        let revoked = payload["revocationDate"] != nil
        let status = revoked ? "已撤销 / 退款" : "已购买"
        let refundReasonCode = (payload["revocationReason"] as? NSNumber)?.intValue
        let refundTypeRaw = payload["revocationType"] as? String ?? ""
        let offerCode = (payload["offerType"] as? NSNumber)?.intValue
        let appAccountToken = payload["appAccountToken"] as? String ?? ""
        let quantity = (payload["quantity"] as? NSNumber).map { String($0.intValue) } ?? ""
        let refundPercentage = ((payload["revocationPercentage"] as? NSNumber)?.doubleValue).map { "\(Int($0 / 1000))%" } ?? ""
        let productID = payload["productId"] as? String ?? ""
        let bundleID = payload["bundleId"] as? String ?? fallbackBundleID
        let ownershipRaw = payload["inAppOwnershipType"] as? String
        let ownership = ownershipRaw == "FAMILY_SHARED" ? "家庭共享" : ownershipRaw.map { _ in "本人购买" } ?? ""
        let price = formattedPrice(payload["price"], currency: payload["currency"] as? String)
        let purchaseDate = payload["purchaseDate"]
        let originalPurchaseDate = payload["originalPurchaseDate"]
        let revocationDate = payload["revocationDate"]
        let typeString = payload["type"] as? String ?? ""
        let isSub = typeString == "Auto-Renewable Subscription" || typeString == "Non-Renewing Subscription"
        let billingPlanType = localizedBillingPlan(payload["billingPlanType"] as? String)
        let commitmentInfo = commitmentDescription(payload["transactionCommitmentInfo"], currency: payload["currency"] as? String)

        return TransactionSummary(
            transactionID: payload["transactionId"] as? String ?? fallbackID,
            originalTransactionID: payload["originalTransactionId"] as? String ?? "",
            bundleID: bundleID,
            productID: productID,
            productName: ProductCatalog.lookupName(for: productID),
            status: status,
            purchaseDate: dateValue(purchaseDate),
            originalPurchaseDate: dateValue(originalPurchaseDate),
            expirationDate: dateValue(payload["expiresDate"]),
            revocationDate: dateValue(revocationDate),
            price: price,
            storefront: payload["storefront"] as? String ?? "",
            ownership: ownership,
            productType: localizedProductType(typeString),
            billingPlanType: billingPlanType,
            commitmentInfo: commitmentInfo,
            transactionReason: localizedTransactionReason(payload["transactionReason"] as? String ?? ""),
            refundType: localizedRevocationType(refundTypeRaw),
            refundReason: refundReasonCode.map(localizedRefundReason) ?? "",
            refundPercentage: refundPercentage,
            offerType: offerCode.map(localizedOfferType) ?? "",
            offerIdentifier: payload["offerIdentifier"] as? String ?? "",
            appAccountToken: appAccountToken,
            quantity: quantity,
            isSubscription: isSub,
            refundCaveat: "退款记录只显示 Apple 已批准的退款，不代表用户是否提交过退款申请。",
            purchasedAt: parseDate(purchaseDate),
            originalPurchasedAt: parseDate(originalPurchaseDate),
            revokedAt: parseDate(revocationDate)
        )
    }

    private func localizedProductType(_ value: String) -> String {
        ["Consumable": "消耗型商品", "Non-Consumable": "非消耗型商品", "Auto-Renewable Subscription": "自动续期订阅", "Non-Renewing Subscription": "非续期订阅"][value] ?? value
    }
    private func localizedBillingPlan(_ value: String?) -> String {
        switch value {
        case "BILLED_UPFRONT": return "预付"
        case "MONTHLY": return "按月付费"
        default: return value ?? ""
        }
    }
    private func commitmentDescription(_ value: Any?, currency: String?) -> String {
        guard let info = value as? [String: Any] else { return "" }
        var parts: [String] = []
        if let current = info["billingPeriodNumber"] { parts.append("第 \(current) 期") }
        if let total = info["totalBillingPeriods"] { parts.append("共 \(total) 期") }
        let endDate = dateValue(info["commitmentExpiresDate"])
        if !endDate.isEmpty { parts.append("承诺结束：\(endDate)") }
        let price = formattedPrice(info["commitmentPrice"] ?? info["commitmentRenewalPrice"], currency: currency)
        if !price.isEmpty { parts.append("承诺价格：\(price)") }
        return parts.joined(separator: "，")
    }
    private func localizedTransactionReason(_ value: String) -> String {
        ["PURCHASE": "用户发起购买", "RENEWAL": "订阅自动续期"][value] ?? value
    }
    private func localizedRefundReason(_ value: Int) -> String {
        [0: "其他原因（也可能是家庭共享撤销）", 1: "应用存在实际或感知问题"][value] ?? "未知原因（\(value)）"
    }
    private func localizedRevocationType(_ value: String) -> String {
        ["REFUND_FULL": "全额退款", "REFUND_PRORATED": "按比例退款", "FAMILY_REVOKE": "家庭共享资格撤销"][value] ?? value
    }
    private func localizedOfferType(_ value: Int) -> String {
        [1: "订阅入门优惠", 2: "促销优惠", 3: "优惠码", 4: "挽回优惠"][value] ?? "其他优惠（\(value)）"
    }
    private func parseDate(_ value: Any?) -> Date? {
        let milliseconds = (value as? NSNumber)?.doubleValue ?? Double(value as? String ?? "") ?? 0
        guard milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
    private func dateValue(_ value: Any?) -> String {
        parseDate(value)?.formatted(.dateTime.locale(Self.zhCNLocale).year().month().day().hour().minute().second()) ?? ""
    }
    private func formattedPrice(_ value: Any?, currency: String?) -> String {
        guard let amount = (value as? NSNumber)?.doubleValue, let currency else { return "" }
        Self.currencyFormattersLock.lock()
        let format: NumberFormatter
        if let cached = Self.currencyFormatters[currency] {
            format = cached
        } else {
            let f = NumberFormatter()
            f.numberStyle = .currency
            f.currencyCode = currency
            Self.currencyFormatters[currency] = f
            format = f
        }
        let formatted = format.string(from: NSNumber(value: amount / 1000)) ?? ""
        Self.currencyFormattersLock.unlock()
        return formatted
    }
    private func subscriptionStatus(_ status: Int) -> String { [1: "有效", 2: "已过期", 3: "账单重试", 4: "计费宽限期", 5: "已撤销"][status] ?? "未知" }
}

// MARK: - Apple JWT & JWS Inspector
enum AppleJWT {
    private struct CachedToken {
        let token: String
        let expiresAt: Int
        let cacheKey: String
    }
    private static var cachedToken: CachedToken?
    private static var cachedPrivateKey: (pem: String, key: P256.Signing.PrivateKey)?
    private static let lock = NSLock()

    static func make(settings: InspectorSettings, privateKey: String) throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        let cacheKey = "\(settings.issuerID):\(settings.keyID):\(settings.bundleID):\(privateKey.hashValue)"

        lock.lock()
        if let current = cachedToken, current.cacheKey == cacheKey, current.expiresAt > now + 60 {
            let token = current.token
            lock.unlock()
            return token
        }

        let signingKey: P256.Signing.PrivateKey
        if let cachedKey = cachedPrivateKey, cachedKey.pem == privateKey {
            signingKey = cachedKey.key
        } else {
            let newKey = try P256.Signing.PrivateKey(pemRepresentation: privateKey)
            cachedPrivateKey = (pem: privateKey, key: newKey)
            signingKey = newKey
        }
        lock.unlock()

        let header: [String: Any] = ["alg": "ES256", "kid": settings.keyID, "typ": "JWT"]
        let exp = now + 300
        let payload: [String: Any] = ["iss": settings.issuerID, "iat": now, "exp": exp, "aud": "appstoreconnect-v1", "bid": settings.bundleID]
        let encodedHeader = try encode(header), encodedPayload = try encode(payload)
        let input = "\(encodedHeader).\(encodedPayload)"
        let signature = try signingKey.signature(for: Data(input.utf8))
        let raw = signature.derRepresentation
        let jwtSignature = try P256.Signing.ECDSASignature(derRepresentation: raw).rawRepresentation
        let token = "\(input).\(jwtSignature.base64URLEncodedString())"

        lock.lock()
        cachedToken = CachedToken(token: token, expiresAt: exp, cacheKey: cacheKey)
        lock.unlock()

        return token
    }

    static func decodePayload(_ token: String) throws -> [String: Any] {
        let pieces = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard pieces.count == 3, let data = Data(base64URL: String(pieces[1])), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppleAPIError.badResponse }
        return object
    }

    static func verifyAndDecodePayload(_ token: String, expectedBundleID: String) throws -> [String: Any] {
        let pieces = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard pieces.count == 3,
              let headerData = Data(base64URL: String(pieces[0])),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "ES256",
              let chain = header["x5c"] as? [String], chain.count == 3,
              let payloadData = Data(base64URL: String(pieces[1])),
              let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let signatureData = Data(base64URL: String(pieces[2])) else { throw AppleAPIError.badResponse }
        let certificates = try chain.map { value -> SecCertificate in
            guard let data = Data(base64Encoded: value), let certificate = SecCertificateCreateWithData(nil, data as CFData) else { throw AppleAPIError.badResponse }
            return certificate
        }
        guard certificates.count == 3 else { throw AppleAPIError.badResponse }
        guard hasCertificateExtension(certificates[0], oid: "1.2.840.113635.100.6.11.1"),
              hasCertificateExtension(certificates[1], oid: "1.2.840.113635.100.6.2.1") else { throw AppleAPIError.invalidSignedData }
        let policy = SecPolicyCreateBasicX509()
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust)
        guard status == errSecSuccess, let trust else { throw AppleAPIError.invalidSignedData }
        SecTrustSetNetworkFetchAllowed(trust, false)
        guard SecTrustEvaluateWithError(trust, nil),
              let publicKey = SecCertificateCopyKey(certificates[0]),
              signatureData.count == 64 else { throw AppleAPIError.invalidSignedData }
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        let signingInput = Data("\(pieces[0]).\(pieces[1])".utf8)
        guard let keyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              let verifier = try? P256.Signing.PublicKey(x963Representation: keyData),
              verifier.isValidSignature(signature, for: signingInput) else { throw AppleAPIError.invalidSignedData }
        if let bundleID = payload["bundleId"] as? String, !expectedBundleID.isEmpty, bundleID != expectedBundleID { throw AppleAPIError.invalidSignedData }
        return payload
    }

    static func inspectJWS(_ tokenString: String) -> JWSInspectionResult {
        let token = tokenString.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = token.split(separator: ".")
        guard pieces.count == 3 else {
            return JWSInspectionResult(isValidSignature: false, isAppleRootTrusted: false, headerJSON: "{}", payloadJSON: "{}", summaryItems: [], certificateChainSummaries: [], errorMessage: "无效的 JWS 格式（必须是由点号 '.' 分隔的 3 段 Base64URL 字符串）")
        }

        guard let headerData = Data(base64URL: String(pieces[0])),
              let headerObj = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let payloadData = Data(base64URL: String(pieces[1])),
              let payloadObj = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return JWSInspectionResult(isValidSignature: false, isAppleRootTrusted: false, headerJSON: "{}", payloadJSON: "{}", summaryItems: [], certificateChainSummaries: [], errorMessage: "Header 或 Payload 无法作为 JSON 解析")
        }

        let headerJSON = (try? String(data: JSONSerialization.data(withJSONObject: headerObj, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)) ?? "{}"
        let payloadJSON = (try? String(data: JSONSerialization.data(withJSONObject: payloadObj, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)) ?? "{}"

        // 提取摘要字段
        var summaries: [(key: String, value: String)] = []
        if let tid = payloadObj["transactionId"] as? String { summaries.append(("Transaction ID", tid)) }
        if let otid = payloadObj["originalTransactionId"] as? String { summaries.append(("Original Transaction ID", otid)) }
        if let bid = payloadObj["bundleId"] as? String { summaries.append(("Bundle ID", bid)) }
        if let pid = payloadObj["productId"] as? String { summaries.append(("Product ID", pid)) }
        if let value = payloadObj["subscriptionGroupIdentifier"] as? String { summaries.append(("订阅组 ID", value)) }
        if let value = payloadObj["webOrderLineItemId"] as? String { summaries.append(("订阅订单行 ID", value)) }
        if let value = payloadObj["storefrontId"] as? String { summaries.append(("商店地区 ID", value)) }
        if let value = payloadObj["appAccountToken"] as? String { summaries.append(("App Account Token", value)) }
        if let value = payloadObj["autoRenewProductId"] as? String { summaries.append(("下次续订商品 ID", value)) }
        if let value = payloadObj["autoRenewStatus"] { summaries.append(("自动续订状态", String(describing: value) == "1" ? "已开启" : "已关闭")) }
        if let value = payloadObj["isInBillingRetryPeriod"] as? Bool { summaries.append(("是否账单重试", value ? "是" : "否")) }
        if let value = payloadObj["gracePeriodExpiresDate"] as? NSNumber {
            let date = Date(timeIntervalSince1970: value.doubleValue / 1000)
            summaries.append(("宽限期结束时间", date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month().day().hour().minute().second())))
        }
        if let value = payloadObj["offerPeriod"] as? String { summaries.append(("优惠周期", value)) }
        if let value = payloadObj["transactionReason"] as? String { summaries.append(("交易原因", value == "PURCHASE" ? "用户购买" : value == "RENEWAL" ? "自动续订" : value)) }
        if let value = payloadObj["billingPlanType"] as? String { summaries.append(("计费计划", value == "BILLED_UPFRONT" ? "预付" : value == "MONTHLY" ? "按月付费" : value)) }
        if let value = payloadObj["renewalBillingPlanType"] as? String { summaries.append(("续订计费计划", value == "BILLED_UPFRONT" ? "预付" : value == "MONTHLY" ? "按月付费" : value)) }
        if let value = payloadObj["offerDiscountType"] as? String {
            let name = ["FREE_TRIAL": "免费试用", "PAY_AS_YOU_GO": "按周期付费优惠", "PAY_UP_FRONT": "预付优惠", "ONE_TIME": "一次性优惠"][value] ?? value
            summaries.append(("优惠折扣类型", name))
        }
        if let value = payloadObj["priceIncreaseStatus"] { summaries.append(("价格调整状态", String(describing: value))) }
        if let values = payloadObj["eligibleWinBackOfferIds"] as? [String], !values.isEmpty { summaries.append(("符合资格的挽回优惠", values.joined(separator: ", "))) }
        for (field, title) in [("transactionCommitmentInfo", "交易承诺信息"), ("renewalCommitmentInfo", "续订承诺信息")] {
            if let value = payloadObj[field], JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                summaries.append((title, json))
            }
        }
        if let type = payloadObj["type"] as? String { summaries.append(("Type", type)) }
        if let nType = payloadObj["notificationType"] as? String { summaries.append(("Notification Type", nType)) }
        if let nSub = payloadObj["subtype"] as? String { summaries.append(("Subtype", nSub)) }
        if let date = payloadObj["purchaseDate"] as? NSNumber {
            let d = Date(timeIntervalSince1970: date.doubleValue / 1000)
            summaries.append(("Purchase Date", d.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month().day().hour().minute().second())))
        }
        if let date = payloadObj["expiresDate"] as? NSNumber {
            let d = Date(timeIntervalSince1970: date.doubleValue / 1000)
            summaries.append(("Expires Date", d.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month().day().hour().minute().second())))
        }

        // 验证签名与证书
        guard let chain = headerObj["x5c"] as? [String], chain.count == 3,
              let signatureData = Data(base64URL: String(pieces[2])), signatureData.count == 64 else {
            return JWSInspectionResult(isValidSignature: false, isAppleRootTrusted: false, headerJSON: headerJSON, payloadJSON: payloadJSON, summaryItems: summaries, certificateChainSummaries: ["缺少有效 x5c 证书链或签名长度错误"], errorMessage: "x5c 证书链缺失或签名不是 64 字节 ES256 签名")
        }

        let certificates = chain.compactMap { value -> SecCertificate? in
            guard let d = Data(base64Encoded: value) else { return nil }
            return SecCertificateCreateWithData(nil, d as CFData)
        }
        guard certificates.count == 3 else {
            return JWSInspectionResult(isValidSignature: false, isAppleRootTrusted: false, headerJSON: headerJSON, payloadJSON: payloadJSON, summaryItems: summaries, certificateChainSummaries: [], errorMessage: "证书链解码失败")
        }

        let leafHasExt = hasCertificateExtension(certificates[0], oid: "1.2.840.113635.100.6.11.1")
        let intermediateHasExt = hasCertificateExtension(certificates[1], oid: "1.2.840.113635.100.6.2.1")

        let policy = SecPolicyCreateBasicX509()
        var trust: SecTrust?
        let trustStatus = SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust)
        var isRootTrusted = false
        if trustStatus == errSecSuccess, let trust {
            SecTrustSetNetworkFetchAllowed(trust, false)
            isRootTrusted = SecTrustEvaluateWithError(trust, nil) && leafHasExt && intermediateHasExt
        }

        var isValidSig = false
        if let publicKey = SecCertificateCopyKey(certificates[0]),
           let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData),
           let keyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
           let verifier = try? P256.Signing.PublicKey(x963Representation: keyData) {
            let signingInput = Data("\(pieces[0]).\(pieces[1])".utf8)
            isValidSig = verifier.isValidSignature(sig, for: signingInput)
        }

        var certDescs: [String] = []
        for (idx, cert) in certificates.enumerated() {
            var commonName: CFString?
            SecCertificateCopyCommonName(cert, &commonName)
            let name = (commonName as String?) ?? "未知证书"
            let role = idx == 0 ? "叶子证书 (Leaf)" : idx == 1 ? "中间证书 (Intermediate)" : "根证书 (Root)"
            certDescs.append("\(role): \(name)")
        }

        return JWSInspectionResult(
            isValidSignature: isValidSig,
            isAppleRootTrusted: isRootTrusted,
            headerJSON: headerJSON,
            payloadJSON: payloadJSON,
            summaryItems: summaries,
            certificateChainSummaries: certDescs,
            errorMessage: isValidSig ? nil : "签名验证未通过（签名与公钥不匹配）"
        )
    }

    private static func hasCertificateExtension(_ certificate: SecCertificate, oid: String) -> Bool {
        var error: Unmanaged<CFError>?
        guard let values = SecCertificateCopyValues(certificate, [oid as CFString] as CFArray, &error) as? [String: Any] else { return false }
        return values[oid] != nil
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    init?(base64URL: String) {
        var value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder > 0 { value += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: value)
    }
}

// MARK: - Keychain Store
enum KeychainStore {
    private static let service = "gg.leon.IAP-Inspector.apple-api"
    private static let account = "private-key"
    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }
    static func save(_ value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecItemNotFound {
            let add: [String: Any] = query.merging([
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw AppleAPIError.network("无法写入 macOS Keychain（\(addStatus)）") }
        } else if updateStatus != errSecSuccess {
            throw AppleAPIError.network("无法更新 macOS Keychain（\(updateStatus)）")
        }
    }
    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum ReceiptSecretStore {
    private static let service = "gg.leon.IAP-Inspector.receipt"
    private static let account = "shared-secret"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            let add = query.merging([
                kSecValueData as String: Data(value.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]) { _, new in new }
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw AppleAPIError.network("无法写入 macOS Keychain（\(status)）") }
        } else if updateStatus != errSecSuccess {
            throw AppleAPIError.network("无法更新 macOS Keychain（\(updateStatus)）")
        }
    }

    static func delete() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }
}
