# IAP Inspector

IAP Inspector 是一款 macOS 原生工具，用于查询和排查 Apple App Store 内购、订阅与通知问题。

## 主要功能

- 查询交易、订单、订阅、退款及通知记录
- 离线解析 App Store Receipt 和 JWS 数据
- 请求并检查 Apple 测试通知
- 管理商品名称映射和本机查询历史
- 导出 Markdown 排查报告

## 开始使用

在 Xcode 中打开 `IAP Inspector.xcodeproj`，选择 `IAP Inspector` scheme 并运行。首次使用时，在应用的「API 设置」中配置 App Store Connect In-App Purchase API 凭证。

也可以在终端构建：

```bash
xcodebuild -project "IAP Inspector.xcodeproj" \
  -scheme "IAP Inspector" \
  -configuration Debug \
  -sdk macosx \
  CODE_SIGNING_ALLOWED=NO \
  build
```

详细配置与功能说明见[使用文档](使用文档.md)。
