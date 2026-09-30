import Foundation
import Security
import CryptoKit

// MARK: - Receipt Models

struct ParsedReceiptItem: Identifiable, Codable {
    var id: String { "\(transactionID)-\(purchaseDate)" }
    var productID: String
    var productName: String
    var transactionID: String
    var originalTransactionID: String
    var purchaseDate: String
    var originalPurchaseDate: String
    var expirationDate: String
    var cancellationDate: String
    var quantity: String
    var webOrderLineItemID: String
    var isIntroOffer: Bool
    var status: String
}

struct ParsedRenewalInfo: Identifiable, Codable {
    var id: String { "\(productID)-\(originalTransactionID)" }
    var productID: String
    var productName: String
    var originalTransactionID: String
    var autoRenewStatus: String
    var autoRenewProductID: String
    var expirationIntent: String
    var isInBillingRetry: String
    var gracePeriodExpiresDate: String
    var priceConsentStatus: String
}

enum ReceiptSource: String, Codable {
    case offlineASN1 = "本地 ASN.1 离线解码"
    case verifyReceiptProduction = "Apple 在线验证 (Production)"
    case verifyReceiptSandbox = "Apple 在线验证 (Sandbox)"
}

struct ReceiptInspectionResult: Identifiable {
    var id = UUID()
    var source: ReceiptSource
    var bundleID: String
    var appVersion: String
    var originalAppVersion: String
    var receiptCreationDate: String
    var receiptExpirationDate: String
    var environment: String
    var inAppPurchases: [ParsedReceiptItem]
    var renewalInfos: [ParsedRenewalInfo]
    var certificateChain: [String]
    var isSignatureValid: Bool
    var isAppleRootTrusted: Bool
    var rawJSON: String
    var diagnosticNotes: [String]
}

// MARK: - ASN.1 TLV Node

final class ASN1Node {
    let tag: UInt8
    let tagClass: UInt8
    let isConstructed: Bool
    let tagNumber: UInt
    let headerLength: Int
    let data: Data
    let valueData: Data
    var children: [ASN1Node] = []

    init(tag: UInt8, tagClass: UInt8, isConstructed: Bool, tagNumber: UInt, headerLength: Int, data: Data, valueData: Data) {
        self.tag = tag
        self.tagClass = tagClass
        self.isConstructed = isConstructed
        self.tagNumber = tagNumber
        self.headerLength = headerLength
        self.data = data
        self.valueData = valueData
    }

    func child(at index: Int) -> ASN1Node? {
        guard index >= 0 && index < children.count else { return nil }
        return children[index]
    }

    func childWithTag(_ tag: UInt8) -> ASN1Node? {
        children.first { $0.tag == tag }
    }

    func childrenWithTag(_ tag: UInt8) -> [ASN1Node] {
        children.filter { $0.tag == tag }
    }
}

// MARK: - ASN.1 Parser

enum ASN1Parser {
    static func parse(data: Data) -> [ASN1Node] {
        var nodes: [ASN1Node] = []
        var offset = 0
        while offset < data.count {
            guard let node = parseNode(data: data, offset: &offset) else { break }
            nodes.append(node)
        }
        return nodes
    }

