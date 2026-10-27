import SwiftUI
import UniformTypeIdentifiers

enum InspectorSection: Hashable {
    case search
    case reconciliation
    case receiptInspector
    case jwsInspector
    case notificationTest
    case history
}

struct ContentView: View {
    @State private var batchModel = TransactionBatchModel()
    @State private var query = ""
    @State private var queryType = QueryType.transaction
    @State private var notificationsOnlyFailures = false
    @State private var selectedSubscriptionStatuses: Set<Int> = Set(1...5)
    @State private var selectedSection: InspectorSection = .search
    @State private var showingSettings = false
    @State private var showingProductCatalog = false
    @State private var isSearching = false
    @State private var result: InspectorResult?
    @State private var errorMessage: String?
    @State private var history = QueryHistory.load()
    @State private var settings = InspectorSettings.load()
    @State private var copyBannerText: String?
    private let service = AppleAPIService()

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Section("排查工具") {
                    Label("逐笔对账", systemImage: "checklist").tag(InspectorSection.reconciliation)
                    Label("交易查询", systemImage: "magnifyingglass").tag(InspectorSection.search)
                    Label("票据解析", systemImage: "doc.text.magnifyingglass").tag(InspectorSection.receiptInspector)
                    Label("JWS 离线解析", systemImage: "key.horizontal").tag(InspectorSection.jwsInspector)
                    Label("测试通知调试", systemImage: "bell.badge").tag(InspectorSection.notificationTest)
                    Label("最近查询", systemImage: "clock").tag(InspectorSection.history)
                }

