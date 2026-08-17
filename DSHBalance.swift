import Cocoa

// ===================== 余额模型 =====================

/// 统一余额快照：无论官方 DeepSeek 还是第三方接口，都解析成这个结构
struct BalanceSnapshot {
    var currency: String
    var total: String             // 当前余额
    var available: Bool           // 账户是否可用
    var details: [(String, String)] // 明细行（菜单展示）
}

// ===================== 日志 =====================

let logPath = NSHomeDirectory() + "/Library/Logs/dshbalance.log"

func appendToFile(_ path: String, _ text: String) {
    guard let data = text.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: path)
    if FileManager.default.fileExists(atPath: path),
       let fh = try? FileHandle(forWritingTo: url) {
        fh.seekToEndOfFile()
        fh.write(data)
        try? fh.close()
    } else {
        try? data.write(to: url)
    }
}

func appendLog(_ msg: String) {
    appendToFile(logPath, "[\(Date())] \(msg)\n")
}

// ===================== 余额历史（只在余额变化时记录） =====================

let historyPath = NSHomeDirectory() + "/Library/Application Support/DSH Balance/history.jsonl"

/// 读取某数据源的历史变化点（升序）
func loadHistory(sourceKey: String) -> [(t: Double, b: Double)] {
    guard let content = try? String(contentsOfFile: historyPath, encoding: .utf8) else { return [] }
    var out: [(Double, Double)] = []
    for line in content.split(separator: "\n") {
        guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let t = d["t"] as? Double, let b = d["b"] as? Double,
              let s = d["s"] as? String, s == sourceKey else { continue }
        out.append((t, b))
    }
    return out
}

func lastHistoryEntry() -> (t: Double, b: Double, s: String)? {
    guard let content = try? String(contentsOfFile: historyPath, encoding: .utf8),
          let lastLine = content.split(separator: "\n").last else { return nil }
    guard let d = try? JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: Any],
          let t = d["t"] as? Double, let b = d["b"] as? Double, let s = d["s"] as? String else { return nil }
    return (t, b, s)
}

/// 与最后一条相同则跳过；否则追加一条变化记录
func recordHistory(sourceKey: String, t: Double, b: Double) {
    if let last = lastHistoryEntry(), last.s == sourceKey, abs(last.b - b) < 0.000001 {
        return
    }
    let obj: [String: Any] = ["t": t, "b": b, "s": sourceKey]
    if let data = try? JSONSerialization.data(withJSONObject: obj),
       let line = String(data: data, encoding: .utf8) {
        appendToFile(historyPath, line + "\n")
    }
}

// ===================== 消耗聚合 =====================

/// 把变化点历史聚合成各时间区间的消耗。
/// 每个变化点（i>=1）的消耗 = max(0, 前值 - 现值)，归入该变化点所在区间。
func aggregateConsumption(history: [(t: Double, b: Double)],
                          ranges: [(start: Double, end: Double)]) -> [Double] {
    var out = [Double](repeating: 0, count: ranges.count)
    guard history.count >= 2 else { return out }
    for i in 1..<history.count {
        let consumption = max(0, history[i - 1].b - history[i].b)
        guard consumption > 0 else { continue }
        let t = history[i].t
        for (idx, r) in ranges.enumerated() where t >= r.start && t < r.end {
            out[idx] += consumption
            break
        }
    }
    return out
}

func hourlyRanges(now: Date, count: Int = 24) -> [(start: Double, end: Double)] {
    let cal = Calendar.current
    let comp = cal.dateComponents([.year, .month, .day, .hour], from: now)
    guard let thisHour = cal.date(from: comp) else { return [] }
    var ranges: [(start: Double, end: Double)] = []
    for i in stride(from: count - 1, through: 0, by: -1) {
        let start = cal.date(byAdding: .hour, value: -i, to: thisHour)!
        let end = cal.date(byAdding: .hour, value: 1, to: start)!
        ranges.append((start.timeIntervalSince1970, end.timeIntervalSince1970))
    }
    return ranges
}

func weeklyRanges(now: Date, count: Int = 8) -> [(start: Double, end: Double)] {
    let cal = Calendar.current
    guard let thisWeek = cal.dateInterval(of: .weekOfYear, for: now) else { return [] }
    var ranges: [(start: Double, end: Double)] = []
    for i in stride(from: count - 1, through: 0, by: -1) {
        let start = cal.date(byAdding: .weekOfYear, value: -i, to: thisWeek.start)!
        let end = cal.date(byAdding: .weekOfYear, value: 1, to: start)!
        ranges.append((start.timeIntervalSince1970, end.timeIntervalSince1970))
    }
    return ranges
}

func monthlyRanges(now: Date, count: Int = 6) -> [(start: Double, end: Double)] {
    let cal = Calendar.current
    let comp = cal.dateComponents([.year, .month], from: now)
    guard let thisMonth = cal.date(from: comp) else { return [] }
    var ranges: [(start: Double, end: Double)] = []
    for i in stride(from: count - 1, through: 0, by: -1) {
        let start = cal.date(byAdding: .month, value: -i, to: thisMonth)!
        let end = cal.date(byAdding: .month, value: 1, to: start)!
        ranges.append((start.timeIntervalSince1970, end.timeIntervalSince1970))
    }
    return ranges
}

