import Foundation

/// 本机路径与端口。App 只读这些东西，不改服务配置。
///
/// 账号不再在本地登记：店铺列表直接来源于后台 `/cookies/details` 返回的账号，
/// 数量与名称都跟着后台走（见 `Store.accounts` / `Store.displayName`）。
/// 这样换号、加号都不用改代码，也不用在这里填任何 ID。
enum Cfg {

    private static let d = UserDefaults.standard

    static var root: URL {
        get {
            if let s = d.string(forKey: "root"), !s.isEmpty {
                return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
            }
            return URL(fileURLWithPath: ("~/Documents/xianyu" as NSString).expandingTildeInPath)
        }
        set { d.set(newValue.path, forKey: "root") }
    }

    static var server: URL { root.appendingPathComponent("xianyu-server") }
    static var db: URL { server.appendingPathComponent("data/xianyu_data.db") }
    static var env: URL { server.appendingPathComponent(".env") }
    static var logs: URL { server.appendingPathComponent("logs") }

    static var supervisor: URL {
        URL(fileURLWithPath: ("~/Library/Application Support/xianyu/xianyu-supervise.sh" as NSString).expandingTildeInPath)
    }
    static var guardScript: URL { root.appendingPathComponent("scripts/xianyu_guard.sh") }

    static var port: Int {
        get { let v = d.integer(forKey: "port"); return v == 0 ? 8090 : v }
        set { d.set(newValue, forKey: "port") }
    }

    static var base: String { "http://127.0.0.1:\(port)" }

    /// 管理员密码只从 .env 读，别在别处再存一份。
    static func password() -> String? {
        guard let text = try? String(contentsOf: env, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("ADMIN_PASSWORD=") else { continue }
            var v = String(s.dropFirst("ADMIN_PASSWORD=".count)).trimmingCharacters(in: .whitespaces)
            if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            return v.isEmpty ? nil : v
        }
        return nil
    }
}
