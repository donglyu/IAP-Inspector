import Foundation

@main struct ReconciliationChecks {
    @MainActor static func main() async throws {
        do { _ = try ReconciliationCSV.cells("\"unclosed"); preconditionFailure("Accepted invalid input") } catch { }
        let multiline = try ReconciliationCSV.cells("a,\"line1\nline2\",\"x\"\"y\"\n")
        precondition(multiline == [["a", "line1\nline2", "x\"y"]])
        let escaped = try ReconciliationCSV.cells(ReconciliationCSV.encode([["=1+1", "comma,value"]]).replacingOccurrences(of: "\u{feff}", with: ""))
        precondition(escaped == [["'=1+1", "comma,value"]])
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let retryDate = BatchRetryPolicy.retryDate("1700000060000", now: now)!
        precondition(retryDate.timeIntervalSince(now) == 60)
        precondition(BatchRetryPolicy.delay(error: AppleAPIError.rateLimited(retryAt: retryDate, code: "4290000"), attempt: 1, now: now) == 60)
        precondition(BatchRetryPolicy.delay(error: AppleAPIError.network("offline"), attempt: 4) == nil)
        precondition(BatchRetryPolicy.delay(error: AppleAPIError.notFound("4040010"), attempt: 1) == nil)
        let server = AppleAPIError.apiRejected(statusCode: 503, code: "503", message: "busy", endpoint: "transaction", environment: "Production")
        precondition(BatchRetryPolicy.delay(error: server, attempt: 1) == 2)
        let forbidden = AppleAPIError.authorizationRejected(statusCode: 403, code: "403", message: "denied", endpoint: "transaction", environment: "Production")
        precondition(BatchRetryPolicy.delay(error: forbidden, attempt: 1) == nil && BatchRetryPolicy.stopBatch(forbidden))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iap-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = WorkbookFile(sheets: [ImportedSheet(name: "订单", rows: [["备注", "transactionId"], ["a,&<\"", "1234567890123456789"], ["=1+1", "1234567890123456789"], ["", ""], ["other", "999"]]), ImportedSheet(name: "第二页", rows: [["原值"], ["多行\n文本"]])])
        let path = dir.appendingPathComponent("roundtrip.xlsx")
        try source.write(to: path)
        let loaded = try WorkbookFile.read(path)
        precondition(loaded.sheets.count == 2 && loaded.sheets[0].rows[1] == source.sheets[0].rows[1])
        precondition(loaded.sheets[1].rows == source.sheets[1].rows)
        var batch = TransactionBatch(workbook: loaded, sourceName: "roundtrip.xlsx")
        batch.transactionColumn = 1
        precondition(batch.uniqueIDs == ["1234567890123456789", "999"])
        precondition(batch.validation(at: 3) != nil)
        var noHeader = batch
        noHeader.headerRow = -1
        precondition(noHeader.dataIndices.lowerBound == 0)
        precondition(noHeader.exportedWorkbook().sheets[0].rows.count == source.sheets[0].rows.count + 1)
        var retryCalls = 0
        let transient = TransactionBatchModel(checkpointURL: dir.appendingPathComponent("retry.json"), lookup: { id, _, _ in
            retryCalls += 1
            if retryCalls == 1 { throw server }
            var t = TransactionSummary(); t.transactionID = id
            return (t, nil, "", "signed")
        })
        var single = batch
        single.workbook.sheets[0].rows = Array(single.sheet.rows.prefix(2))
        transient.batch = single
        var retrySettings = InspectorSettings(); retrySettings.bundleID = "com.test"
        transient.start(settings: retrySettings); await transient.task?.value
        precondition(retryCalls == 2 && transient.batch!.outcomes.values.first!.attempts == 2 && transient.batch!.outcomes.values.first!.succeeded)
        var calls: [String] = []
        let checkpoint = dir.appendingPathComponent("checkpoint.json")
        let model = TransactionBatchModel(checkpointURL: checkpoint, lookup: { id, _, _ in
            calls.append(id)
            if id == "999" { throw AppleAPIError.notFound("4040010") }
            var t = TransactionSummary(); t.transactionID = id; t.productID = "sku"
            return (t, Decimal(string: "4.99"), "USD", "{signed}")
        })
        model.batch = batch
        var settings = InspectorSettings(); settings.bundleID = "com.test"; settings.issuerID = "issuer"; settings.keyID = "key"
        model.start(settings: settings); await model.task?.value
        precondition(calls == ["1234567890123456789", "999"])
        let exported = model.batch!.exportedWorkbook()
        precondition(exported.sheets[0].rows.count == source.sheets[0].rows.count)
        precondition(exported.sheets[0].rows[1][4] == exported.sheets[0].rows[2][4])
        precondition(exported.sheets[0].rows[4][4].hasPrefix("查询失败"))
        precondition(exported.sheets[1].rows == source.sheets[1].rows)
        try exported.write(to: dir.appendingPathComponent("result.xlsx"))
        // Resume solely from an exported workbook, with no local checkpoint.
        let fromFile = try TransactionBatch.importing(workbook: WorkbookFile.read(dir.appendingPathComponent("result.xlsx")), sourceName: "result.xlsx")
        precondition(fromFile.outcomes["1234567890123456789"]?.succeeded == true)
        precondition(fromFile.outcomes["999"]?.succeeded == false)
        precondition(fromFile.environment == .production && fromFile.bundleID == "com.test")
        var resumeCalls: [String] = []
        let fromFileModel = TransactionBatchModel(checkpointURL: dir.appendingPathComponent("separate-machine.json"), lookup: { id, _, _ in
            resumeCalls.append(id)
            var t = TransactionSummary(); t.transactionID = id
            return (t, nil, "", "new-signed")
        })
        fromFileModel.batch = fromFile
        fromFileModel.start(settings: settings); await fromFileModel.task?.value
        precondition(resumeCalls == ["999"])
        let secondExport = fromFileModel.batch!.exportedWorkbook()
        precondition(secondExport.sheets[0].rows[0].count == exported.sheets[0].rows[0].count)
        precondition(secondExport.sheets[0].rows[1] == exported.sheets[0].rows[1])
        precondition(secondExport.sheets[1].rows == source.sheets[1].rows)
        let csvRows = try ReconciliationCSV.cells(ReconciliationCSV.encode(exported.sheets[0].rows).replacingOccurrences(of: "\u{feff}", with: ""))
        let csvResume = try TransactionBatch.importing(workbook: WorkbookFile(sheets: [ImportedSheet(name: "CSV", rows: csvRows)]), sourceName: "result.csv")
        precondition(csvResume.outcomes["1234567890123456789"]?.succeeded == true)
        // Pending rows remain queryable and the original result block is updated in place.
        var pending = exported
        let resultStart = batch.width
        pending.sheets[0].rows[4][resultStart + 2] = "待查询"
        let pendingResume = try TransactionBatch.importing(workbook: pending, sourceName: "pending.xlsx")
        precondition(pendingResume.outcomes["999"] == nil)
        var mismatched = exported
        mismatched.sheets[0].rows[1][resultStart + 9] = "111"
        mismatched.sheets[0].rows[2][resultStart + 9] = "111"
        let mismatchedResume = try TransactionBatch.importing(workbook: mismatched, sourceName: "edited.xlsx")
        precondition(mismatchedResume.outcomes["1234567890123456789"]?.succeeded != true)
        var conflicting = exported
        conflicting.sheets[0].rows[2][resultStart + 4] = "Sandbox"
        do { _ = try TransactionBatch.importing(workbook: conflicting, sourceName: "mixed.xlsx"); preconditionFailure("Accepted mixed environments") } catch { }
        // A stopped batch must resume the failed ID AND later untouched rows.
        var stopped = TransactionBatch(workbook: WorkbookFile(sheets: [ImportedSheet(name: "stopped", rows: [["transactionId"], ["111"], ["222"], ["333"]])]), sourceName: "stopped.xlsx")
        stopped.bundleID = "com.test"
        var done = TransactionSummary(); done.transactionID = "111"; done.bundleID = "com.test"
        stopped.outcomes["111"] = BatchOutcome(status: "查询成功（未做业务匹配）", summary: done, evidence: "signed-111", attempts: 1)
        stopped.outcomes["222"] = BatchOutcome(status: "查询失败：网络错误", attempts: 4)
        let stoppedURL = dir.appendingPathComponent("stopped.xlsx")
        try stopped.exportedWorkbook().write(to: stoppedURL)
        let restart = try TransactionBatch.importing(workbook: WorkbookFile.read(stoppedURL), sourceName: "stopped.xlsx")
        var remainingCalls: [String] = []
        let remaining = TransactionBatchModel(checkpointURL: dir.appendingPathComponent("remaining.json"), lookup: { id, _, _ in
            remainingCalls.append(id); var t = TransactionSummary(); t.transactionID = id
            return (t, nil, "", "signed-" + id)
        })
        remaining.batch = restart; remaining.start(settings: settings); await remaining.task?.value
        precondition(remainingCalls == ["222", "333"])
        precondition(remaining.batch!.outcomes.values.allSatisfy(\.succeeded))
        var headerless = stopped
        headerless.headerRow = -1
        headerless.workbook.sheets[0].rows = [["111"], ["222"], ["333"]]
        let headerlessExport = headerless.exportedWorkbook()
        let headerlessResume = try TransactionBatch.importing(workbook: headerlessExport, sourceName: "headerless.xlsx")
        precondition(headerlessResume.uniqueIDs == ["111", "222", "333"] && headerlessResume.outcomes["111"]?.succeeded == true)
        precondition(headerlessResume.exportedWorkbook().sheets[0].rows == headerlessExport.sheets[0].rows)
        // Supplementary fields come from the saved payload; no API request is needed.
        let purchased = ISO8601DateFormatter().date(from: "2025-11-22T00:30:00Z")!
        let payload: [String: Any] = ["transactionId": "111", "bundleId": "com.test", "storefront": "ARE",
            "purchaseDate": purchased.timeIntervalSince1970 * 1000, "expiresDate": purchased.addingTimeInterval(3600).timeIntervalSince1970 * 1000,
            "signedDate": purchased.timeIntervalSince1970 * 1000, "transactionReason": "RENEWAL", "offerType": 1,
            "offerIdentifier": "intro", "offerDiscountType": "FREE_TRIAL", "offerPeriod": "P1W",
            "revocationType": "REFUND", "revocationPercentage": 25500, "inAppOwnershipType": "PURCHASED",
            "isUpgraded": false, "webOrderLineItemId": "long-line-id", "subscriptionGroupIdentifier": "group", "appTransactionId": "app-transaction"]
        let encoded = try JSONSerialization.data(withJSONObject: payload).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let savedEvidence = String(decoding: try JSONSerialization.data(withJSONObject: ["signedTransactionInfo": "header." + encoded + ".signature"]), as: UTF8.self)
        var supplemented = stopped
        supplemented.outcomes["111"]?.evidence = savedEvidence
        supplemented.outcomes["111"]?.summary?.productID = "sku"
        let extra = TransactionExportFields.values(for: supplemented.outcomes["111"])
        func extraValue(_ name: String) -> String { extra[TransactionExportFields.headers.firstIndex(of: name)!] }
        precondition(extraValue("Apple_国家二位码") == "AE")
        precondition(extraValue("Apple_购买日期UTC") == "2025-11-22" && extraValue("Apple_购买日期洛杉矶") == "2025-11-21")
        precondition(extraValue("Apple_退款撤销比例百分数") == "25.5" && extraValue("Apple_是否订阅升级") == "否")
        precondition(extraValue("Apple_交易原因") == "自动续费" && extraValue("Apple_优惠支付方式") == "FREE_TRIAL")
        precondition(extraValue("Apple_webOrderLineItemId") == "long-line-id")
        // Old-format result blocks expand once, preserving any columns users added after them.
        var legacyExport = supplemented.exportedWorkbook()
        for r in legacyExport.sheets[0].rows.indices {
            legacyExport.sheets[0].rows[r].removeSubrange((1 + TransactionBatch.legacyResultHeaders.count)..<(1 + TransactionBatch.resultHeaders.count))
            legacyExport.sheets[0].rows[r].append(r == 0 ? "同事备注" : "保留备注")
        }
        let legacyResume = try TransactionBatch.importing(workbook: legacyExport, sourceName: "legacy.xlsx")
        precondition(legacyResume.outcomes["111"]?.succeeded == true)
        let upgradedExport = legacyResume.exportedWorkbook()
        precondition(upgradedExport.sheets[0].rows[1].last == "保留备注")
        precondition(upgradedExport.sheets[0].rows[0].count == 2 + TransactionBatch.resultHeaders.count)
        let alphaIndex = 1 + TransactionBatch.resultHeaders.firstIndex(of: "Apple_国家二位码")!
        precondition(upgradedExport.sheets[0].rows[1][alphaIndex] == "AE")
        let upgradedResume = try TransactionBatch.importing(workbook: upgradedExport, sourceName: "upgraded.xlsx")
        precondition(upgradedResume.exportedWorkbook().sheets[0].rows == upgradedExport.sheets[0].rows)
        let recovered = TransactionBatchModel(checkpointURL: checkpoint, lookup: { id, _, _ in calls.append(id); throw AppleAPIError.notFound("4040010") })
        precondition(recovered.batch?.bundleID == "com.test" && recovered.batch?.outcomes.count == 2)
        recovered.start(settings: settings); await recovered.task?.value
        precondition(calls == ["1234567890123456789", "999", "999"])
        let cancelled = TransactionBatchModel(checkpointURL: dir.appendingPathComponent("cancel.json"), lookup: { _, _, _ in throw AppleAPIError.network("offline") })
        cancelled.batch = batch; cancelled.start(settings: settings)
        try await Task.sleep(for: .milliseconds(50))
        let inFlightRecovery = TransactionBatchModel(checkpointURL: dir.appendingPathComponent("cancel.json"))
        precondition(inFlightRecovery.batch?.outcomes.values.first?.attempts == 1)
        cancelled.stop(); await cancelled.task?.value
        precondition(!cancelled.running && cancelled.batch!.outcomes.count == 1 && cancelled.batch!.outcomes.values.first!.attempts == 1)
        var numeric = batch
        numeric.workbook.sheets[0].unsafeNumericCells.insert("1:1")
        numeric.workbook.sheets[0].formulaCells.insert("2:1")
        precondition(numeric.validation(at: 1) != nil && numeric.validation(at: 2) != nil)
        if CommandLine.arguments.count > 1 {
            let fixture = try WorkbookFile.read(URL(fileURLWithPath: CommandLine.arguments[1]))
            precondition(fixture.sheets[0].rows.count == 6)
            precondition(fixture.sheets[0].rows[1] == ["rich text", "", "1234567890123456789"])
            precondition(fixture.sheets[0].unsafeNumericCells == ["2:2", "3:2"])
            precondition(fixture.sheets[0].formulaCells == ["5:2"])
            try exported.write(to: URL(fileURLWithPath: "/tmp/iap-export-check.xlsx"))
        }
        print("Reconciliation, workbook roundtrip, retry policy, deduplication, checkpoint, and cancellation checks passed")
    }
}
