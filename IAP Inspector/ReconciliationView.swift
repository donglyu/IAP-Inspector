import SwiftUI
import UniformTypeIdentifiers

struct ReconciliationView: View {
    let settings: InspectorSettings
    @Bindable var model: TransactionBatchModel
    @State private var filter = ""
    @State private var importing = false
    private var xlsxType: UTType { UTType(filenameExtension: "xlsx") ?? .data }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("批量补齐 Apple 交易明细").font(.title2.bold())
            Text("选择 Excel 工作表和 transactionId 列，保留原始值并追加查询结果。公式使用保存值，导出不保留原样式；本步骤不比较业务字段。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("导入 Excel / CSV", action: importFile).disabled(model.running || importing)
                if let batch = model.batch { Text(batch.sourceName).lineLimit(1).foregroundStyle(.secondary) }
                Spacer()
                Button("清除本机批次") { model.clear() }.disabled(model.running || model.batch == nil)
            }
            if let batch = model.batch {
                mapping(batch)
                HStack {
                    Button("开始 / 继续 / 重试失败项") { model.start(settings: settings) }
                        .disabled(model.running || !settings.isConfigured || batch.uniqueIDs.isEmpty)
                    if model.running {
                        ProgressView().controlSize(.small)
                        Button("停止") { model.stop() }
                    }
                    Spacer()
                    Menu("导出结果") {
                        Button("Excel (.xlsx)，所有工作表") { export(xlsx: true) }
                        Button("CSV，仅所选工作表") { export(xlsx: false) }
                    }
                }
                let successful = batch.outcomes.values.filter(\.succeeded).count
                Text("业务行 \(batch.dataIndices.count) · 有效交易 ID 去重后 \(batch.uniqueIDs.count) · 已成功 \(successful) · 失败 \(batch.outcomes.count - successful)")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.activity.isEmpty { Text(model.activity).font(.caption).monospacedDigit() }
                TextField("筛选交易 ID 或查询结果", text: $filter)
                Table(preview(batch)) {
                    TableColumn("原始行") { Text(String($0.index + 1)) }.width(60)
                    TableColumn("输入 transactionId", value: \.transactionID)
                    TableColumn("商品", value: \.productID)
                    TableColumn("Apple 金额", value: \.amount)
                    TableColumn("查询结果", value: \.status)
                }
            } else {
                ContentUnavailableView("导入业务表格", systemImage: "tablecells", description: Text("只需要一列 transactionId，无需固定表头或完整业务字段。支持 .xlsx 和 UTF-8 CSV。"))
            }
            if !model.message.isEmpty { Text(model.message).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            Text("进度及交易明细自动保存在本机；成功项会跳过，重复 ID 共用结果。导出的表格可再次导入续查，也可带回 ChatGPT 做后续匹配。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24)
    }

    @ViewBuilder private func mapping(_ batch: TransactionBatch) -> some View {
        HStack {
            Picker("工作表", selection: Binding(get: { model.batch?.sheetIndex ?? 0 }, set: { index in
                model.batch?.sheetIndex = index; model.batch?.headerRow = 0; model.batch?.transactionColumn = 0; model.persist()
            })) {
                ForEach(batch.workbook.sheets.indices, id: \.self) { index in Text(batch.workbook.sheets[index].name).tag(index) }
            }
            Toggle("有表头", isOn: Binding(get: { (model.batch?.headerRow ?? 0) >= 0 }, set: { model.batch?.headerRow = $0 ? 0 : -1; model.persist() })).toggleStyle(.checkbox)
            Stepper("表头：第 \(batch.headerRow + 1) 行", value: Binding(get: { model.batch?.headerRow ?? 0 }, set: { model.batch?.headerRow = $0; model.persist() }), in: 0...max(0, batch.sheet.rows.count - 1))
                .disabled(batch.headerRow < 0)
                .frame(width: 160)
            Picker("交易 ID 列", selection: Binding(get: { model.batch?.transactionColumn ?? 0 }, set: { model.batch?.transactionColumn = $0; model.persist() })) {
                ForEach(0..<max(1, batch.width), id: \.self) { col in
                    Text(columnLabel(batch, col)).tag(col)
                }
            }
            Picker("环境", selection: Binding(get: { model.batch?.environment ?? .production }, set: { model.batch?.environment = $0; model.persist() })) {
                ForEach(AppleEnvironment.allCases, id: \.self) { Text($0.title).tag($0) }
            }.frame(width: 160)
        }.disabled(model.running || !batch.outcomes.isEmpty || batch.resultColumnStart() != nil)
        if !batch.outcomes.isEmpty { Text("已有查询记录，工作表、列和环境已锁定；更换输入请重新导入原始文件。").font(.caption).foregroundStyle(.secondary) }
    }
    private func columnLabel(_ batch: TransactionBatch, _ col: Int) -> String {
        let header = batch.sheet.rows.indices.contains(batch.headerRow) ? batch.sheet.rows[batch.headerRow] : []
        return "\(WorkbookFile.columnName(col))：\(header.indices.contains(col) ? header[col] : "无表头")"
    }
    private struct Preview: Identifiable {
        var id: Int { index }
        var index: Int; var transactionID: String; var productID: String; var amount: String; var status: String
    }
    private func preview(_ batch: TransactionBatch) -> [Preview] {
        batch.dataIndices.compactMap { index in
            let id = batch.identifier(at: index), status = batch.state(at: index)
            guard filter.isEmpty || (id + status).localizedCaseInsensitiveContains(filter) else { return nil }
            let outcome = batch.validation(at: index) == nil ? batch.outcomes[id] : nil
            return Preview(index: index, transactionID: id, productID: outcome?.summary?.productID ?? "", amount: "\(outcome?.amount ?? "") \(outcome?.currency ?? "")", status: status)
        }
    }
    private func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [xlsxType, .commaSeparatedText]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        let access = url.startAccessingSecurityScopedResource()
        defer { importing = false; if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let workbook = try WorkbookFile.read(url)
            guard workbook.sheets.contains(where: { !$0.rows.isEmpty }) else { throw ReconciliationCSV.failure("文件中没有数据。") }
            let batch = try TransactionBatch.importing(workbook: workbook, sourceName: url.lastPathComponent)
            model.batch = batch
            if batch.resultColumnStart() != nil {
                let completed = batch.outcomes.values.filter(\.succeeded).count
                model.message = "已识别续查表格，保留 \(completed) 个已成功结果；点击继续，仅查询未完成和失败的交易。"
            } else {
                model.message = "请选择工作表、表头行和 transactionId 列。Excel 长数字列、科学计数法和公式 ID 会标记为无效，不会擅自修复。"
            }
            model.persist()
        } catch { model.message = error.localizedDescription }
    }
    private func export(xlsx: Bool) {
        guard let batch = model.batch else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = xlsx ? [xlsxType] : [.commaSeparatedText]
        panel.nameFieldStringValue = "Apple交易明细." + (xlsx ? "xlsx" : "csv")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let workbook = batch.exportedWorkbook()
            if xlsx { try workbook.write(to: url) }
            else { try ReconciliationCSV.encode(workbook.sheets[batch.sheetIndex].rows).write(to: url, atomically: true, encoding: .utf8) }
            model.message = "已导出当前进度；原业务行顺序不变，失败项和重复行均已保留。"
        } catch { model.message = error.localizedDescription }
    }
}