/// 15 分钟粒度：最近 1 小时，每 15 分钟一个区间（共 4 个），起点对齐 15 分钟边界
func quarterHourRanges(now: Date) -> [(start: Double, end: Double)] {
    let span = 15 * 60.0
    let alignedNow = floor(now.timeIntervalSince1970 / span) * span
    var ranges: [(start: Double, end: Double)] = []
    for i in 0..<4 {
        let s = alignedNow - span * Double(3 - i)
        ranges.append((s, s + span))
    }
    return ranges
}

/// 每日粒度：最近 count 天，每天一个区间（日起点对齐）
func dailyRanges(now: Date, count: Int = 14) -> [(start: Double, end: Double)] {
    let cal = Calendar.current
    let comp = cal.dateComponents([.year, .month, .day], from: now)
    guard let today = cal.date(from: comp) else { return [] }
    var ranges: [(start: Double, end: Double)] = []
    for i in stride(from: count - 1, through: 0, by: -1) {
        let start = cal.date(byAdding: .day, value: -i, to: today)!
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        ranges.append((start.timeIntervalSince1970, end.timeIntervalSince1970))
    }
    return ranges
}

let hourLabelFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:00"; return f }()
let minuteLabelFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
let dayLabelFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM/dd"; return f }()
let monthLabelFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yy/MM"; return f }()

func formatNumber(_ v: Double) -> String {
    if v >= 100 { return String(format: "%.0f", v) }
    if v >= 10 { return String(format: "%.1f", v) }
    return String(format: "%.2f", v)
}

// ===================== 折线图视图 =====================

final class ChartView: NSView {
    var points: [(label: String, value: Double)] = []
    /// 纵坐标单位后缀（如 "M" 表示百万 token）
    var unitSuffix: String = ""

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        let plot = bounds.insetBy(dx: 52, dy: 26)

        guard !points.isEmpty else {
            drawCentered("暂无数据", in: bounds)
            return
        }
        let maxV = points.map { $0.value }.max() ?? 0
        if maxV <= 0 {
            drawCentered("暂无消耗数据（历史从安装本工具后开始积累）", in: bounds)
            return
        }

        // 网格 + Y 轴标签
        NSColor.separatorColor.setStroke()
        for i in 0...3 {
            let y = plot.minY + plot.height * CGFloat(i) / 3
            let grid = NSBezierPath()
            grid.move(to: NSPoint(x: plot.minX, y: y))
            grid.line(to: NSPoint(x: plot.maxX, y: y))
            grid.lineWidth = 0.5
            grid.stroke()
            let v = maxV * Double(i) / 3
            drawText(formatNumber(v) + unitSuffix, at: NSPoint(x: 6, y: y - 7), size: 10)
        }

        // X 轴标签（最多 6 个）
        let n = points.count
        let step = max(1, n / 6)
        var i = 0
        while i < n {
            let x = plot.minX + plot.width * CGFloat(i) / CGFloat(max(1, n - 1))
            drawText(points[i].label, at: NSPoint(x: x - 20, y: plot.minY - 20), size: 9)
            i += step
        }

        // 平滑折线（Catmull-Rom → 三次贝塞尔）
        var pts: [NSPoint] = []
        for i in 0..<n {
            let x = plot.minX + plot.width * CGFloat(i) / CGFloat(max(1, n - 1))
            let y = plot.minY + plot.height * CGFloat(points[i].value / maxV)
            pts.append(NSPoint(x: x, y: y))
        }
        let line = NSBezierPath()
        line.move(to: pts[0])
        if pts.count == 2 {
            line.line(to: pts[1])
        } else {
            for i in 0..<(pts.count - 1) {
                let p0 = pts[max(0, i - 1)]
                let p1 = pts[i]
                let p2 = pts[i + 1]
                let p3 = pts[min(pts.count - 1, i + 2)]
                let c1 = NSPoint(x: p1.x + (p2.x - p0.x) / 6,
                                 y: p1.y + (p2.y - p0.y) / 6)
                let c2 = NSPoint(x: p2.x - (p3.x - p1.x) / 6,
                                 y: p2.y - (p3.y - p1.y) / 6)
                line.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
            }
        }
        NSColor.systemBlue.setStroke()
        line.lineWidth = 2
        line.lineCapStyle = .round
        line.lineJoinStyle = .round
        line.stroke()

        // 数据点（点数过多时省略，避免过密）
        if n <= 60 {
            NSColor.systemBlue.setFill()
            for p in pts {
                let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5))
                dot.fill()
            }
        }
    }

    private func drawText(_ s: String, at p: NSPoint, size: CGFloat) {
        (s as NSString).draw(at: p, withAttributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    private func drawCentered(_ s: String, in r: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let sz = (s as NSString).size(withAttributes: attrs)
        (s as NSString).draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2),
                             withAttributes: attrs)
    }
}