    private static func parseNode(data: Data, offset: inout Int) -> ASN1Node? {
        guard offset < data.count else { return nil }
        let startOffset = offset
        let firstByte = data[offset]
        offset += 1

        let tagClass = (firstByte & 0xC0) >> 6
        let isConstructed = (firstByte & 0x20) != 0
        var tagNumber = UInt(firstByte & 0x1F)

        if tagNumber == 0x1F {
            tagNumber = 0
            while offset < data.count {
                let byte = data[offset]
                offset += 1
                tagNumber = (tagNumber << 7) | UInt(byte & 0x7F)
                if (byte & 0x80) == 0 { break }
            }
        }

        guard offset < data.count else { return nil }
        let lengthByte = data[offset]
        offset += 1

        var length: Int = 0
        if lengthByte < 0x80 {
            length = Int(lengthByte)
        } else if lengthByte == 0x80 {
            // Indefinite length
            length = findIndefiniteLength(data: data, startOffset: offset)
        } else {
            let numBytes = Int(lengthByte & 0x7F)
            guard numBytes <= 4, offset + numBytes <= data.count else { return nil }
            for _ in 0..<numBytes {
                length = (length << 8) | Int(data[offset])
                offset += 1
            }
        }

        guard offset + length <= data.count else { return nil }
        let headerLength = offset - startOffset
        let valueRange = offset..<(offset + length)
        let totalRange = startOffset..<(offset + length)
        let valueData = data.subdata(in: valueRange)
        let totalData = data.subdata(in: totalRange)
        offset += length

        let node = ASN1Node(
            tag: firstByte,
            tagClass: tagClass,
            isConstructed: isConstructed,
            tagNumber: tagNumber,
            headerLength: headerLength,
            data: totalData,
            valueData: valueData
        )

        if isConstructed || (firstByte == 0x04 && mightBeConstructedASN1(valueData)) {
            node.children = parse(data: valueData)
        }

        return node
    }

    private static func findIndefiniteLength(data: Data, startOffset: Int) -> Int {
        var offset = startOffset
        while offset + 1 < data.count {
            if data[offset] == 0x00 && data[offset + 1] == 0x00 {
                let len = offset - startOffset
                return len
            }
            offset += 1
        }
        return data.count - startOffset
    }

    private static func mightBeConstructedASN1(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let tag = data[0]
        return tag == 0x30 || tag == 0x31 || tag == 0xA0
    }

    static func parseInteger(_ data: Data) -> Int64? {
        guard !data.isEmpty else { return nil }
        var result: Int64 = 0
        let isNegative = (data[0] & 0x80) != 0
        if isNegative {
            result = -1
        }
        for byte in data {
            result = (result << 8) | Int64(byte)
        }
        return result
    }

    static func parseString(_ data: Data) -> String? {
        if let str = String(data: data, encoding: .utf8) { return str }
        if let str = String(data: data, encoding: .ascii) { return str }
        return nil
    }

    static func parseDateString(_ data: Data) -> String? {
        guard let str = parseString(data)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return formatReceiptDate(str)
    }

    static func formatReceiptDate(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        // Try standard ISO8601 / RFC3339
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: trimmed) {
            return formatDate(date)
        }
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: trimmed) {
            return formatDate(date)
        }

        // Try custom date formatters
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss 'Etc/GMT'",
            "yyyy-MM-dd HH:mm:ss 'GMT'",
            "yyyy-MM-dd HH:mm:ss 'UTC'",
            "yyyy-MM-dd HH:mm:ss",
            "yyMMddHHmmssZ",
            "yyyyMMddHHmmssZ"
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)

        for format in formats {
            df.dateFormat = format
            if let date = df.date(from: trimmed) {
                return formatDate(date)
            }
        }

        // Try epoch timestamp (ms or s)
        if let num = Double(trimmed) {
            let date = num > 100_000_000_000 ? Date(timeIntervalSince1970: num / 1000) : Date(timeIntervalSince1970: num)
            return formatDate(date)
        }

        return trimmed
    }

    private static func formatDate(_ date: Date) -> String {
        date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month().day().hour().minute().second())
    }
}

// MARK: - PKCS#7 / ASN.1 Receipt Parser

enum PKCS7ReceiptParser {
    static func parse(receiptData: Data) -> ReceiptInspectionResult {
        let rootNodes = ASN1Parser.parse(data: receiptData)
        guard let root = rootNodes.first else {
            return makeEmptyResult(error: "无法解析 ASN.1 根节点，请确认输入数据是否为有效的 Apple Receipt 二进制或 Base64。")
        }

        // Search for PKCS#7 payload or direct receipt attributes
        var payloadData: Data?
        var certificates: [SecCertificate] = []

        // Extract certificates and payload from PKCS#7 structure
        extractPKCS7Elements(node: root, payloadData: &payloadData, certificates: &certificates)

        let targetData = payloadData ?? receiptData
        return parsePayloadAttributes(data: targetData, certificates: certificates, rawData: receiptData)
    }