                Section("API 配置状态") {
                    Button {
                        showingSettings = true
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(settings.isConfigured ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                                .shadow(color: (settings.isConfigured ? Color.green : Color.orange).opacity(0.35), radius: 2)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(settings.isConfigured ? "Apple API 已就绪" : "未配置 API 凭证")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(settings.isConfigured ? Color.primary : Color.orange)
                                Text(settings.bundleID.isEmpty ? "点击配置密钥与证书" : settings.bundleID)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("IAP Inspector")
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 8) {
                        Button {
                            showingProductCatalog = true
                        } label: {
                            Label("商品库", systemImage: "square.grid.2x2")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .help("管理 Product ID 与商品名称映射")

                        Button {
                            showingSettings = true
                        } label: {
                            Label("API 设置", systemImage: "gearshape")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .help("API 凭证与 Keychain 设置 (⌘,)")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.85))
                }
            }
        } detail: {
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    switch selectedSection {
                    case .reconciliation:
                        ReconciliationView(settings: settings, model: batchModel)
                    case .search:
                        searchHeader
                        Divider()
                        if let errorMessage {
                            ContentUnavailableView("查询未完成", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let result {
                            ResultView(result: result, onInspectTransaction: { tid in
                                query = tid
                                queryType = .transaction
                                Task { await search() }
                            }, onShowToast: { msg in
                                showToast(msg)
                            })
                        } else {
                            welcomeView
                        }
                    case .receiptInspector:
                        ReceiptInspectorView(onInspectTransaction: { tid in
                            query = tid
                            queryType = .transaction
                            selectedSection = .search
                            Task { await search() }
                        }, onShowToast: { msg in
                            showToast(msg)
                        })
                    case .jwsInspector:
                        JWSInspectorView(onInspectTransaction: { tid in
                            query = tid
                            queryType = .transaction
                            selectedSection = .search
                            Task { await search() }
                        }, onShowToast: { msg in
                            showToast(msg)
                        })
                    case .notificationTest:
                        NotificationTestView(service: service, settings: settings)
                    case .history:
                        HistoryListView(history: $history, onSelect: { item in
                            query = item.identifier
                            queryType = item.queryType
                            selectedSection = .search
                            Task { await search() }
                        })
                    }
                }
                .frame(minWidth: 720, minHeight: 560)
                .background(Color(nsColor: .windowBackgroundColor))

                if let copyBannerText {
                    Text(copyBannerText)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .padding(.top, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: copyBannerText)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(settings: $settings)
            .frame(width: 520)
            .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showingProductCatalog) {
            ProductCatalogView()
                .frame(width: 620, height: 480)
        }
        .onChange(of: settings) { _, value in value.save() }
    }

    private func showToast(_ msg: String) {
        copyBannerText = msg
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if copyBannerText == msg {
                copyBannerText = nil
            }
        }
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple 交易查询").font(.title2.bold())
                    Text("输入交易 ID 或订单号，快速解析 Apple 侧交易状态与通知轨迹").font(.callout).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Picker("标识类型", selection: $queryType) {
                    ForEach(QueryType.allCases, id: \.self) { type in
                        Text(type.title).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)

                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(queryType == .order ? "Apple 订单号 (如 ML4X2K9Q7P)" : queryType == .appTransaction ? "App Transaction ID" : "交易 ID / 原始交易 ID", text: $query)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .onSubmit { Task { await search() } }

                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    Button { Task { await search() } } label: {
                        if isSearching {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("查询").frame(minWidth: 46)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))

                Menu {
                    Toggle("只查询投递失败的通知", isOn: $notificationsOnlyFailures)
                    Divider()
                    Text("订阅状态")
                    ForEach(SubscriptionStatusFilter.allCases, id: \.rawValue) { filter in
                        Toggle(filter.title, isOn: subscriptionStatusBinding(filter.rawValue))
                    }
                    Divider()
                    Button("全部订阅状态") { selectedSubscriptionStatuses = Set(1...5) }
                } label: {
                    Label("查询筛选", systemImage: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var welcomeView: some View {
        ContentUnavailableView {
            Label("从一笔交易开始", systemImage: "shippingbox")
        } description: {
            Text("支持交易 ID、原始交易 ID、App Transaction ID 或 Apple 订单号。\n查询结果将整理为中文摘要、异常诊断、购买历史与事件时间线。")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor private func search() async {
        let identifier = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchType = queryType
        guard !identifier.isEmpty else { return }
        isSearching = true
        errorMessage = nil
        result = nil
        defer { isSearching = false }
        do {
            let fetched: InspectorResult
            switch searchType {
            case .order: fetched = try await service.lookupOrderID(identifier, settings: settings)
            case .appTransaction: fetched = try await service.lookupAppTransactionID(identifier, settings: settings, subscriptionStatuses: selectedStatusFilters, notificationsOnlyFailures: notificationsOnlyFailures)
            case .transaction: fetched = try await service.lookup(identifier, settings: settings, subscriptionStatuses: selectedStatusFilters, notificationsOnlyFailures: notificationsOnlyFailures)
            }
            result = fetched
            let existingNote = history.first {
                $0.identifier == identifier && $0.queryType == searchType
            }?.note
            history.removeAll { $0.identifier == identifier && $0.queryType == searchType }
            history.insert(QueryHistoryItem(identifier: identifier, date: .now, environment: fetched.environment.title, queryType: searchType, note: existingNote), at: 0)
            QueryHistory.save(history)
            history = QueryHistory.load()
            selectedSection = .search
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var selectedStatusFilters: [Int] {
        selectedSubscriptionStatuses.count == SubscriptionStatusFilter.allCases.count ? [] : selectedSubscriptionStatuses.sorted()
    }

    private func subscriptionStatusBinding(_ status: Int) -> Binding<Bool> {
        Binding(
            get: { selectedSubscriptionStatuses.contains(status) },
            set: { isSelected in
                if isSelected { selectedSubscriptionStatuses.insert(status) }
                else { selectedSubscriptionStatuses.remove(status) }
            }
        )
    }
}

private enum SubscriptionStatusFilter: Int, CaseIterable {
    case active = 1
    case expired = 2
    case billingRetry = 3
    case gracePeriod = 4
    case revoked = 5

    var title: String {
        switch self {
        case .active: "有效"
        case .expired: "已过期"
        case .billingRetry: "账单重试"
        case .gracePeriod: "计费宽限期"
        case .revoked: "已撤销"
        }
    }
}

// MARK: - Result View
struct ResultView: View {
    let result: InspectorResult
    var onInspectTransaction: (String) -> Void
    var onShowToast: (String) -> Void
    @State private var selectedTab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部信息条
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(result.summary.productName).font(.title3.bold())
                        if result.summary.isSubscription {
                            Text("自动续期订阅")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.blue.opacity(0.12), in: Capsule())
                                .foregroundStyle(.blue)
                        }
                    }
                    Text(result.summary.productID.isEmpty ? "商品 ID 暂无" : result.summary.productID)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 10) {
                    Button {
                        let report = ReportGenerator.generateMarkdown(result: result)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                        onShowToast("已复制排查报告 (Markdown)")
                    } label: {
                        Label("复制排查报告", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)

                    Label(result.environment.title, systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(result.environment == .production ? .green : .orange)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            // 智能诊断看板
            let issues = result.diagnosticIssues
            if !issues.isEmpty {
                VStack(spacing: 6) {
                    ForEach(issues) { issue in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: issue.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(issue.severity == .critical ? .red : .orange)
                                .font(.system(size: 14))
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(issue.title).font(.caption.bold())
                                    Spacer()
                                }
                                Text(issue.detail).font(.caption2).foregroundStyle(.secondary)
                                if let sug = issue.suggestion {
                                    Text("💡 " + sug).font(.caption2).foregroundStyle(.primary).padding(.top, 1)
                                }
                            }
                        }
                        .padding(8)
                        .background(issue.severity == .critical ? Color.red.opacity(0.08) : Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(issue.severity == .critical ? Color.red.opacity(0.2) : Color.orange.opacity(0.2)))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            if result.paginationIncomplete {
                Label("记录超过分页上限，当前展示可能不完整。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).padding(.horizontal, 20).padding(.bottom, 6)
            }

            Divider()

            Picker("结果分项", selection: $selectedTab) {
                Text("交易概览").tag(0)
                Text("购买历史 (\(result.history.count))").tag(1)
                Text("退款记录 (\(result.refunds.count))").tag(2)
                Text("订阅状态 (\(result.subscriptions.count))").tag(3)
                Text("\(result.notificationFailuresOnly ? "失败通知" : "通知历史") (\(result.notifications.count))").tag(4)
                Text("Raw 数据").tag(5)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Group {
                if selectedTab == 0 { overview.padding(.horizontal, 20) }
                else if selectedTab == 1 { transactionList(result.history, empty: "没有返回购买历史") }
                else if selectedTab == 2 { transactionList(result.refunds, empty: "未发现 Apple 已批准的退款记录") }
                else if selectedTab == 3 { subscriptionList }
                else if selectedTab == 4 { notificationList }
                else { rawData }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 顶部状态磁贴
                HStack(spacing: 8) {
                    statusTile("交易状态", value: result.summary.status, icon: "checkmark.seal", highlight: result.summary.status.contains("退款") ? .red : nil)
                    statusTile("本次交易时间", value: result.summary.purchaseDate, icon: "clock")
                    if !result.summary.originalPurchaseDate.isEmpty && result.summary.originalPurchaseDate != result.summary.purchaseDate {
                        statusTile("首次购买时间", value: result.summary.originalPurchaseDate, icon: "calendar.badge.clock")
                    }
                    statusTile("金额", value: result.summary.price.isEmpty ? "—" : result.summary.price, icon: "dollarsign.circle")
                }

                // 分组 1：核心交易标识 (带一键复制)
                GroupBox {
                    VStack(spacing: 8) {
                        copyableInfoRow("交易 ID (Transaction ID)", result.summary.transactionID)
                        copyableInfoRow("原始交易 ID (Original ID)", result.summary.originalTransactionID)
                        if !result.summary.appAccountToken.isEmpty {
                            copyableInfoRow("App Account Token", result.summary.appAccountToken)
                        }
                        if !result.summary.bundleID.isEmpty {
                            copyableInfoRow("Bundle ID", result.summary.bundleID)
                        }
                    }
                    .padding(.vertical, 4)
                } label: {
                    Label("核心交易标识", systemImage: "key.fill")
                        .font(.subheadline.bold())
                }

                // 分组 2：商品与计费属性
                GroupBox {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                        infoRow("商品 ID", result.summary.productID)
                        infoRow("商品类型", result.summary.productType)
                        if !result.summary.billingPlanType.isEmpty {
                            infoRow("订阅计费方式", result.summary.billingPlanType)
                        }
                        if !result.summary.commitmentInfo.isEmpty {
                            infoRow("订阅承诺信息", result.summary.commitmentInfo)
                        }
                        infoRow("交易原因", result.summary.transactionReason)
                        infoRow("商店国家/地区", result.summary.storefront)
                        infoRow("购买方式", result.summary.ownership)
                        infoRow("购买数量", result.summary.quantity)
                        if !result.summary.expirationDate.isEmpty {
                            infoRow("到期时间", result.summary.expirationDate)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                } label: {
                    Label("商品与计费属性", systemImage: "doc.text.fill")
                        .font(.subheadline.bold())
                }

                // 分组 3：退款与撤销详情 (若有退款高亮展示)
                if !result.summary.revocationDate.isEmpty || !result.summary.refundReason.isEmpty || result.summary.status.contains("退款") {
                    GroupBox {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                            infoRow("撤销 / 退款时间", result.summary.revocationDate.isEmpty ? "—" : result.summary.revocationDate)
                            if !result.summary.refundType.isEmpty {
                                infoRow("退款类型", result.summary.refundType)
                            }
                            if !result.summary.refundReason.isEmpty {
                                infoRow("退款原因", result.summary.refundReason)
                            }
                            if !result.summary.refundPercentage.isEmpty {
                                infoRow("退款比例", result.summary.refundPercentage)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    } label: {
                        Label("退款与撤销详情", systemImage: "exclamationmark.shield.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(.red)
                    }
                }

                // 分组 4：优惠与活动 (若有)
                if !result.summary.offerType.isEmpty || !result.summary.offerIdentifier.isEmpty {
                    GroupBox {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                            if !result.summary.offerType.isEmpty {
                                infoRow("优惠类型", result.summary.offerType)
                            }
                            if !result.summary.offerIdentifier.isEmpty {
                                infoRow("优惠标识", result.summary.offerIdentifier)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    } label: {
                        Label("优惠与促销信息", systemImage: "tag.fill")
                            .font(.subheadline.bold())
                    }
                }

                // 分组 5：App Transaction 信息
                if let appTransaction = result.appTransaction {
                    GroupBox {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                            copyableInfoRow("App Transaction ID", appTransaction.appTransactionID)
                            infoRow("Bundle ID", appTransaction.bundleID)
                            infoRow("首次下载时间", appTransaction.appPurchaseDate)
                            infoRow("原始 App 版本", appTransaction.originalAppVersion)
                            infoRow("原始平台", appTransaction.originalPlatform)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    } label: {
                        Label("App Transaction 信息", systemImage: "app.badge.fill")
                            .font(.subheadline.bold())
                    }
                }

                // 分组 6：交易事件时间线
                GroupBox {
                    if result.timeline.isEmpty {
                        Text("暂无可排序的交易事件").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(result.timeline.enumerated()), id: \.element.id) { index, event in
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(spacing: 0) {
                                        Image(systemName: event.symbol)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(event.isWarning ? .orange : .accentColor)
                                            .frame(width: 20, height: 20)
                                            .background(event.isWarning ? Color.orange.opacity(0.12) : Color.accentColor.opacity(0.1), in: Circle())
                                        if index < result.timeline.count - 1 {
                                            Rectangle().fill(.quaternary).frame(width: 1, height: 28)
                                        }
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(event.title).font(.callout.weight(.medium))
                                            Spacer()
                                            Text(event.occurredAt.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month().day().hour().minute().second()))
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                        if !event.detail.isEmpty {
                                            Text(event.detail).font(.caption2).foregroundStyle(.secondary)
                                        }
                                        if !event.identifier.isEmpty {
                                            HStack(spacing: 6) {
                                                Text(event.identifier).font(.system(.caption2, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                                                CopyButton(text: event.identifier, onCopied: { onShowToast("已复制: \(event.identifier)") })
                                            }
                                        }
                                    }
                                    .padding(.top, 1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                } label: {
                    Label("交易事件时间线", systemImage: "timeline.selection")
                        .font(.subheadline.bold())
                }
            }
            .padding(.bottom, 16)
        }
    }

    private func statusTile(_ title: String, value: String, icon: String, highlight: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption2).foregroundStyle(.secondary)
            Text(value.isEmpty ? "暂无" : value)
                .font(.headline)
                .foregroundStyle(highlight ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    private func copyableInfoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
                .font(.callout)
                .frame(width: 190, alignment: .leading)

            Text(value.isEmpty ? "—" : value)
                .textSelection(.enabled)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if !value.isEmpty {
                CopyButton(text: value, onCopied: { onShowToast("已复制 \(title)") })
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).font(.callout).frame(width: 130, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .textSelection(.enabled)
                .font(value.allSatisfy(\.isNumber) && !value.isEmpty ? .system(.callout, design: .monospaced) : .callout)
        }
    }

    private func transactionList(_ items: [TransactionSummary], empty: String) -> some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(empty, systemImage: "tray")
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
                            }
                            HStack(spacing: 6) {
                                Text("交易 ID: \(item.transactionID)")
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                CopyButton(text: item.transactionID, onCopied: { onShowToast("已复制交易 ID") })
                            }
                            HStack(spacing: 12) {
                                Text("本次交易: \(item.purchaseDate)")
                                if !item.price.isEmpty { Text("金额: \(item.price)") }
                                if !item.refundReason.isEmpty { Text("退款原因: \(item.refundReason)").foregroundStyle(.red) }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("查询此笔") {
                            onInspectTransaction(item.transactionID)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var subscriptionList: some View {
        Group {
            if result.subscriptions.isEmpty {
                ContentUnavailableView("没有返回订阅状态", systemImage: "calendar.badge.clock")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !result.subscriptionStatuses.isEmpty {
                        Text("状态筛选：\(result.subscriptionStatuses.compactMap { SubscriptionStatusFilter(rawValue: $0)?.title }.joined(separator: "、"))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(result.subscriptions) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(ProductCatalog.lookupName(for: item.productID)).font(.headline)
                            Spacer()
                            Text(item.status)
                                .font(.caption.bold())
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(item.status == "有效" ? Color.green.opacity(0.1) : Color.orange.opacity(0.1), in: Capsule())
                                .foregroundStyle(item.status == "有效" ? .green : .orange)
                        }
                        HStack(spacing: 6) {
                            Text("Product ID: \(item.productID)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            CopyButton(text: item.productID, onCopied: { onShowToast("已复制 Product ID") })
                        }
                        Text("到期时间：\(item.expirationDate.isEmpty ? "暂无" : item.expirationDate)").font(.caption).foregroundStyle(.secondary)
                        if !item.billingPlanType.isEmpty { Text("当前计费方式：\(item.billingPlanType)").font(.caption).foregroundStyle(.secondary) }
                        if !item.renewalBillingPlanType.isEmpty { Text("续订计费方式：\(item.renewalBillingPlanType)").font(.caption).foregroundStyle(.secondary) }
                        if !item.renewalCommitmentInfo.isEmpty { Text("续订承诺：\(item.renewalCommitmentInfo)").font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var notificationList: some View {
        Group {
            if result.notifications.isEmpty {
                ContentUnavailableView("没有返回通知历史", systemImage: "bell.slash", description: Text("Apple 仅保留近 180 天 (Production) 或近 30 天 (Sandbox) 的通知投递记录。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if result.notificationFailuresOnly {
                        Text("仅显示 Apple 判定未成功投递或仍在重试的通知")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(result.notifications) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.type).font(.headline)
                            if !item.subtype.isEmpty {
                                Text(item.subtype).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                            }
                            Spacer()
                            Text(item.deliveryStatus)
                                .font(.caption.bold())
                                .foregroundStyle(item.isFailure ? .red : .green)
                        }
                        Text("时间: \(item.date)").font(.caption).foregroundStyle(.secondary)
                        Text(item.rawPayload).font(.system(size: 10, design: .monospaced)).lineLimit(2).textSelection(.enabled).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var rawData: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Apple 返回原始 JSON").font(.headline)
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
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        }
        .padding(20)
    }
}

// MARK: - JWS Inspector View
struct JWSInspectorView: View {
    var onInspectTransaction: ((String) -> Void)? = nil
    var onShowToast: ((String) -> Void)? = nil
    @State private var inputJWS = ""
    @State private var result: JWSInspectionResult?
    @State private var copyMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("JWS 离线解析与验签").font(.title2.bold())
                    Text("输入 StoreKit 2 或 App Store Server JWS 字符串，离线解码 Payload 并校验 Apple X.509 证书链").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        if let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty {
                            inputJWS = clip
                        }
                    } label: {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)
                    .help("一键粘贴剪贴板中的 JWS 字符串")

                    if !inputJWS.isEmpty {
                        Button("清空") { inputJWS = ""; result = nil }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }

            HStack(alignment: .top, spacing: 10) {
                TextEditor(text: $inputJWS)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 80)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

                Button("解析 & 验签") {
                    result = AppleJWT.inspectJWS(inputJWS)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(inputJWS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let result {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // 验签状态徽章
                        HStack(spacing: 12) {
                            HStack(spacing: 6) {
                                Image(systemName: result.isValidSignature ? "checkmark.seal.fill" : "xmark.seal.fill")
                                Text(result.isValidSignature ? "ES256 签名有效" : "签名无效")
                            }
                            .font(.callout.bold())
                            .foregroundStyle(result.isValidSignature ? .green : .red)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(result.isValidSignature ? Color.green.opacity(0.1) : Color.red.opacity(0.1), in: Capsule())

                            HStack(spacing: 6) {
                                Image(systemName: result.isAppleRootTrusted ? "lock.shield.fill" : "exclamationmark.shield.fill")
                                Text(result.isAppleRootTrusted ? "Apple Root 证书链受信任" : "证书链未通过校验")
                            }
                            .font(.callout.bold())
                            .foregroundStyle(result.isAppleRootTrusted ? .green : .orange)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(result.isAppleRootTrusted ? Color.green.opacity(0.1) : Color.orange.opacity(0.1), in: Capsule())

                            Spacer()
                        }

                        if let err = result.errorMessage {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }

                        // 快捷提取卡片
                        if !result.summaryItems.isEmpty {
                            GroupBox("提取关键字段") {
                                VStack(spacing: 8) {
                                    ForEach(result.summaryItems, id: \.key) { item in
                                        HStack {
                                            Text(item.key + ":")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .frame(width: 140, alignment: .leading)
                                            Text(item.value)
                                                .font(.system(.caption, design: .monospaced).bold())
                                                .textSelection(.enabled)
                                                .lineLimit(1)
                                                .truncationMode(.middle)

                                            Spacer()

                                            CopyButton(text: item.value, onCopied: { onShowToast?("已复制 \(item.key)") })

                                            if (item.key.lowercased().contains("transactionid") || item.key.lowercased().contains("originaltransactionid")) && !item.value.isEmpty {
                                                Button("在交易查询中查看") {
                                                    onInspectTransaction?(item.value)
                                                }
                                                .buttonStyle(.bordered)
                                                .controlSize(.small)
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }

                        // 证书链信息
                        if !result.certificateChainSummaries.isEmpty {
                            GroupBox("证书链详情 (x5c)") {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(result.certificateChainSummaries, id: \.self) { cert in
                                        Text(cert).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }

                        // Payload JSON
                        GroupBox("Decoded Payload JSON") {
                            ScrollView([.horizontal, .vertical]) {
                                Text(result.payloadJSON)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .padding(8)
                            }
                            .frame(minHeight: 120)
                        }
                    }
                    .padding(.bottom, 20)
                }
            } else {
                ContentUnavailableView("等待解析 JWS", systemImage: "key.horizontal", description: Text("在上方输入或粘贴 StoreKit 2 / App Store Server JWS 字符串，点击「解析 & 验签」查看 Payload 与证书链。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
    }
}

// MARK: - Notification Test View
struct NotificationTestView: View {
    let service: AppleAPIService
    let settings: InspectorSettings
    @State private var environment = AppleEnvironment.sandbox
    @State private var isRequesting = false
    @State private var isChecking = false
    @State private var testToken: String?
    @State private var testResultJSON: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("测试通知调试 (Request Test Notification)").font(.title2.bold())
                    Text("调用 Apple POST /inApps/v1/notifications/test，要求 Apple 向开发者服务器主动发送一条测试通知").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 12) {
                Picker("目标环境", selection: $environment) {
                    ForEach(AppleEnvironment.allCases, id: \.self) { env in
                        Text(env.title).tag(env)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                Button {
                    Task { await sendTestNotification() }
                } label: {
                    if isRequesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("向 Apple 请求发送测试通知", systemImage: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRequesting || !settings.isConfigured)

                if let token = testToken {
                    Button {
                        Task { await checkStatus(token: token) }
                    } label: {
                        if isChecking {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("查询 Apple 投递结果", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isChecking)
                }
            }

            if let token = testToken {
                GroupBox("Test Notification Token") {
                    HStack {
                        Text(token).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                        Spacer()
                        Button("复制") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(token, forType: .string)
                        }.buttonStyle(.borderless)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }

            if let testResultJSON {
                GroupBox("投递结果 (Response Payload)") {
                    ScrollView([.horizontal, .vertical]) {
                        Text(testResultJSON)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(8)
                    }
                }
            } else {
                ContentUnavailableView("点击上方按钮发起测试", systemImage: "bell.badge", description: Text("Apple 将向您在 App Store Connect 中配置的 Server Notification V2 URL 发送一条 TEST 类型的通知。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
    }

    @MainActor private func sendTestNotification() async {
        isRequesting = true
        errorMessage = nil
        testResultJSON = nil
        defer { isRequesting = false }
        do {
            let token = try await service.requestTestNotification(environment: environment, settings: settings)
            testToken = token
            // 自动拉取一次状态
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await checkStatus(token: token)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor private func checkStatus(token: String) async {
        isChecking = true
        errorMessage = nil
        defer { isChecking = false }
        do {
            let data = try await service.getTestNotificationStatus(token: token, environment: environment, settings: settings)
            let json = (try? String(data: JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)) ?? "{}"
            testResultJSON = json
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Product Catalog View
struct ProductCatalogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items = ProductCatalog.load()
    @State private var newProductID = ""
    @State private var newDisplayName = ""
    @State private var searchText = ""

    var filteredItems: [ProductItem] {
        if searchText.isEmpty { return items }
        return items.filter { $0.productID.localizedCaseInsensitiveContains(searchText) || $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("商品库管理").font(.title2.bold())
                    Text("自定义 Product ID 到可读商品名称的映射，查询时自动匹配展示").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).frame(width: 26, height: 26).background(.quaternary, in: Circle())
                }.buttonStyle(.plain)
            }

            // 新增栏
            HStack(spacing: 8) {
                TextField("Product ID (如 gg.epal.buff_0001)", text: $newProductID)
                    .textFieldStyle(.roundedBorder)
                TextField("商品展示名称 (如 Buff 4.99 USD)", text: $newDisplayName)
                    .textFieldStyle(.roundedBorder)
                Button("添加") {
                    let pid = newProductID.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = newDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !pid.isEmpty && !name.isEmpty else { return }
                    items.removeAll { $0.productID == pid }
                    items.insert(ProductItem(productID: pid, displayName: name), at: 0)
                    ProductCatalog.save(items)
                    newProductID = ""
                    newDisplayName = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(newProductID.isEmpty || newDisplayName.isEmpty)
            }

            HStack {
                TextField("搜索商品 ID 或名称...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Spacer()
                Button("恢复默认预设") {
                    ProductCatalog.resetToDefault()
                    items = ProductCatalog.load()
                }
                .buttonStyle(.bordered)
            }

            if filteredItems.isEmpty {
                ContentUnavailableView("暂无匹配的商品", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredItems) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.displayName).font(.headline)
                                Text(item.productID).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                items.removeAll { $0.productID == item.productID }
                                ProductCatalog.save(items)
                            } label: {
                                Image(systemName: "trash").foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
    }
}

// MARK: - History List View
struct HistoryListView: View {
    @Binding var history: [QueryHistoryItem]
    var onSelect: (QueryHistoryItem) -> Void
    @State private var searchText = ""
    @State private var editingItem: QueryHistoryItem?
    @State private var noteText = ""
    @State private var showingRetentionSettings = false
    @State private var historyLimit = QueryHistory.maximumCount
    @State private var historyRetention = QueryHistory.retentionDays

    var filteredHistory: [QueryHistoryItem] {
        if searchText.isEmpty { return history }
        return history.filter {
            $0.identifier.localizedCaseInsensitiveContains(searchText) ||
            ($0.note?.localizedCaseInsensitiveContains(searchText) == true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近查询历史").font(.title2.bold())
                Spacer()
                Button {
                    showingRetentionSettings = true
                } label: {
                    Label("保留策略", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $showingRetentionSettings, arrowEdge: .bottom) {
                    retentionSettings
                }
                if !history.isEmpty {
                    Button("清空历史") {
                        history.removeAll()
                        QueryHistory.save(history)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .font(.caption)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Text("\(history.count) 条记录 · \(historyLimitDescription) · \(historyRetentionDescription)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)

            TextField("搜索历史 ID 或备注...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20)

            if filteredHistory.isEmpty {
                ContentUnavailableView("暂无匹配的历史记录", systemImage: "clock")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredHistory) { item in
                        HStack {
                            Button {
                                onSelect(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(item.identifier)
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        if let note = item.note, !note.isEmpty {
                                            Text(note)
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(Color.yellow.opacity(0.2), in: Capsule())
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    HStack(spacing: 8) {
                                        Text(item.queryType.title)
                                        Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                        if let env = item.environment {
                                            Text("·  \(env)")
                                        }
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Button {
                                editingItem = item
                                noteText = item.note ?? ""
                            } label: {
                                Image(systemName: "pencil.line")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("修改备注")

                            Button(role: .destructive) {
                                history.removeAll { $0.id == item.id }
                                QueryHistory.save(history)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .help("删除这条查询记录")
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { offsets in
                        history.remove(atOffsets: offsets)
                        QueryHistory.save(history)
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(item: $editingItem) { item in
            VStack(alignment: .leading, spacing: 14) {
                Text("编辑查询备注").font(.headline)
                Text(item.identifier).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                TextField("如：客诉争议、沙盒连环订阅测试...", text: $noteText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("取消") { editingItem = nil }.buttonStyle(.plain)
                    Spacer()
                    Button("保存") {
                        if let idx = history.firstIndex(where: { $0.id == item.id }) {
                            history[idx].note = noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : noteText
                            QueryHistory.save(history)
                        }
                        editingItem = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 380)
        }
    }

    private var retentionSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("历史记录保留").font(.headline)
            Picker("最多保留", selection: $historyLimit) {
                Text("20 条").tag(20)
                Text("50 条").tag(50)
                Text("100 条").tag(100)
                Text("不限").tag(0)
            }
            Picker("自动清理", selection: $historyRetention) {
                Text("关闭").tag(0)
                Text("30 天").tag(30)
                Text("90 天").tag(90)
                Text("180 天").tag(180)
            }
            Text("仅保存查询标识、时间、环境、类型和备注。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 260)
        .onChange(of: historyLimit) { _, _ in saveHistoryPolicy() }
        .onChange(of: historyRetention) { _, _ in saveHistoryPolicy() }
    }

    private var historyLimitDescription: String {
        historyLimit == 0 ? "不限条数" : "最多 \(historyLimit) 条"
    }

    private var historyRetentionDescription: String {
        historyRetention == 0 ? "不自动清理" : "保留 \(historyRetention) 天"
    }

    private func saveHistoryPolicy() {
        QueryHistory.setPolicy(maximumCount: historyLimit, retentionDays: historyRetention)
        history = QueryHistory.load()
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @Binding var settings: InspectorSettings
    @Environment(\.dismiss) private var dismiss
    @State private var privateKey = KeychainStore.read() ?? ""
    @State private var selectedKeyFile: URL?
    @State private var showingImporter = false
    @State private var statusMessage: String?
    @State private var isTesting = false
    private let service = AppleAPIService()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple API 设置").font(.title2.bold())
                    Text("凭证仅保存在本机 Keychain 中，所有请求直接连通 Apple").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).frame(width: 28, height: 28).background(.quaternary.opacity(0.55), in: Circle())
                }.buttonStyle(.plain).help("关闭")
            }

            Form {
                TextField("Bundle ID", text: $settings.bundleID, prompt: Text("com.example.app"))
                TextField("Issuer ID", text: $settings.issuerID, prompt: Text("App Store Connect Issuer ID"))
                TextField("Key ID", text: $settings.keyID, prompt: Text("In-App Purchase Key ID"))
                HStack {
                    Text(selectedKeyFile?.lastPathComponent ?? (KeychainStore.read() == nil ? "尚未导入 .p8 私钥" : "私钥已安全保存至 Keychain"))
                        .lineLimit(1).foregroundStyle(.secondary)
                    Spacer()
                    Button("选择 .p8 文件…") { showingImporter = true }
                }
                SecureField("或在此粘贴 .p8 内容", text: $privateKey)

            }

            HStack {
                Button("测试连接并保存") { Task { await testAndSave() } }
                    .buttonStyle(.borderedProminent).disabled(isTesting)
                if isTesting { ProgressView().controlSize(.small) }
                Spacer()
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusMessage.hasPrefix("连接成功") ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            HStack {
                Text("私钥将加密存储在 macOS Keychain。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("移除凭证") {
                    KeychainStore.delete()
                    privateKey = ""
                    settings = .empty
                    statusMessage = "已移除凭证"
                }.foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { outcome in
            switch outcome {
            case .success(let urls):
                selectedKeyFile = urls.first
                if let url = urls.first {
                    do {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        privateKey = try String(contentsOf: url, encoding: .utf8)
                    } catch {
                        statusMessage = "无法读取私钥文件"
                    }
                }
            case .failure:
                statusMessage = "文件读取已取消"
            }
        }
    }

    @MainActor private func testAndSave() async {
        guard settings.isConfigured else {
            statusMessage = "请填写 Bundle ID、Issuer ID 和 Key ID"
            return
        }
        let key = privateKey.isEmpty ? KeychainStore.read() : privateKey
        guard let key, !key.isEmpty else {
            statusMessage = "请导入 .p8 私钥"
            return
        }
        isTesting = true
        defer { isTesting = false }
        do {
            try KeychainStore.save(key)
            settings.save()
            try await service.testConnection(settings: settings)
            statusMessage = "连接成功，凭证有效（测试编号无效为预期），配置已保存"
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

// MARK: - 快捷复制按钮组件
struct CopyButton: View {
    let text: String
    var title: String? = nil
    var onCopied: (() -> Void)? = nil
    @State private var isCopied = false

    var body: some View {
        Button {
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.easeInOut(duration: 0.15)) {
                isCopied = true
            }
            onCopied?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isCopied = false
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: isCopied ? .bold : .regular))
                    .foregroundStyle(isCopied ? Color.green : Color.secondary)
                if let title {
                    Text(isCopied ? "已复制" : title)
                        .font(.caption2)
                        .foregroundStyle(isCopied ? Color.green : Color.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCopied ? "已复制到剪贴板" : "复制")
    }
}