// ===================== 图表面板 =====================

final class ChartPanelController: NSObject {
    let panel: NSPanel
    let chartView = ChartView()
    let seg = NSSegmentedControl(labels: ["15分钟", "每天", "每周", "每月"],
                                 trackingMode: .selectOne, target: nil, action: nil)
    let summaryLabel = NSTextField(labelWithString: "")
    var history: [(t: Double, b: Double)] = []
    var costPerMillionTokens: Double = 2.5

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 384),
                        styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        super.init()

        panel.title = "消耗图表"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating

        seg.frame = NSRect(x: 110, y: 16, width: 300, height: 26)
        seg.selectedSegment = 0
        seg.target = self
        seg.action = #selector(segChanged)

        chartView.frame = NSRect(x: 16, y: 52, width: 488, height: 300)

        summaryLabel.frame = NSRect(x: 16, y: 360, width: 488, height: 18)
        summaryLabel.font = NSFont.systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor

        panel.contentView?.addSubview(seg)
        panel.contentView?.addSubview(chartView)
        panel.contentView?.addSubview(summaryLabel)
    }

    func show() {
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        appendLog("图表面板已显示")
    }

    @objc func segChanged() {
        refreshChart()
    }

    func refreshChart() {
        let now = Date()
        let ranges: [(start: Double, end: Double)]
        let labels: [String]
        let unit: String
        switch seg.selectedSegment {
        case 1:
            ranges = dailyRanges(now: now)
            labels = ranges.map { dayLabelFmt.string(from: Date(timeIntervalSince1970: $0.start)) }
            unit = "天"
        case 2:
            ranges = weeklyRanges(now: now)
            labels = ranges.map { dayLabelFmt.string(from: Date(timeIntervalSince1970: $0.start)) }
            unit = "周"
        case 3:
            ranges = monthlyRanges(now: now)
            labels = ranges.map { monthLabelFmt.string(from: Date(timeIntervalSince1970: $0.start)) }
            unit = "月"
        default:
            // 15 分钟粒度：最近 1 小时
            ranges = quarterHourRanges(now: now)
            labels = ranges.map { minuteLabelFmt.string(from: Date(timeIntervalSince1970: $0.start)) }
            unit = "15分钟段"
        }
        let values = aggregateConsumption(history: history, ranges: ranges)
        // 金额消耗 → token 消耗（百万 token）：tokenM = 金额 / 单价
        let price = (costPerMillionTokens > 0) ? costPerMillionTokens : 2.5
        let tokenM = values.map { $0 / price }
        chartView.points = zip(labels, tokenM).map { (label: $0.0, value: $0.1) }
        chartView.unitSuffix = "M"
        chartView.needsDisplay = true

        let totalAmount = values.reduce(0, +)
        let totalTokens = totalAmount / price
        let nonZero = values.filter { $0 > 0 }.count
        summaryLabel.stringValue = "总消耗：约 \(formatNumber(totalTokens)) 百万 token（金额 \(formatNumber(totalAmount))，按 ¥\(formatNumber(price))/百万 token 估算；共 \(values.count) 个\(unit)，\(nonZero) 个有消耗）"
    }
}

// ===================== 配置 =====================

struct AppConfig: Codable {
    var refreshSeconds: Int = 60
    var apiKey: String? = nil
    /// 提供方："deepseek"（官方）| "custom"（自定义第三方）
    var provider: String = "deepseek"
    /// 第三方 Base URL（provider=custom 时生效）
    var baseURL: String? = nil
    /// 余额接口风格："deepseek"（/user/balance）| "openai"（/v1/dashboard/billing/credit_grants）| "custom"（自定义路径）
    var balanceStyle: String = "deepseek"
    /// 自定义余额接口路径（balanceStyle=custom 时生效）
    var balancePath: String? = nil
    /// 金额 → token 换算单价（元/百万 token），用于图表纵坐标
    var costPerMillionTokens: Double = 2.5

    enum CodingKeys: String, CodingKey {
        case refreshSeconds, apiKey, provider, baseURL, balanceStyle, balancePath, costPerMillionTokens
    }

    init(refreshSeconds: Int = 60, apiKey: String? = nil,
         provider: String = "deepseek", baseURL: String? = nil,
         balanceStyle: String = "deepseek", balancePath: String? = nil,
         costPerMillionTokens: Double = 2.5) {
        self.refreshSeconds = refreshSeconds
        self.apiKey = apiKey
        self.provider = provider
        self.baseURL = baseURL
        self.balanceStyle = balanceStyle
        self.balancePath = balancePath
        self.costPerMillionTokens = costPerMillionTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        refreshSeconds = try c.decodeIfPresent(Int.self, forKey: .refreshSeconds) ?? 60
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "deepseek"
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
        balanceStyle = try c.decodeIfPresent(String.self, forKey: .balanceStyle) ?? "deepseek"
        balancePath = try c.decodeIfPresent(String.self, forKey: .balancePath)
        costPerMillionTokens = try c.decodeIfPresent(Double.self, forKey: .costPerMillionTokens) ?? 2.5
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(refreshSeconds, forKey: .refreshSeconds)
        try c.encode(apiKey, forKey: .apiKey)
        try c.encode(provider, forKey: .provider)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(balanceStyle, forKey: .balanceStyle)
        try c.encode(balancePath, forKey: .balancePath)
        try c.encode(costPerMillionTokens, forKey: .costPerMillionTokens)
    }
}

