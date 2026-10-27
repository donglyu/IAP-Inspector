import Foundation
import Observation

struct BatchOutcome: Codable {
    var status: String
    var summary: TransactionSummary?
    var amount: String = ""
    var currency = ""
    var evidence = ""
    var checkedAt = ""
    var attempts = 0
    var retryAt: Date?
    var supplementalFields: [String: String]?
    var succeeded: Bool { summary != nil }
}

struct TransactionBatch: Codable {
    var checkpointID = UUID()
    var workbook: WorkbookFile
    var sourceName: String
    var sheetIndex = 0
    var headerRow = 0
    var transactionColumn = 0
    var environment = AppleEnvironment.production
    var bundleID = ""
    var outcomes: [String: BatchOutcome] = [:]

    static let legacyResultHeaders = ["IAP_源行号", "IAP_输入交易ID", "IAP_查询结果", "IAP_重复ID行数", "IAP_环境", "IAP_BundleID", "IAP_查询时间UTC", "IAP_请求次数", "IAP_可重试时间UTC", "Apple_transactionId", "Apple_originalTransactionId", "Apple_productId", "Apple_商品类型", "Apple_业务分类参考", "Apple_购买时间UTC", "Apple_首次购买时间UTC", "Apple_金额", "Apple_币种", "Apple_数量", "Apple_国家地区", "Apple_退款撤销时间UTC", "Apple_退款原因", "Apple_appAccountToken", "Apple_签名响应"]

    static var resultHeaders: [String] { legacyResultHeaders + TransactionExportFields.headers }

    /// Recognize exported result columns as one complete block, never a random nonempty cell.
    func resultColumnStart() -> Int? {
        guard sheet.rows.indices.contains(headerRow) else { return nil }
        let row = sheet.rows[headerRow]
        guard row.count >= Self.legacyResultHeaders.count else { return nil }
        return (0...(row.count - Self.legacyResultHeaders.count)).first { start in
            Array(row[start..<(start + Self.legacyResultHeaders.count)]) == Self.legacyResultHeaders
        }
    }

    func resultColumnCount(at start: Int) -> Int {
        let header = sheet.rows[headerRow]
        if header.count >= start + Self.resultHeaders.count,
           Array(header[start..<(start + Self.resultHeaders.count)]) == Self.resultHeaders { return Self.resultHeaders.count }
        return Self.legacyResultHeaders.count
    }

    static func importing(workbook: WorkbookFile, sourceName: String) throws -> Self {
        var batch = Self(workbook: workbook, sourceName: sourceName)
        batch.sheetIndex = workbook.sheets.firstIndex(where: { !$0.rows.isEmpty }) ?? 0
        for index in workbook.sheets.indices {
            batch.sheetIndex = index
            for row in workbook.sheets[index].rows.indices {
                batch.headerRow = row
                if let start = batch.resultColumnStart() {
                    let originalColumn = batch.sheet.rows[row].prefix(start).firstIndex {
                        $0.lowercased().replacingOccurrences(of: "_", with: "") == "transactionid"
                    }
                    batch.transactionColumn = originalColumn ?? (start + 1)
                    try batch.restoreExportedOutcomes(start: start)
                    return batch
                }
            }
        }
        batch.sheetIndex = workbook.sheets.firstIndex(where: { !$0.rows.isEmpty }) ?? 0
        batch.headerRow = 0
        if let col = batch.sheet.rows.first?.firstIndex(where: { $0.lowercased().replacingOccurrences(of: "_", with: "") == "transactionid" }) { batch.transactionColumn = col }
        return batch
    }