    private static func extractPKCS7Elements(node: ASN1Node, payloadData: inout Data?, certificates: inout [SecCertificate]) {
        // Find certificates in context tag [0] (0xA0)
        if node.tag == 0xA0 {
            for child in node.children {
                if child.tag == 0x30 { // SEQUENCE representing Certificate
                    if let cert = SecCertificateCreateWithData(nil, child.data as CFData) {
                        certificates.append(cert)
                    }
                }
            }
        }

        // Find ContentInfo / OCTET STRING containing the receipt attributes
        // Check for OID 1.2.840.113549.1.7.1 (data)
        if node.tag == 0x06 {
            let oidData = node.valueData
            let dataOID = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01]) // 1.2.840.113549.1.7.1
            if oidData == dataOID {
                // Next sibling or parent context usually holds the payload
            }
        }

        // If this node is OCTET STRING (0x04) or context tag [0] (0xA0) that contains a SET (0x31)
        if node.tag == 0x04 || node.tag == 0xA0 {
            if let childSet = node.children.first(where: { $0.tag == 0x31 }) {
                payloadData = childSet.data
            } else if let childSeq = node.children.first(where: { $0.tag == 0x30 }) {
                if childSeq.children.contains(where: { $0.tag == 0x31 }) {
                    payloadData = childSeq.data
                }
            }
        }

        for child in node.children {
            extractPKCS7Elements(node: child, payloadData: &payloadData, certificates: &certificates)
        }
    }

    private static func parsePayloadAttributes(data: Data, certificates: [SecCertificate], rawData: Data) -> ReceiptInspectionResult {
        var bundleID = ""
        var appVersion = ""
        var originalAppVersion = ""
        var receiptCreationDate = ""
        var receiptExpirationDate = ""
        var inAppPurchases: [ParsedReceiptItem] = []
        var diagnosticNotes: [String] = []

        let nodes = ASN1Parser.parse(data: data)
        let setNode = findFirstSetNode(in: nodes) ?? nodes.first

        if let setNode {
            for attrSeq in setNode.children where attrSeq.tag == 0x30 {
                // Attribute: SEQUENCE { type INTEGER, version INTEGER, value OCTET STRING }
                guard attrSeq.children.count >= 3,
                      let typeNode = attrSeq.child(at: 0),
                      let type = ASN1Parser.parseInteger(typeNode.valueData),
                      let valueNode = attrSeq.child(at: 2) else { continue }

                let valData = valueNode.valueData

                switch type {
                case 2: // Bundle ID
                    if let val = parseInnerString(valData) { bundleID = val }
                case 3: // Application Version
                    if let val = parseInnerString(valData) { appVersion = val }
                case 12: // Receipt Creation Date
                    if let val = parseInnerDateString(valData) { receiptCreationDate = val }
                case 19: // Original Application Version
                    if let val = parseInnerString(valData) { originalAppVersion = val }
                case 21: // Receipt Expiration Date
                    if let val = parseInnerDateString(valData) { receiptExpirationDate = val }
                case 17: // In-App Purchase Attribute
                    if let item = parseInAppItem(valData) {
                        inAppPurchases.append(item)
                    }
                default:
                    break
                }
            }
        }

        // Sort in-app purchases by purchase date descending
        inAppPurchases.sort { $0.purchaseDate > $1.purchaseDate }

        // Evaluate Certificate Chain
        var certDescs: [String] = []
        var isAppleRootTrusted = false
        var isSignatureValid = false

        if !certificates.isEmpty {
            for (idx, cert) in certificates.enumerated() {
                var commonName: CFString?
                SecCertificateCopyCommonName(cert, &commonName)
                let name = (commonName as String?) ?? "未知证书"
                let role = idx == 0 ? "签名证书 (Leaf)" : idx == 1 ? "中间证书 (Intermediate)" : "根证书 (Root)"
                certDescs.append("\(role): \(name)")
            }

            let policy = SecPolicyCreateBasicX509()
            var trust: SecTrust?
            let status = SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust)
            if status == errSecSuccess, let trust {
                SecTrustSetNetworkFetchAllowed(trust, false)
                isAppleRootTrusted = SecTrustEvaluateWithError(trust, nil)
                isSignatureValid = isAppleRootTrusted
            }
        }

        if bundleID.isEmpty && inAppPurchases.isEmpty {
            diagnosticNotes.append("未能从 Payload 中解析出标准 Apple Receipt 字段，可能缺少对应 ASN.1 属性或数据被损坏。")
        } else {
            diagnosticNotes.append("成功解码 \(inAppPurchases.count) 笔内购交易记录。")
            if !originalAppVersion.isEmpty {
                diagnosticNotes.append("首次下载 App 版本号: \(originalAppVersion)")
            }
        }

        // Build Pretty JSON for display
        let summaryDict: [String: Any] = [
            "bundle_id": bundleID,
            "application_version": appVersion,
            "original_application_version": originalAppVersion,
            "receipt_creation_date": receiptCreationDate,
            "receipt_expiration_date": receiptExpirationDate,
            "in_app_count": inAppPurchases.count,
            "in_app": inAppPurchases.map { item in
                [
                    "product_id": item.productID,
                    "product_name": item.productName,
                    "transaction_id": item.transactionID,
                    "original_transaction_id": item.originalTransactionID,
                    "purchase_date": item.purchaseDate,
                    "original_purchase_date": item.originalPurchaseDate,
                    "expires_date": item.expirationDate,
                    "cancellation_date": item.cancellationDate,
                    "quantity": item.quantity,
                    "web_order_line_item_id": item.webOrderLineItemID
                ]
            }
        ]
        let rawJSON = (try? String(data: JSONSerialization.data(withJSONObject: summaryDict, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)) ?? "{}"

        return ReceiptInspectionResult(
            source: .offlineASN1,
            bundleID: bundleID,
            appVersion: appVersion,
            originalAppVersion: originalAppVersion,
            receiptCreationDate: receiptCreationDate,
            receiptExpirationDate: receiptExpirationDate,
            environment: "本地离线解析 (PKCS#7)",
            inAppPurchases: inAppPurchases,
            renewalInfos: [],
            certificateChain: certDescs,
            isSignatureValid: isSignatureValid,
            isAppleRootTrusted: isAppleRootTrusted,
            rawJSON: rawJSON,
            diagnosticNotes: diagnosticNotes
        )
    }

    private static func findFirstSetNode(in nodes: [ASN1Node]) -> ASN1Node? {
        for node in nodes {
            if node.tag == 0x31 { return node }
            if let found = findFirstSetNode(in: node.children) { return found }
        }
        return nil
    }

    private static func parseInnerString(_ data: Data) -> String? {
        let nodes = ASN1Parser.parse(data: data)
        if let first = nodes.first {
            return ASN1Parser.parseString(first.valueData)
        }
        return ASN1Parser.parseString(data)
    }

    private static func parseInnerDateString(_ data: Data) -> String? {
        let nodes = ASN1Parser.parse(data: data)
        if let first = nodes.first {
            return ASN1Parser.parseDateString(first.valueData)
        }
        return ASN1Parser.parseDateString(data)
    }

    private static func parseInAppItem(_ data: Data) -> ParsedReceiptItem? {
        let nodes = ASN1Parser.parse(data: data)
        let setNode = findFirstSetNode(in: nodes) ?? nodes.first
        guard let setNode else { return nil }

        var quantity = "1"
        var productID = ""
        var transactionID = ""
        var originalTransactionID = ""
        var purchaseDate = ""
        var originalPurchaseDate = ""
        var expirationDate = ""
        var cancellationDate = ""
        var webOrderLineItemID = ""
        var isIntroOffer = false

        for attrSeq in setNode.children where attrSeq.tag == 0x30 {
            guard attrSeq.children.count >= 3,
                  let typeNode = attrSeq.child(at: 0),
                  let type = ASN1Parser.parseInteger(typeNode.valueData),
                  let valueNode = attrSeq.child(at: 2) else { continue }

            let valData = valueNode.valueData

            switch type {
            case 1701: // Quantity
                if let num = parseInnerInteger(valData) { quantity = String(num) }
            case 1702: // Product ID
                if let val = parseInnerString(valData) { productID = val }
            case 1703: // Transaction ID
                if let val = parseInnerString(valData) { transactionID = val }
            case 1704: // Purchase Date
                if let val = parseInnerDateString(valData) { purchaseDate = val }
            case 1705: // Original Transaction ID
                if let val = parseInnerString(valData) { originalTransactionID = val }
            case 1706: // Original Purchase Date
                if let val = parseInnerDateString(valData) { originalPurchaseDate = val }
            case 1708: // Subscription Expiration Date
                if let val = parseInnerDateString(valData) { expirationDate = val }
            case 1711: // Web Order Line Item ID
                if let num = parseInnerInteger(valData) { webOrderLineItemID = String(num) }
                else if let val = parseInnerString(valData) { webOrderLineItemID = val }
            case 1712: // Cancellation Date
                if let val = parseInnerDateString(valData) { cancellationDate = val }
            case 1719: // Is In Intro Offer Period
                if let num = parseInnerInteger(valData) { isIntroOffer = (num != 0) }
            default:
                break
            }
        }

        guard !productID.isEmpty || !transactionID.isEmpty else { return nil }

        let status = !cancellationDate.isEmpty ? "已退款 / 撤销" : (!expirationDate.isEmpty ? "订阅交易" : "已购买")
        let productName = ProductCatalog.lookupName(for: productID)

        return ParsedReceiptItem(
            productID: productID,
            productName: productName,
            transactionID: transactionID,
            originalTransactionID: originalTransactionID,
            purchaseDate: purchaseDate,
            originalPurchaseDate: originalPurchaseDate,
            expirationDate: expirationDate,
            cancellationDate: cancellationDate,
            quantity: quantity,
            webOrderLineItemID: webOrderLineItemID,
            isIntroOffer: isIntroOffer,
            status: status
        )
    }

    private static func parseInnerInteger(_ data: Data) -> Int64? {
        let nodes = ASN1Parser.parse(data: data)
        if let first = nodes.first {
            return ASN1Parser.parseInteger(first.valueData)
        }
        return ASN1Parser.parseInteger(data)
    }

    private static func makeEmptyResult(error: String) -> ReceiptInspectionResult {
        ReceiptInspectionResult(
            source: .offlineASN1,
            bundleID: "",
            appVersion: "",
            originalAppVersion: "",
            receiptCreationDate: "",
            receiptExpirationDate: "",
            environment: "解析失败",
            inAppPurchases: [],
            renewalInfos: [],
            certificateChain: [],
            isSignatureValid: false,
            isAppleRootTrusted: false,
            rawJSON: "{}",
            diagnosticNotes: [error]
        )
    }
}