let configPath = NSHomeDirectory() + "/Library/Application Support/DSH Balance/config.json"

func loadConfig() -> AppConfig {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
          let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else {
        return AppConfig()
    }
    return cfg
}

func saveConfig(_ cfg: AppConfig) {
    let url = URL(fileURLWithPath: configPath)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(cfg) {
        try? data.write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: configPath)
    }
}

// ===================== 提供方预设（来自 DSH 模型数据） =====================

/// DSH 支持的模型提供方及其官方 Base URL（多区域的取默认/首个）
let providerBaseURLs: [String: String] = [
    "deepseek": "https://api.deepseek.com",
    "amazon-bedrock": "https://bedrock-runtime.us-east-1.amazonaws.com",
    "ant-ling": "https://api.ant-ling.com/v1",
    "anthropic": "https://api.anthropic.com",
    "azure-openai-responses": "https://{RESOURCE}.openai.azure.com",
    "cerebras": "https://api.cerebras.ai/v1",
    "cloudflare-ai-gateway": "https://gateway.ai.cloudflare.com/v1/{CLOUDFLARE_ACCOUNT_ID}/{CLOUDFLARE_GATEWAY_ID}/openai",
    "cloudflare-workers-ai": "https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai/v1",
    "fireworks": "https://api.fireworks.ai/inference/v1",
    "github-copilot": "https://api.individual.githubcopilot.com",
    "google": "https://generativelanguage.googleapis.com/v1beta",
    "google-vertex": "https://{location}-aiplatform.googleapis.com",
    "groq": "https://api.groq.com/openai/v1",
    "huggingface": "https://router.huggingface.co/v1",
    "kimi-coding": "https://api.kimi.com/coding",
    "minimax": "https://api.minimax.io/anthropic",
    "minimax-cn": "https://api.minimaxi.com/anthropic",
    "mistral": "https://api.mistral.ai",
]

/// 提供方下拉选项顺序（与 DSH 页面一致）
let providerOptions: [String] = [
    "deepseek", "amazon-bedrock", "ant-ling", "anthropic",
    "azure-openai-responses", "cerebras", "cloudflare-ai-gateway",
    "cloudflare-workers-ai", "fireworks", "github-copilot", "google",
    "google-vertex", "groq", "huggingface", "kimi-coding", "minimax",
    "minimax-cn", "mistral",
]

func providerDisplayName(_ id: String) -> String {
    switch id {
    case "deepseek": return "官方 DeepSeek（DSH）"
    case "custom": return "自定义第三方"
    default: return id
    }
}

// ===================== DSH 凭据文件读取（回退用） =====================

func loadCredentialsAPIKey() -> String? {
    let path = NSHomeDirectory() + "/.dsh/.credentials.yaml"
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        return nil
    }
    for rawLine in content.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("DEEPSEEK_API_KEY") else { continue }
        guard let colon = line.firstIndex(of: ":") else { continue }
        var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if value.isEmpty { return nil }
        return value
    }
    return nil
}

// ===================== 余额查询 =====================

/// 根据配置构造余额查询请求并解析（apiKey 为已解析生效的 Key）
func fetchBalance(config: AppConfig, apiKey: String,
                  completion: @escaping (Result<BalanceSnapshot, Error>) -> Void) {
    let isCustom = (config.provider == "custom")
    let base: String
    if isCustom, let b = config.baseURL, !b.isEmpty {
        base = b.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    } else if let b = config.baseURL, !b.isEmpty {
        base = b.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    } else {
        base = providerBaseURLs[config.provider] ?? "https://api.deepseek.com"
    }

    let path: String
    switch config.balanceStyle {
    case "openai":
        path = "/v1/dashboard/billing/credit_grants"
    case "custom":
        let p = config.balancePath?.trimmingCharacters(in: .whitespaces) ?? ""
        path = p.isEmpty ? "/user/balance" : p
    default:
        path = "/user/balance"
    }
    let style = (config.balanceStyle == "openai") ? "openai"
        : (config.balanceStyle == "custom") ? "custom" : "deepseek"

    guard !apiKey.isEmpty, let url = URL(string: base + path) else {
        completion(.failure(NSError(domain: "DSHBalance", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "配置不完整：请检查 API Key / Base URL"])))
        return
    }

    var req = URLRequest(url: url)
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.timeoutInterval = 15

    let task = URLSession.shared.dataTask(with: req) { data, resp, err in
        if let err = err {
            completion(.failure(err))
            return
        }
        guard let http = resp as? HTTPURLResponse else {
            completion(.failure(NSError(domain: "DSHBalance", code: 2,
                                        userInfo: [NSLocalizedDescriptionKey: "无响应"])))
            return
        }
        guard http.statusCode == 200 else {
            completion(.failure(NSError(domain: "DSHBalance", code: http.statusCode,
                                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])))
            return
        }
        guard let data = data else {
            completion(.failure(NSError(domain: "DSHBalance", code: 3,
                                        userInfo: [NSLocalizedDescriptionKey: "响应为空"])))
            return
        }
        do {
            if style == "openai" {
                completion(.success(try parseOpenAIBalance(data)))
            } else {
                completion(.success(try parseDeepSeekBalance(data)))
            }
        } catch {
            completion(.failure(error))
        }
    }
    task.resume()
}

