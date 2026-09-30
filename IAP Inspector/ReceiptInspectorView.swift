import SwiftUI
import UniformTypeIdentifiers

struct ReceiptInspectorView: View {
    var onInspectTransaction: (String) -> Void
    var onShowToast: (String) -> Void

    @State private var receiptInput = ""
    @State private var sharedSecret = ReceiptSecretStore.read() ?? ""
    @State private var isProcessing = false
    @State private var result: ReceiptInspectionResult?
    @State private var errorMessage: String?
    @State private var selectedTab = 0
    @State private var showingFileImporter = false

    private let verifyService = VerifyReceiptService()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerView

            inputSection

            if isProcessing {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在解析票据数据…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("解析未完成", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result {
                Divider()
                resultSection(result: result)
            } else {
                welcomePlaceholder
            }
        }
        .padding(20)
        .onAppear(perform: migrateSharedSecretFromUserDefaults)
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.data, .item], allowsMultipleSelection: false) { outcome in
            switch outcome {
            case .success(let urls):
                if let url = urls.first {
                    do {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let data = try Data(contentsOf: url)
                        receiptInput = data.base64EncodedString()
                        parseOfflineASN1()
                    } catch {
                        errorMessage = "读取文件失败：\(error.localizedDescription)"
                    }
                }
            case .failure:
                break
            }
        }
    }

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("App Store 票据解析 (Receipt Inspector)").font(.title2.bold())
                Text("支持 Base64 Receipt 离线 ASN.1 深度解码与 Apple verifyReceipt 双环境在线验证").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Button {
                    if let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty {
                        receiptInput = clip
                    }
                } label: {
                    Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .help("一键粘贴剪贴板中的 Base64 票据")

                if !receiptInput.isEmpty {
                    Button("清空") {
                        receiptInput = ""
                        result = nil
                        errorMessage = nil
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $receiptInput)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 85)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

                if receiptInput.isEmpty {
                    Text("在此粘贴 Base64 票据字符串，或包含 {\"receipt-data\": \"...\"} 的 JSON 报文…")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "key.fill").foregroundStyle(.secondary).font(.caption)
                    SecureField("App 专用共享密钥 (Shared Secret，可选)", text: $sharedSecret)
                        .textFieldStyle(.plain)
                        .font(.callout)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

                Button {
                    showingFileImporter = true
                } label: {
                    Label("导入文件…", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.bordered)

                Button {
                    parseOfflineASN1()
                } label: {
                    Label("离线 ASN.1 解码", systemImage: "lock.laptopcomputer")
                }
                .buttonStyle(.bordered)
                .disabled(receiptInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)

                Button {
                    Task { await verifyOnline() }
                } label: {
                    Label("兼容验证 verifyReceipt（已弃用）", systemImage: "network")
                }
                .buttonStyle(.borderedProminent)
                .disabled(receiptInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)
            }
            Label("Apple 已弃用 verifyReceipt。仅用于旧票据兼容排查；新流程优先使用 App Store Server API 或已签名的交易数据。", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var welcomePlaceholder: some View {
        ContentUnavailableView {
            Label("从一张 App Store 票据开始", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("粘贴客户端导出的 Base64 receipt-data 或拖入 .receipt 原始文件。\n支持无网离线 ASN.1 解码；旧票据可用已弃用的 verifyReceipt 接口作兼容排查。")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultSection(result: ReceiptInspectionResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 顶部状态栏
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(result.bundleID.isEmpty ? "未知 Bundle ID" : result.bundleID)
                            .font(.title3.bold())
                        if !result.appVersion.isEmpty {
                            Text("v\(result.appVersion)")
                                .font(.caption.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(result.source.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 10) {
                    Button {
                        copyReceiptReport(result: result)
                    } label: {
                        Label("复制排查报告", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)

                    Label(result.environment, systemImage: "checkmark.shield.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(result.environment.contains("Sandbox") ? .orange : .green)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(.vertical, 4)

            // 诊断与提示
            if !result.diagnosticNotes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(result.diagnosticNotes, id: \.self) { note in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(note.contains("异常") || note.contains("未能") ? .orange : .accentColor)
                                .font(.caption)
                                .padding(.top, 2)
                            Text(note).font(.caption).foregroundStyle(.primary)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            Picker("分项视图", selection: $selectedTab) {
                Text("票据概览").tag(0)
                Text("内购交易 (\(result.inAppPurchases.count))").tag(1)
                if !result.renewalInfos.isEmpty {
                    Text("自动续订状态 (\(result.renewalInfos.count))").tag(2)
                }
                Text("证书与签名").tag(3)
                Text("原始 JSON").tag(4)
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 4)

            Group {
                if selectedTab == 0 {
                    overviewTab(result: result)
                } else if selectedTab == 1 {
                    inAppPurchasesTab(items: result.inAppPurchases)
                } else if selectedTab == 2 {
                    renewalInfosTab(items: result.renewalInfos)
                } else if selectedTab == 3 {
                    certificatesTab(result: result)
                } else {
                    rawJSONTab(result: result)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func overviewTab(result: ReceiptInspectionResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    tileView(title: "解析方式", value: result.source.rawValue, icon: "cpu")
                    tileView(title: "内购交易总数", value: "\(result.inAppPurchases.count) 笔", icon: "cart")
                    tileView(title: "票据创建时间", value: result.receiptCreationDate.isEmpty ? "未知" : result.receiptCreationDate, icon: "clock")
                }

                GroupBox("票据元数据") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                        gridRow("Bundle ID", result.bundleID)
                        gridRow("App 版本号", result.appVersion)
                        if !result.originalAppVersion.isEmpty {
                            gridRow("首次下载 App 版本号", result.originalAppVersion)
                        }
                        gridRow("票据创建时间", result.receiptCreationDate)
                        if !result.receiptExpirationDate.isEmpty {
                            gridRow("票据到期时间", result.receiptExpirationDate)
                        }
                        gridRow("验证环境", result.environment)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .padding(.bottom, 16)
        }
    }

    private func inAppPurchasesTab(items: [ParsedReceiptItem]) -> some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("票据内无内购交易记录", systemImage: "tray")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(item.productName.isEmpty ? item.productID : item.productName).font(.headline)
                                Text(item.status)
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(item.status.contains("退款") ? Color.red.opacity(0.1) : Color.green.opacity(0.1), in: Capsule())
                                    .foregroundStyle(item.status.contains("退款") ? .red : .green)
                                if item.isIntroOffer {
                                    Text("首发优惠")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.1), in: Capsule())
                                        .foregroundStyle(.blue)
                                }
                            }
                            HStack(spacing: 16) {
                                Text("Transaction ID: \(item.transactionID)").textSelection(.enabled)
                                if !item.originalTransactionID.isEmpty && item.originalTransactionID != item.transactionID {
                                    Text("Original ID: \(item.originalTransactionID)").textSelection(.enabled)
                                }
                            }
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)

                            HStack(spacing: 14) {
                                Text("购买时间: \(item.purchaseDate)")
                                if !item.expirationDate.isEmpty {
                                    Text("到期时间: \(item.expirationDate)").foregroundStyle(.orange)
                                }
                                if !item.cancellationDate.isEmpty {
                                    Text("撤销/退款时间: \(item.cancellationDate)").foregroundStyle(.red)
                                }
                                if item.quantity != "1" && !item.quantity.isEmpty {
                                    Text("数量: \(item.quantity)")
                                }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("在交易查询中查看") {
                            let tid = item.transactionID.isEmpty ? item.originalTransactionID : item.transactionID
                            onInspectTransaction(tid)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func renewalInfosTab(items: [ParsedRenewalInfo]) -> some View {
        List(items) { info in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(info.productName.isEmpty ? info.productID : info.productName).font(.headline)
                    Spacer()
                    Text(info.autoRenewStatus)
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(info.autoRenewStatus.contains("开启") ? Color.green.opacity(0.1) : Color.orange.opacity(0.1), in: Capsule())
                        .foregroundStyle(info.autoRenewStatus.contains("开启") ? .green : .orange)
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    gridRow("Original Transaction ID", info.originalTransactionID)
                    if info.autoRenewProductID != info.productID && !info.autoRenewProductID.isEmpty {
                        gridRow("下期续订商品", info.autoRenewProductID)
                    }
                    if info.expirationIntent != "无异常" && !info.expirationIntent.isEmpty {
                        gridRow("过期意图", info.expirationIntent)
                    }
                    if info.isInBillingRetry != "正常" {
                        gridRow("扣款重试", info.isInBillingRetry)
                    }
                    if !info.gracePeriodExpiresDate.isEmpty {
                        gridRow("宽限期到期时间", info.gracePeriodExpiresDate)
                    }
                }
                .font(.caption)
            }
            .padding(.vertical, 4)
        }
    }

    private func certificatesTab(result: ReceiptInspectionResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: result.isSignatureValid ? "checkmark.seal.fill" : "xmark.seal.fill")
                        Text(result.isSignatureValid ? "签名/数据校验有效" : "签名未校验")
                    }
                    .font(.callout.bold())
                    .foregroundStyle(result.isSignatureValid ? .green : .orange)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(result.isSignatureValid ? Color.green.opacity(0.1) : Color.orange.opacity(0.1), in: Capsule())

                    HStack(spacing: 6) {
                        Image(systemName: result.isAppleRootTrusted ? "lock.shield.fill" : "shield.slash")
                        Text(result.isAppleRootTrusted ? "Apple 信任链受信任" : "未通过 Apple 根证书校验")
                    }
                    .font(.callout.bold())
                    .foregroundStyle(result.isAppleRootTrusted ? .green : .orange)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(result.isAppleRootTrusted ? Color.green.opacity(0.1) : Color.orange.opacity(0.1), in: Capsule())

                    Spacer()
                }

                if !result.certificateChain.isEmpty {
                    GroupBox("证书链详情") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(result.certificateChain, id: \.self) { cert in
                                Text(cert).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    private func rawJSONTab(result: ReceiptInspectionResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("解码 / 返回的原始 JSON").font(.headline)
                Spacer()
                Button("复制完整 JSON") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.rawJSON, forType: .string)
                    onShowToast("已复制 JSON")
                }
                .buttonStyle(.bordered)
            }
            ScrollView([.horizontal, .vertical]) {
                Text(result.rawJSON)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        }
    }

    private func tileView(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption2).foregroundStyle(.secondary)
            Text(value.isEmpty ? "暂无" : value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    private func gridRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).font(.callout).frame(width: 140, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .textSelection(.enabled)
                .font(value.allSatisfy(\.isNumber) && !value.isEmpty ? .system(.callout, design: .monospaced) : .callout)
        }
    }

    private func parseOfflineASN1() {
        errorMessage = nil
        let trimmed = extractBase64(from: receiptInput)
        guard let data = Data(base64Encoded: trimmed, options: [.ignoreUnknownCharacters]) else {
            errorMessage = "输入的不是有效的 Base64 编码数据，请检查输入内容。"
            return
        }
        let parsed = PKCS7ReceiptParser.parse(receiptData: data)
        result = parsed
    }

    @MainActor private func verifyOnline() async {
        isProcessing = true
        errorMessage = nil
        result = nil
        defer { isProcessing = false }

        let trimmed = extractBase64(from: receiptInput)
        guard !trimmed.isEmpty else {
            errorMessage = "请先输入或粘贴 Base64 票据数据"
            return
        }

        do {
            let secret = sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            if secret.isEmpty {
                ReceiptSecretStore.delete()
            } else {
                try ReceiptSecretStore.save(secret)
            }
            let res = try await verifyService.verify(base64Receipt: trimmed, password: secret)
            result = res
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func migrateSharedSecretFromUserDefaults() {
        let defaultsKey = "inspector.receipt_shared_secret"
        if ReceiptSecretStore.read() != nil {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return
        }
        guard let oldSecret = UserDefaults.standard.string(forKey: defaultsKey), !oldSecret.isEmpty else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return
        }
        do {
            try ReceiptSecretStore.save(oldSecret)
            sharedSecret = oldSecret
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } catch {
            // Keep the legacy value if Keychain migration fails so it can be retried.
            return
        }
    }

    private func extractBase64(from raw: String) -> String {
        var str = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("{") && str.contains("receipt-data") {
            if let data = str.data(using: .utf8),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let rData = json["receipt-data"] as? String {
                str = rData
            }
        }
        return str.replacingOccurrences(of: "\r", with: "")
                  .replacingOccurrences(of: "\n", with: "")
                  .replacingOccurrences(of: " ", with: "")
    }

    private func copyReceiptReport(result: ReceiptInspectionResult) {
        var lines: [String] = []
        lines.append("# Apple App Store 票据解析报告")
        lines.append("- **解析模式**: \(result.source.rawValue)")
        lines.append("- **环境**: \(result.environment)")
        lines.append("- **Bundle ID**: `\(result.bundleID)`")
        if !result.appVersion.isEmpty { lines.append("- **App 版本**: `\(result.appVersion)`") }
        if !result.originalAppVersion.isEmpty { lines.append("- **首次下载版本**: `\(result.originalAppVersion)`") }
        if !result.receiptCreationDate.isEmpty { lines.append("- **票据生成时间**: \(result.receiptCreationDate)") }
        lines.append("- **内购交易笔数**: \(result.inAppPurchases.count)")

        if !result.inAppPurchases.isEmpty {
            lines.append("\n## 内购交易列表")
            for item in result.inAppPurchases {
                lines.append("- `\(item.transactionID)` | \(item.productName) (`\(item.productID)`) | 购买时间: \(item.purchaseDate) | 状态: \(item.status)")
            }
        }

        if !result.renewalInfos.isEmpty {
            lines.append("\n## 自动续订信息")
            for info in result.renewalInfos {
                lines.append("- `\(info.originalTransactionID)` | \(info.productName) | 续订状态: \(info.autoRenewStatus) | 重试状态: \(info.isInBillingRetry)")
            }
        }

        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        onShowToast("已复制票据排查报告 (Markdown)")
    }
}