// MARK: - Online VerifyReceipt Service

final class VerifyReceiptService {
    private let session = URLSession.shared

    func verify(base64Receipt: String, password: String?) async throws -> ReceiptInspectionResult {
        let cleaned = cleanBase64(base64Receipt)
        guard !cleaned.isEmpty else {
            throw AppleAPIError.badResponse
        }

        var requestBody: [String: Any] = [
            "receipt-data": cleaned,
            "exclude-old-transactions": false
        ]
        if let password = password?.trimmingCharacters(in: .whitespacesAndNewlines), !password.isEmpty {
            requestBody["password"] = password
        }

        // Try Production first
        let prodResult = try await executeRequest(url: "https://buy.itunes.apple.com/verifyReceipt", body: requestBody)
        let status = prodResult["status"] as? Int ?? -1

        if status == 21007 {
            // Receipt is from Sandbox, rerun on sandbox
            let sandResult = try await executeRequest(url: "https://sandbox.itunes.apple.com/verifyReceipt", body: requestBody)
            return parseVerifyResponse(sandResult, source: .verifyReceiptSandbox, environment: "Sandbox (沙盒环境)")
        } else if status == 21008 {
            // Receipt is from Production, rerunning on prod
            let retryResult = try await executeRequest(url: "https://buy.itunes.apple.com/verifyReceipt", body: requestBody)
            return parseVerifyResponse(retryResult, source: .verifyReceiptProduction, environment: "Production (生产环境)")
        } else {
            let envName = (prodResult["environment"] as? String) ?? "Production (生产环境)"
            return parseVerifyResponse(prodResult, source: .verifyReceiptProduction, environment: envName)
        }
    }