/// DeepSeek 风格：{ "is_available": true, "balance_infos": [ { "currency","total_balance","granted_balance","topped_up_balance" } ] }
func parseDeepSeekBalance(_ data: Data) throws -> BalanceSnapshot {
    struct Info: Decodable {
        let currency: String?
        let total_balance: String?
        let granted_balance: String?
        let topped_up_balance: String?
    }
    struct Resp: Decodable {
        let is_available: Bool?
        let balance_infos: [Info]?
    }
    let r = try JSONDecoder().decode(Resp.self, from: data)
    guard let info = r.balance_infos?.first else {
        throw NSError(domain: "DSHBalance", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "响应中没有 balance_infos"])
    }
    let total = info.total_balance ?? "0"
    let sym = currencySymbol(info.currency ?? "CNY")
    return BalanceSnapshot(
        currency: info.currency ?? "CNY",
        total: total,
        available: r.is_available ?? false,
        details: [
            ("充值余额", "\(sym)\(info.topped_up_balance ?? "0")"),
            ("赠送余额", "\(sym)\(info.granted_balance ?? "0")"),
            ("账户状态", (r.is_available ?? false) ? "可用" : "不可用"),
        ])
}

/// OpenAI 兼容风格：{ "total_granted": 100.0, "total_used": 30.0, "total_available": 70.0 }
func parseOpenAIBalance(_ data: Data) throws -> BalanceSnapshot {
    struct Resp: Decodable {
        let total_granted: Double?
        let total_used: Double?
        let total_available: Double?
    }
    let r = try JSONDecoder().decode(Resp.self, from: data)
    guard let avail = r.total_available else {
        throw NSError(domain: "DSHBalance", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "响应中没有 total_available"])
    }
    let f = { (v: Double?) -> String in String(format: "%.2f", v ?? 0) }
    return BalanceSnapshot(
        currency: "USD",
        total: f(avail),
        available: true,
        details: [
            ("总额度", "\(f(r.total_granted))"),
            ("已用", "\(f(r.total_used))"),
            ("可用", "\(f(avail))"),
        ])
}

func currencySymbol(_ currency: String) -> String {
    switch currency.uppercased() {
    case "CNY": return "¥"
    case "USD": return "$"
    case "EUR": return "€"
    default: return currency + " "
    }
}

// ===================== 命令行验证 =====================

/// --check：走官方接口查一次余额
func runCheck() -> Never {
    guard let key = loadCredentialsAPIKey() else {
        print("ERROR: 未找到 DEEPSEEK_API_KEY（凭据文件）")
        exit(1)
    }
    var cfg = AppConfig()
    cfg.apiKey = key
    let sem = DispatchSemaphore(value: 0)
    var out = "ERROR: 无结果"
    fetchBalance(config: cfg, apiKey: key) { result in
        switch result {
        case .success(let s):
            out = "OK \(s.currency) total=\(s.total) details=\(s.details.map { "\($0.0)=\($0.1)" }.joined(separator: ","))"
        case .failure(let e):
            out = "ERROR: \(e.localizedDescription)"
        }
        sem.signal()
    }
    sem.wait()
    print(out)
    exit(0)
}

/// --check-chart：打印当前数据源的消耗聚合结果
func runCheckChart() -> Never {
    let cfg = loadConfig()
    let sk = (cfg.provider == "custom") ? "custom|\(cfg.baseURL ?? "")" : "deepseek|https://api.deepseek.com"
    let hist = loadHistory(sourceKey: sk)
    print("数据源: \(sk)")
    print("历史变化点数量: \(hist.count)")
    guard hist.count >= 2 else {
        print("历史数据不足（需要至少 2 个余额变化点）")
        exit(0)
    }
    let now = Date()
    let hr = aggregateConsumption(history: hist, ranges: hourlyRanges(now: now))
    let wk = aggregateConsumption(history: hist, ranges: weeklyRanges(now: now))
    let mo = aggregateConsumption(history: hist, ranges: monthlyRanges(now: now))
    print("近24小时消耗: " + hr.map { formatNumber($0) }.joined(separator: ","))
    print("近8周消耗: " + wk.map { formatNumber($0) }.joined(separator: ","))
    print("近6月消耗: " + mo.map { formatNumber($0) }.joined(separator: ","))
    exit(0)
}