    private mutating func restoreExportedOutcomes(start: Int) throws {
        let existingHeaders = Array(Self.resultHeaders.prefix(resultColumnCount(at: start)))
        func cell(_ row: Int, _ name: String) -> String {
            guard let offset = existingHeaders.firstIndex(of: name), sheet.rows[row].indices.contains(start + offset) else { return "" }
            return sheet.rows[row][start + offset]
        }
        let environments = Set(dataIndices.map { cell($0, "IAP_环境") }.filter { !$0.isEmpty })
        let bundles = Set(dataIndices.map { cell($0, "IAP_BundleID") }.filter { !$0.isEmpty })
        guard environments.count <= 1, bundles.count <= 1 else { throw ReconciliationCSV.failure("续查文件包含不同环境或 Bundle ID，请分别导出后继续。") }
        if let value = environments.first {
            guard let env = AppleEnvironment.allCases.first(where: { $0.title == value }) else { throw ReconciliationCSV.failure("续查文件中的环境无效。") }
            environment = env
        }
        bundleID = bundles.first ?? ""
        var restored: [String: BatchOutcome] = [:]
        let dates = ISO8601DateFormatter()
        for row in dataIndices where validation(at: row) == nil {
            let id = identifier(at: row), status = cell(row, "IAP_查询结果")
            let attempts = max(0, Int(cell(row, "IAP_请求次数")) ?? 0)
            let checked = cell(row, "IAP_查询时间UTC")
            let retryAt = dates.date(from: cell(row, "IAP_可重试时间UTC"))
            var outcome = BatchOutcome(status: status, checkedAt: checked, attempts: attempts, retryAt: retryAt)
            if status.hasPrefix("查询成功") {
                guard cell(row, "IAP_输入交易ID") == id, cell(row, "Apple_transactionId") == id, !bundleID.isEmpty,
                      cell(row, "IAP_BundleID") == bundleID, cell(row, "IAP_环境") == environment.title,
                      !cell(row, "Apple_签名响应").isEmpty else {
                    outcome.status = "查询失败：导入的成功结果不完整或交易 ID 不一致，需重新查询"
                    if restored[id]?.succeeded != true { restored[id] = outcome }; continue
                }
                var t = TransactionSummary()
                t.transactionID = id; t.bundleID = bundleID
                t.originalTransactionID = cell(row, "Apple_originalTransactionId")
                t.productID = cell(row, "Apple_productId")
                t.productType = cell(row, "Apple_商品类型")
                t.isSubscription = t.productType.contains("订阅")
                t.purchaseDate = cell(row, "Apple_购买时间UTC"); t.purchasedAt = dates.date(from: t.purchaseDate)
                t.originalPurchaseDate = cell(row, "Apple_首次购买时间UTC"); t.originalPurchasedAt = dates.date(from: t.originalPurchaseDate)
                t.revocationDate = cell(row, "Apple_退款撤销时间UTC"); t.revokedAt = dates.date(from: t.revocationDate)
                t.refundReason = cell(row, "Apple_退款原因"); t.quantity = cell(row, "Apple_数量")
                t.storefront = cell(row, "Apple_国家地区"); t.appAccountToken = cell(row, "Apple_appAccountToken")
                outcome.summary = t; outcome.amount = cell(row, "Apple_金额"); outcome.currency = cell(row, "Apple_币种")
                outcome.evidence = cell(row, "Apple_签名响应")
                outcome.supplementalFields = Dictionary(uniqueKeysWithValues: TransactionExportFields.headers.map { ($0, cell(row, $0)) })
            } else if !status.hasPrefix("查询失败") { continue }
            if let previous = restored[id], previous.succeeded {
                if outcome.succeeded && (previous.evidence != outcome.evidence || previous.amount != outcome.amount || previous.currency != outcome.currency) {
                    throw ReconciliationCSV.failure("交易 \(id) 的重复行包含冲突结果，请核实后重新导入。")
                }
                continue
            }
            restored[id] = outcome
        }
        outcomes = restored
    }