    private func executeRequest(url: String, body: [String: Any]) async throws -> [String: Any] {
        guard let requestURL = URL(string: url) else { throw AppleAPIError.badResponse }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw AppleAPIError.badResponse }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AppleAPIError.rejected(httpResponse.statusCode, "verifyReceipt 接口响应异常 HTTP \(httpResponse.statusCode)")
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return json
    }

    private func parseVerifyResponse(_ json: [String: Any], source: ReceiptSource, environment: String) -> ReceiptInspectionResult {
        let status = json["status"] as? Int ?? 0
        var diagnosticNotes: [String] = []

        if status != 0 {
            diagnosticNotes.append("Apple 验证状态码异常：\(status) - \(localizedStatusMessage(status))")
        } else {
            diagnosticNotes.append("Apple 官方 verifyReceipt 验证通过 (status: 0)。")
        }

        let receipt = json["receipt"] as? [String: Any] ?? [:]
        let bundleID = (receipt["bundle_id"] as? String) ?? ""
        let appVersion = (receipt["application_version"] as? String) ?? ""
        let originalAppVersion = (receipt["original_application_version"] as? String) ?? ""
        let creationDate = ASN1Parser.formatReceiptDate((receipt["receipt_creation_date"] as? String) ?? (receipt["receipt_creation_date_ms"] as? String) ?? "")
        let expirationDate = ASN1Parser.formatReceiptDate((receipt["receipt_expiration_date"] as? String) ?? "")

        // In-app purchases (combine latest_receipt_info and receipt.in_app)
        let inAppRaw = receipt["in_app"] as? [[String: Any]] ?? []
        let latestRaw = json["latest_receipt_info"] as? [[String: Any]] ?? []
        let allTransactionsRaw = !latestRaw.isEmpty ? latestRaw : inAppRaw

        var inAppPurchases: [ParsedReceiptItem] = []
        for item in allTransactionsRaw {
            let pid = item["product_id"] as? String ?? ""
            let tid = item["transaction_id"] as? String ?? ""
            let otid = item["original_transaction_id"] as? String ?? ""
            let pDate = ASN1Parser.formatReceiptDate((item["purchase_date"] as? String) ?? (item["purchase_date_ms"] as? String) ?? "")
            let opDate = ASN1Parser.formatReceiptDate((item["original_purchase_date"] as? String) ?? (item["original_purchase_date_ms"] as? String) ?? "")
            let expDate = ASN1Parser.formatReceiptDate((item["expires_date"] as? String) ?? (item["expires_date_ms"] as? String) ?? "")
            let cDate = ASN1Parser.formatReceiptDate((item["cancellation_date"] as? String) ?? (item["cancellation_date_ms"] as? String) ?? "")
            let qty = item["quantity"] as? String ?? "1"
            let webOrder = item["web_order_line_item_id"] as? String ?? ""
            let isIntro = (item["is_in_intro_offer_period"] as? String) == "true" || (item["is_in_intro_offer_period"] as? Int) == 1
            let statusText = !cDate.isEmpty ? "已退款 / 撤销" : (!expDate.isEmpty ? "订阅交易" : "已购买")

            inAppPurchases.append(ParsedReceiptItem(
                productID: pid,
                productName: ProductCatalog.lookupName(for: pid),
                transactionID: tid,
                originalTransactionID: otid,
                purchaseDate: pDate,
                originalPurchaseDate: opDate,
                expirationDate: expDate,
                cancellationDate: cDate,
                quantity: qty,
                webOrderLineItemID: webOrder,
                isIntroOffer: isIntro,
                status: statusText
            ))
        }

        inAppPurchases.sort { $0.purchaseDate > $1.purchaseDate }

        // Pending renewal info
        var renewalInfos: [ParsedRenewalInfo] = []
        let pendingRaw = json["pending_renewal_info"] as? [[String: Any]] ?? []
        for info in pendingRaw {
            let pid = info["product_id"] as? String ?? ""
            let autoPid = info["auto_renew_product_id"] as? String ?? pid
            let otid = info["original_transaction_id"] as? String ?? ""
            let autoStatusNum = info["auto_renew_status"] as? String ?? String(info["auto_renew_status"] as? Int ?? 0)
            let autoStatus = autoStatusNum == "1" ? "已开启自动续订" : "已关闭自动续订"
            let intentCode = info["expiration_intent"] as? String ?? String(info["expiration_intent"] as? Int ?? 0)
            let intentText = localizedExpirationIntent(intentCode)
            let retryNum = info["is_in_billing_retry_period"] as? String ?? String(info["is_in_billing_retry_period"] as? Int ?? 0)
            let retryText = retryNum == "1" ? "处于重试扣款中" : "正常"
            let grace = ASN1Parser.formatReceiptDate((info["grace_period_expires_date"] as? String) ?? (info["grace_period_expires_date_ms"] as? String) ?? "")
            let priceConsent = (info["price_consent_status"] as? String) ?? "无需确认"

            renewalInfos.append(ParsedRenewalInfo(
                productID: pid,
                productName: ProductCatalog.lookupName(for: pid),
                originalTransactionID: otid,
                autoRenewStatus: autoStatus,
                autoRenewProductID: autoPid,
                expirationIntent: intentText,
                isInBillingRetry: retryText,
                gracePeriodExpiresDate: grace,
                priceConsentStatus: priceConsent
            ))
        }

        let rawJSON = (try? String(data: JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)) ?? "{}"

        return ReceiptInspectionResult(
            source: source,
            bundleID: bundleID,
            appVersion: appVersion,
            originalAppVersion: originalAppVersion,
            receiptCreationDate: creationDate,
            receiptExpirationDate: expirationDate,
            environment: environment,
            inAppPurchases: inAppPurchases,
            renewalInfos: renewalInfos,
            certificateChain: ["Apple 官方 API 在线验证服务返回"],
            isSignatureValid: status == 0,
            isAppleRootTrusted: true,
            rawJSON: rawJSON,
            diagnosticNotes: diagnosticNotes
        )
    }

    private func localizedStatusMessage(_ status: Int) -> String {
        switch status {
        case 21000: return "App Store 无法读取你提供的 JSON 数据"
        case 21002: return "receipt-data 属性中的数据格式错误或丢失"
        case 21003: return "无法验证此收据"
        case 21004: return "提供的 App 共享密钥 (Shared Secret) 不匹配"
        case 21005: return "收据服务器当前不可用"
        case 21006: return "此收据有效，但订阅已过期"
        case 21007: return "此收据来自沙盒测试环境"
        case 21008: return "此收据来自生产环境"
        case 21009: return "内部数据访问错误，请稍后重试"
        case 21010: return "用户帐户未找到或已被锁定"
        default: return "未知状态码 (\(status))"
        }
    }

    private func localizedExpirationIntent(_ code: String) -> String {
        switch code {
        case "1": return "用户主动取消订阅"
        case "2": return "计费扣款错误 (例如信用卡过期/余额不足)"
        case "3": return "用户未同意涨价导致订阅取消"
        case "4": return "商品在续订时已不可购买"
        case "5": return "未知原因"
        default: return code.isEmpty || code == "0" ? "无异常" : "原因代码 \(code)"
        }
    }

    private func cleanBase64(_ input: String) -> String {
        var str = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // If user pasted a JSON string containing "receipt-data"
        if str.hasPrefix("{") && str.contains("receipt-data") {
            if let data = str.data(using: .utf8),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let receiptData = json["receipt-data"] as? String {
                str = receiptData
            }
        }

        // Remove newlines and whitespaces
        return str.replacingOccurrences(of: "\r", with: "")
                  .replacingOccurrences(of: "\n", with: "")
                  .replacingOccurrences(of: " ", with: "")
    }
}