// ===================== 应用主体 =====================

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var config: AppConfig = loadConfig()
    private let intervalOptions = [5, 10, 30, 60]
    private var balance: BalanceSnapshot?
    private var lastFetchAt: Date?
    private var lastError: String?
    private var isFetching = false
    private var chartController: ChartPanelController?
    private weak var configAccessory: NSView?

    private let tagBaseURLField = 101
    private let tagStylePop = 102
    private let tagBaseURLLabel = 111
    private let tagStyleLabel = 112
    private let tagPathField = 103
    private let tagPathLabel = 113

    /// 当前数据源标识（历史记录按此区分）
    private var sourceKey: String {
        let base: String
        if let b = config.baseURL, !b.isEmpty {
            base = b
        } else {
            base = providerBaseURLs[config.provider] ?? "https://api.deepseek.com"
        }
        return "\(config.provider)|\(base)"
    }

    private var activeAPIKey: String? {
        if let k = config.apiKey, !k.isEmpty { return k }
        // 只有官方 DeepSeek 才回退使用 DSH 凭据文件中的 Key
        if config.provider == "deepseek" { return loadCredentialsAPIKey() }
        return nil
    }

    private var keySourceLabel: String {
        let providerName = providerDisplayName(config.provider)
        if config.provider == "custom" {
            let base = config.baseURL?.isEmpty == false ? config.baseURL! : "未填写"
            return "\(providerName)（\(base)）"
        }
        if config.provider != "deepseek" {
            let base = config.baseURL?.isEmpty == false ? config.baseURL! : (providerBaseURLs[config.provider] ?? "?")
            return "\(providerName)（\(base)）"
        }
        if let k = config.apiKey, !k.isEmpty { return "官方 DeepSeek（应用内 Key）" }
        if loadCredentialsAPIKey() != nil { return "官方 DeepSeek（DSH 凭据文件）" }
        return "官方 DeepSeek（未配置 Key）"
    }

    private var topUpURL: URL? {
        if config.provider != "deepseek" {
            let base = config.baseURL?.isEmpty == false ? config.baseURL!
                : (providerBaseURLs[config.provider] ?? "https://platform.deepseek.com/top_up")
            if let u = URL(string: base) { return u }
        }
        return URL(string: "https://platform.deepseek.com/top_up")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if config.provider == "custom" {
            appendLog("启动，提供方：自定义第三方（\(config.baseURL ?? "未填 Base URL")），接口风格：\(config.balanceStyle)")
        } else if let k = config.apiKey, !k.isEmpty {
            appendLog("启动，API Key：应用内配置(长度\(k.count))")
        } else if let k = loadCredentialsAPIKey() {
            appendLog("启动，API Key：DSH 凭据文件(长度\(k.count))")
        } else {
            appendLog("启动，API Key：未找到")
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "余额 …"
        statusItem.button?.toolTip = "余额（点击查看详情）"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()

        refresh()
        startTimer()
    }

    func startTimer() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: TimeInterval(config.refreshSeconds), repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        appendLog("定时器已设置：每 \(config.refreshSeconds) 秒刷新")
    }

    func intervalLabel(_ sec: Int) -> String {
        if sec < 60 { return "\(sec) 秒" }
        if sec % 3600 == 0 { return "\(sec / 3600) 小时" }
        return "\(sec / 60) 分钟"
    }

    @objc func setInterval(_ sender: NSMenuItem) {
        guard let sec = sender.representedObject as? Int, sec != config.refreshSeconds else { return }
        config.refreshSeconds = sec
        saveConfig(config)
        startTimer()
        rebuildMenu()
        refresh()
    }

    @objc func providerChanged(_ sender: NSPopUpButton) {
        guard let view = configAccessory else { return }
        let id = sender.selectedItem?.representedObject as? String ?? "deepseek"
        // 选择提供方时自动预填官方 Base URL（自定义则保留用户已填内容）
        if let preset = providerBaseURLs[id],
           let baseField = view.viewWithTag(tagBaseURLField) as? NSTextField {
            baseField.stringValue = preset
        }
    }

    @objc func styleChanged(_ sender: NSPopUpButton) {
        guard let view = configAccessory else { return }
        let isCustomPath = (sender.indexOfSelectedItem == 2)
        (view.viewWithTag(tagPathField))?.isHidden = !isCustomPath
        (view.viewWithTag(tagPathLabel))?.isHidden = !isCustomPath
    }

    @objc func configureAPIKey() {
        let alert = NSAlert()
        alert.messageText = "配置余额查询"
        alert.informativeText = "选择提供方并填写对应信息。\n多数提供方没有公开的余额接口，查询失败属正常，可切换余额接口风格或自定义路径。\nKey 仅保存在本机配置文件（权限 600），不会上传。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 234))

        // 行 1：提供方（DSH 全部提供方 + 自定义）
        let providerLabel = NSTextField(labelWithString: "API 提供方：")
        providerLabel.frame = NSRect(x: 0, y: 208, width: 110, height: 20)
        let providerPop = NSPopUpButton(frame: NSRect(x: 118, y: 204, width: 300, height: 26))
        for id in providerOptions + ["custom"] {
            let item = NSMenuItem(title: providerDisplayName(id), action: nil, keyEquivalent: "")
            item.representedObject = id
            providerPop.menu?.addItem(item)
        }
        // 定位当前 provider
        var currentProvider = config.provider
        if !providerOptions.contains(currentProvider) && currentProvider != "custom" {
            currentProvider = "custom"
        }
        if let idx = providerPop.itemArray.firstIndex(where: { ($0.representedObject as? String) == currentProvider }) {
            providerPop.selectItem(at: idx)
        } else {
            providerPop.selectItem(at: providerOptions.count) // 兜底选“自定义第三方”
        }
        providerPop.target = self
        providerPop.action = #selector(providerChanged(_:))

        // 行 2：API Key
        let keyLabel = NSTextField(labelWithString: "API Key：")
        keyLabel.frame = NSRect(x: 0, y: 170, width: 110, height: 20)
        let keyField = NSTextField(frame: NSRect(x: 118, y: 166, width: 300, height: 24))
        keyField.placeholderString = "sk-..."
        keyField.stringValue = config.apiKey ?? ""

        // 行 3：Base URL（始终可见，选择提供方自动预填）
        let baseURLLabel = NSTextField(labelWithString: "Base URL：")
        baseURLLabel.frame = NSRect(x: 0, y: 132, width: 110, height: 20)
        baseURLLabel.tag = tagBaseURLLabel
        let baseURLField = NSTextField(frame: NSRect(x: 118, y: 128, width: 300, height: 24))
        baseURLField.placeholderString = "https://api.example.com"
        if let b = config.baseURL, !b.isEmpty {
            baseURLField.stringValue = b
        } else {
            baseURLField.stringValue = providerBaseURLs[currentProvider] ?? ""
        }
        baseURLField.tag = tagBaseURLField

        // 行 4：余额接口风格
        let styleLabel = NSTextField(labelWithString: "余额接口：")
        styleLabel.frame = NSRect(x: 0, y: 94, width: 110, height: 20)
        styleLabel.tag = tagStyleLabel
        let stylePop = NSPopUpButton(frame: NSRect(x: 118, y: 90, width: 300, height: 26))
        stylePop.addItems(withTitles: [
            "DeepSeek 风格（/user/balance）",
            "OpenAI 风格（/v1/dashboard/billing/credit_grants）",
            "自定义路径…",
        ])
        let styleIndex: Int
        switch config.balanceStyle {
        case "openai": styleIndex = 1
        case "custom": styleIndex = 2
        default: styleIndex = 0
        }
        stylePop.selectItem(at: styleIndex)
        stylePop.target = self
        stylePop.action = #selector(styleChanged(_:))
        stylePop.tag = tagStylePop

        // 行 5：自定义路径（仅 style=custom 显示）
        let pathLabel = NSTextField(labelWithString: "接口路径：")
        pathLabel.frame = NSRect(x: 0, y: 56, width: 110, height: 20)
        pathLabel.tag = tagPathLabel
        let pathField = NSTextField(frame: NSRect(x: 118, y: 52, width: 300, height: 24))
        pathField.placeholderString = "/user/balance"
        pathField.stringValue = config.balancePath ?? "/user/balance"
        pathField.tag = tagPathField

        // 行 6：金额→token 换算单价（用于图表纵坐标）
        let priceLabel = NSTextField(labelWithString: "单价(元/百万t)：")
        priceLabel.frame = NSRect(x: 0, y: 18, width: 110, height: 20)
        let priceField = NSTextField(frame: NSRect(x: 118, y: 14, width: 300, height: 24))
        priceField.placeholderString = "2.5（deepseek-v4-flash 混合价，可按需调整）"
        priceField.stringValue = String(format: "%g", config.costPerMillionTokens)

        view.addSubview(providerLabel); view.addSubview(providerPop)
        view.addSubview(keyLabel); view.addSubview(keyField)
        view.addSubview(baseURLLabel); view.addSubview(baseURLField)
        view.addSubview(styleLabel); view.addSubview(stylePop)
        view.addSubview(pathLabel); view.addSubview(pathField)
        view.addSubview(priceLabel); view.addSubview(priceField)

        let isCustomPath = (config.balanceStyle == "custom")
        pathLabel.isHidden = !isCustomPath
        pathField.isHidden = !isCustomPath

        alert.accessoryView = view
        configAccessory = view
        alert.window.initialFirstResponder = keyField

        if alert.runModal() == .alertFirstButtonReturn {
            let v = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let providerID = providerPop.selectedItem?.representedObject as? String ?? "deepseek"
            let styleID: String
            switch stylePop.indexOfSelectedItem {
            case 1: styleID = "openai"
            case 2: styleID = "custom"
            default: styleID = "deepseek"
            }
            let path = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let price = Double(priceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 2.5
            config.provider = providerID
            config.baseURL = base.isEmpty ? nil : base
            config.balanceStyle = styleID
            config.balancePath = path.isEmpty ? nil : path
            config.apiKey = v.isEmpty ? nil : v
            config.costPerMillionTokens = (price > 0) ? price : 2.5
            saveConfig(config)
            appendLog("已配置：提供方=\(providerDisplayName(providerID))，Base=\(config.baseURL ?? "默认")，接口=\(styleID)，单价=\(config.costPerMillionTokens)元/百万t，Key 长度 \(v.count)")
            rebuildMenu()
            refresh()
        }
        configAccessory = nil
    }

    @objc func topUp() {
        if let url = topUpURL {
            appendLog("打开充值/提供方页面：\(url.absoluteString)")
            NSWorkspace.shared.open(url)
        }
    }

    @objc func showChart() {
        appendLog("菜单点击：消耗图表")
        if chartController == nil {
            chartController = ChartPanelController()
        }
        chartController?.history = loadHistory(sourceKey: sourceKey)
        chartController?.costPerMillionTokens = config.costPerMillionTokens
        chartController?.refreshChart()
        chartController?.show()
    }

    func refresh() {
        guard !isFetching else { return }
        guard activeAPIKey != nil else {
            if config.provider == "custom" {
                lastError = "请先在“配置 API Key…”中填写 Key 与 Base URL"
            } else if config.provider == "deepseek" {
                lastError = "未找到 DEEPSEEK_API_KEY"
            } else {
                lastError = "请在“配置 API Key…”中填写该提供方的 Key"
            }
            updateTitle()
            rebuildMenu()
            return
        }
        isFetching = true
        let key = activeAPIKey!
        fetchBalance(config: config, apiKey: key) { [weak self] result in
            guard let strongSelf = self else { return }
            DispatchQueue.main.async {
                strongSelf.isFetching = false
                switch result {
                case .success(let s):
                    let prev = strongSelf.balance?.total
                    strongSelf.balance = s
                    strongSelf.lastError = nil
                    strongSelf.lastFetchAt = Date()
                    // 记录历史（只在余额变化时落盘）
                    if let b = Double(s.total) {
                        recordHistory(sourceKey: strongSelf.sourceKey,
                                      t: Date().timeIntervalSince1970, b: b)
                    }
                    if prev != nil && prev != s.total {
                        appendLog("余额变化：\(prev!) → \(s.total)")
                    }
                case .failure(let e):
                    strongSelf.lastError = e.localizedDescription
                    appendLog("刷新失败：\(e.localizedDescription)")
                }
                strongSelf.updateTitle()
                strongSelf.rebuildMenu()
            }
        }
    }

    func updateTitle() {
        guard let btn = statusItem?.button else { return }
        if let b = balance {
            btn.title = "\(currencySymbol(b.currency))\(b.total)"
        } else if lastError != nil {
            btn.title = "余额 ?"
        } else {
            btn.title = "余额 …"
        }
    }

    func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        let header = NSMenuItem(title: "余额监控", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if let b = balance {
            let sym = currencySymbol(b.currency)
            menu.addItem(titled: "当前余额：\(sym)\(b.total)", disabled: true)
            for (label, value) in b.details {
                menu.addItem(titled: "\(label)：\(value)", disabled: true)
            }
        } else {
            menu.addItem(titled: "暂无余额数据", disabled: true)
        }

        if let t = lastFetchAt {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            menu.addItem(titled: "上次刷新：\(f.string(from: t))", disabled: true)
        }
        if let e = lastError {
            menu.addItem(titled: "提示：\(e)", disabled: true)
        }
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let chartItem = NSMenuItem(title: "消耗图表…", action: #selector(showChart), keyEquivalent: "c")
        chartItem.target = self
        menu.addItem(chartItem)

        let intervalSub = NSMenu()
        for sec in intervalOptions {
            let item = NSMenuItem(title: intervalLabel(sec),
                                  action: #selector(setInterval(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = sec
            item.state = (sec == config.refreshSeconds) ? .on : .off
            intervalSub.addItem(item)
        }
        let intervalItem = NSMenuItem(title: "刷新间隔（当前 \(intervalLabel(config.refreshSeconds))）",
                                      action: nil, keyEquivalent: "")
        intervalItem.submenu = intervalSub
        menu.addItem(intervalItem)

        menu.addItem(titled: "密钥来源：\(keySourceLabel)", disabled: true)
        let keyItem = NSMenuItem(title: "配置 API Key…", action: #selector(configureAPIKey), keyEquivalent: "k")
        keyItem.target = self
        menu.addItem(keyItem)

        let topUpItem = NSMenuItem(title: (config.provider == "custom") ? "打开提供方页面…" : "充值…",
                                   action: #selector(topUp), keyEquivalent: "")
        topUpItem.target = self
        menu.addItem(topUpItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    @objc func refreshClicked() { refresh() }

    @objc func quitApp() {
        appendLog("退出")
        NSApp.terminate(nil)
    }
}

extension NSMenu {
    func addItem(titled title: String, disabled: Bool) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = !disabled
        addItem(item)
    }
}

// ===================== 入口 =====================

@main
struct DSHBalanceMain {
    static func main() {
        if CommandLine.arguments.contains("--check") {
            runCheck()
        }
        if CommandLine.arguments.contains("--check-chart") {
            runCheckChart()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
