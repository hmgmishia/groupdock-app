import Foundation

/// アプリのバージョン表示と、ビルド番号の計算（純粋関数）。
/// ビルドのたびに `build.sh` が `BUILD_NUMBER` を 1 つ上げ、`VERSION`（例 0.2）と合わせて
/// Info.plist の `CFBundleShortVersionString`（0.2.37）と `CFBundleVersion`（37）へ書く。設定の「一般」に出す。
enum AppVersion {
    /// 画面に出す文。バージョン情報が無い（開発中の実行ファイルなど）ときは、開発版。
    static func text(short: String?, build: String?) -> String {
        let short = clean(short), build = clean(build)
        switch (short, build) {
        case let (short?, build?): return "バージョン \(short)（ビルド \(build)）"
        case let (short?, nil): return "バージョン \(short)"
        case let (nil, build?): return "開発版（ビルド \(build)）"
        case (nil, nil): return "開発版（バージョン情報なし）"
        }
    }

    /// 次のビルド番号。空・壊れた値のときは 1 から。
    static func nextBuild(current: String) -> Int {
        guard let value = Int(current.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 else { return 1 }
        return value + 1
    }

    /// `VERSION` とビルド番号をつなぐ（0.2 と 37 → 0.2.37）。
    static func shortVersion(version: String, build: Int) -> String { "\(version).\(build)" }

    /// 実行中のアプリのバージョン文。
    static var current: String {
        let info = Bundle.main.infoDictionary
        return text(short: info?["CFBundleShortVersionString"] as? String, build: info?["CFBundleVersion"] as? String)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