    var sheet: ImportedSheet { workbook.sheets[sheetIndex] }
    var width: Int { sheet.rows.map(\.count).max() ?? 0 }
    var dataIndices: Range<Int> { min(headerRow + 1, sheet.rows.count)..<sheet.rows.count }
    func identifier(at row: Int) -> String {
        guard sheet.rows[row].indices.contains(transactionColumn) else { return "" }
        return sheet.rows[row][transactionColumn].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func validation(at row: Int) -> String? {
        let key = "\(row):\(transactionColumn)", id = identifier(at: row)
        if sheet.formulaCells.contains(key) { return "交易 ID 为公式，请先转换为准确文本" }
        if sheet.unsafeNumericCells.contains(key) { return "Excel 长数字或科学计数法可能丢失精度，请从源系统重新导出文本 ID" }
        if id.isEmpty { return "交易 ID 为空" }
        if !id.allSatisfy({ $0.isASCII && $0.isNumber }) { return "交易 ID 格式无效（须为数字文本）" }
        return nil
    }
    var uniqueIDs: [String] {
        var seen: Set<String> = []
        return dataIndices.compactMap { row in
            let id = identifier(at: row)
            return validation(at: row) == nil && seen.insert(id).inserted ? id : nil
        }
    }
    func state(at row: Int) -> String { validation(at: row) ?? outcomes[identifier(at: row)]?.status ?? "待查询" }

    func exportedWorkbook() -> WorkbookFile {
        var result = workbook
        let headers = Self.resultHeaders
        let existingStart = resultColumnStart()
        let existingCount = existingStart.map { resultColumnCount(at: $0) } ?? 0
        let counts = Dictionary(grouping: dataIndices.filter { validation(at: $0) == nil }, by: { identifier(at: $0) }).mapValues(\.count)
        for row in sheet.rows.indices {
            var cells = sheet.rows[row]
            cells += Array(repeating: "", count: width - cells.count)
            func writeResult(_ values: [String]) {
                if let start = existingStart { cells.replaceSubrange(start..<(start + existingCount), with: values) }
                else { cells += values }
            }
            if row == headerRow { writeResult(headers) }
            else if row > headerRow {
                let id = identifier(at: row), outcome = validation(at: row) == nil ? outcomes[id] : nil
                let t = outcome?.summary
                let classification = t.map { $0.isSubscription ? "订阅" : ($0.productType == "消耗型商品" ? "充值/消耗型（需业务确认）" : $0.productType) } ?? ""
                writeResult([existingStart.map { cells[$0] }.flatMap { $0.isEmpty ? nil : $0 } ?? String(row + 1), id, state(at: row), String(counts[id, default: 0]), environment.title, bundleID, outcome?.checkedAt ?? "", String(outcome?.attempts ?? 0), outcome?.retryAt.map { ISO8601DateFormatter().string(from: $0) } ?? "", t?.transactionID ?? "", t?.originalTransactionID ?? "", t?.productID ?? "", t?.productType ?? "", classification, t?.purchasedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "", t?.originalPurchasedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "", outcome?.amount ?? "", outcome?.currency ?? "", t?.quantity ?? "", t?.storefront ?? "", t?.revokedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "", t?.refundReason ?? "", t?.appAccountToken ?? "", outcome?.evidence ?? ""] + TransactionExportFields.values(for: outcome))
            }
            result.sheets[sheetIndex].rows[row] = cells
        }
        if headerRow == -1 {
            let sourceHeaders = (0..<width).map { "原始_" + WorkbookFile.columnName($0) }
            result.sheets[sheetIndex].rows.insert(sourceHeaders + headers, at: 0)
        }
        return result
    }
}

enum BatchRetryPolicy {
    static let maximumAttempts = 4
    static func retryDate(_ header: String?, now: Date = Date()) -> Date? {
        guard let header, let milliseconds = Double(header), milliseconds.isFinite, milliseconds > 0 else { return nil }
        // App Store Server API specifies an absolute UNIX timestamp in milliseconds.
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
    static func delay(error: Error, attempt: Int, now: Date = Date()) -> TimeInterval? {
        guard attempt < maximumAttempts else { return nil }
        let backoff = pow(2, Double(attempt))
        if let error = error as? AppleAPIError {
            switch error {
            case .rateLimited(let date, _): return max(backoff, date?.timeIntervalSince(now) ?? backoff)
            case .network: return backoff
            case .apiRejected(let status, _, _, _, _): return (500...599).contains(status) ? backoff : nil
            default: return nil
            }
        }
        return nil
    }
    static func stopBatch(_ error: Error) -> Bool {
        guard let error = error as? AppleAPIError else { return true }
        switch error {
        case .notFound, .invalidTransactionID: return false
        case .apiRejected(let status, _, _, _, _): return status != 400 && status != 404
        default: return true
        }
    }
}

private struct BatchCheckpointEvent: Codable {
    var batchID: UUID
    var transactionID: String
    var outcome: BatchOutcome
}

@MainActor @Observable final class TransactionBatchModel {
    var batch: TransactionBatch?
    var running = false
    var message = ""
    var activity = ""
    var task: Task<Void, Never>?
    typealias Lookup = (String, AppleEnvironment, InspectorSettings) async throws -> (TransactionSummary, Decimal?, String, String)
    private let lookup: Lookup
    private let checkpointURL: URL
    private var journalURL: URL { checkpointURL.appendingPathExtension("journal") }

    init(checkpointURL: URL? = nil, lookup: Lookup? = nil) {
        self.lookup = lookup ?? { id, environment, settings in
            try await AppleAPIService().reconciliationTransaction(id, environment: environment, settings: settings)
        }
        self.checkpointURL = checkpointURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IAP Inspector/transaction-batch.json")
        if let data = try? Data(contentsOf: self.checkpointURL), let saved = try? JSONDecoder().decode(TransactionBatch.self, from: data),
           saved.workbook.sheets.indices.contains(saved.sheetIndex), saved.headerRow >= -1, saved.headerRow < saved.sheet.rows.count, saved.transactionColumn >= 0 {
            batch = saved
            if let journal = try? Data(contentsOf: journalURL) {
                for line in journal.split(separator: 10) {
                    guard let event = try? JSONDecoder().decode(BatchCheckpointEvent.self, from: Data(line)) else { break }
                    if event.batchID == saved.checkpointID { batch?.outcomes[event.transactionID] = event.outcome }
                }
                persist()
            }
            message = "已恢复本机保存的批次。导入新文件会替换此批次。"
        }
    }
    func persist() {
        guard let batch else { return }
        do {
            try FileManager.default.createDirectory(at: checkpointURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(batch).write(to: checkpointURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            if FileManager.default.fileExists(atPath: journalURL.path) { try FileManager.default.removeItem(at: journalURL) }
        } catch { message = "保存查询进度失败：\(error.localizedDescription)。退出前请导出。" }
    }
    private func persistOutcome(_ id: String) {
        guard let batch, let outcome = batch.outcomes[id] else { return }
        do {
            let event = BatchCheckpointEvent(batchID: batch.checkpointID, transactionID: id, outcome: outcome)
            var data = try JSONEncoder().encode(event); data.append(10)
            if !FileManager.default.fileExists(atPath: journalURL.path) {
                try Data().write(to: journalURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            }
            let file = try FileHandle(forWritingTo: journalURL)
            defer { try? file.close() }
            try file.seekToEnd(); try file.write(contentsOf: data); try file.synchronize()
        } catch { message = "保存查询进度失败：\(error.localizedDescription)。退出前请导出。" }
    }
    func clear() {
        guard !running else { return }
        do { if FileManager.default.fileExists(atPath: checkpointURL.path) { try FileManager.default.removeItem(at: checkpointURL) }; if FileManager.default.fileExists(atPath: journalURL.path) { try FileManager.default.removeItem(at: journalURL) }; batch = nil; message = "已清除本机批次。" }
        catch { message = error.localizedDescription }
    }
    func start(settings: InspectorSettings) {
        guard !running, batch != nil else { return }
        guard batch!.bundleID.isEmpty || batch!.bundleID == settings.bundleID else { message = "Bundle ID 与已有批次不一致，请重新导入。"; return }
        batch!.bundleID = settings.bundleID
        persist()
        running = true
        task = Task { await run(settings: settings) }
    }
    func stop() { task?.cancel() }

    private func wait(until date: Date) async throws {
        while date > Date() {
            try Task.checkCancellation()
            activity = "等待重试至 \(date.formatted(date: .omitted, time: .standard))"
            try await Task.sleep(for: .seconds(min(1, date.timeIntervalSinceNow)))
        }
    }
    private func run(settings: InspectorSettings) async {
        defer { running = false; activity = ""; task = nil; persist() }
        guard let initial = batch else { return }
        let ids = initial.uniqueIDs
        var stopBatch = false
        do {
            for id in ids {
                try Task.checkCancellation()
                if batch!.outcomes[id]?.succeeded == true { continue }
                if let date = batch!.outcomes[id]?.retryAt { try await wait(until: date) }
                for attempt in 1...BatchRetryPolicy.maximumAttempts {
                    try Task.checkCancellation()
                    let previousAttempts = batch!.outcomes[id]?.attempts ?? 0
                    activity = "查询 \(id)（本轮第 \(attempt) 次）"
                    do {
                        let value = try await lookup(id, initial.environment, settings)
                        guard value.0.transactionID == id else { throw ReconciliationCSV.failure("Apple 返回的 transactionId 与输入不一致，批次已停止。") }
                        let state = value.0.revocationDate.isEmpty ? "查询成功（未做业务匹配）" : "查询成功：含退款/撤销"
                        batch!.outcomes[id] = BatchOutcome(status: state, summary: value.0, amount: value.1.map { NSDecimalNumber(decimal: $0).stringValue } ?? "", currency: value.2, evidence: value.3, checkedAt: ISO8601DateFormatter().string(from: Date()), attempts: previousAttempts + 1)
                        persistOutcome(id); break
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        let next = BatchRetryPolicy.delay(error: error, attempt: attempt).map { Date().addingTimeInterval($0 + Double.random(in: 0...0.5)) }
                        var retryAt = next
                        if case .rateLimited(let serverDate, _) = error as? AppleAPIError { retryAt = max(serverDate ?? .distantPast, next ?? .distantPast) }
                        if retryAt == .distantPast { retryAt = nil }
                        batch!.outcomes[id] = BatchOutcome(status: "查询失败：\(error.localizedDescription)", checkedAt: ISO8601DateFormatter().string(from: Date()), attempts: previousAttempts + 1, retryAt: retryAt)
                        persistOutcome(id)
                        if let next { try await wait(until: next); continue }
                        stopBatch = BatchRetryPolicy.stopBatch(error)
                        break
                    }
                }
                if stopBatch { message = "批次已停止：请检查失败原因后继续。已成功的交易不会重复查询。"; return }
                // Sequential requests, at most two per second; shared app traffic can still trigger Apple's limits.
                try await Task.sleep(for: .milliseconds(500))
            }
            message = "本轮查询完成。失败项、空 ID 和无效 ID 均会保留在导出表中。"
        } catch { message = "已停止，结果和进度已保存，可继续查询。" }
    }
}
