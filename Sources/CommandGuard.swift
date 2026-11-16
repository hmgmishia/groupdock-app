import Foundation

/// ウィジェットのコマンドを検閲する層。
///
/// シェル（`sh` / `bash`）を一切通さず、**許可した実行ファイルだけ**を引数つきで直接起動する。
/// `curl` や `sh -c` のような「何でもできる」入口を塞ぐのが目的。
/// パイプ・リダイレクト・コマンド置換（`$( )` やバッククォート）も文字として拒否する。
enum CommandGuard {
    /// 実行を許すプログラム（絶対パス）。
    /// 追加するときは「引数だけで完結し、任意のコードを走らせられないもの」に限る。
    static let allowed: [String: String] = [
        "echo": "/bin/echo",
        "date": "/bin/date",
        "uptime": "/usr/bin/uptime",
        "df": "/bin/df",
        "ps": "/bin/ps",
        "vm_stat": "/usr/bin/vm_stat",
        "sysctl": "/usr/sbin/sysctl",
        "pmset": "/usr/bin/pmset",
        "cat": "/bin/cat",
    ]

    enum Failure: Error, CustomStringConvertible {
        case empty
        case notAllowed(String)
        case shellSyntax(String)
        case badArgument(String)

        var description: String {
            switch self {
            case .empty: return "コマンドが空です"
            case .notAllowed(let name):
                return "「\(name)」は許可されていません（許可: \(CommandGuard.allowed.keys.sorted().joined(separator: ", "))）"
            case .shellSyntax(let token):
                return "シェルの記号「\(token)」は使えません。プログラムと引数だけを書いてください"
            case .badArgument(let token):
                return "使えない引数です: \(token)"
            }
        }
    }

    struct Parsed {
        let executable: URL
        let arguments: [String]
    }

    /// シェルとして解釈される記号。1 つでも含まれていたら拒否する。
    private static let forbiddenTokens = [
        "|", "||", "&&", ";", "&", ">", ">>", "<", "<<",
        "$(", "`", "$", "!", "#", "~", "*", "?", "[", "]", "{", "}", "\\",
    ]

    /// コマンド文字列を検閲し、実行できる形にする。
    /// `{id}` は**そのトークンの中だけ**で展開する（シェルを経由しないので引用は不要）。
    static func parse(
        _ command: String,
        definition: WidgetDefinition?,
        values: [String: String]
    ) throws -> Parsed {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.empty }

        let tokens = try tokenize(trimmed)

        // プレースホルダ（{id}）を展開してから記号を検査する。
        // 展開後の値に `$(` などが入っていたら、その時点で拒否する。
        let expanded = tokens.map { expand($0, definition: definition, values: values) }
        guard let head = expanded.first else { throw Failure.empty }

        for token in expanded {
            if forbiddenTokens.contains(where: { token.contains($0) }) {
                throw Failure.shellSyntax(token)
            }
        }

        let name = (head as NSString).lastPathComponent
        guard let path = allowed[name] else { throw Failure.notAllowed(name) }

        var arguments: [String] = []
        for token in expanded.dropFirst() {
            arguments.append(try checkArgument(token, definition: definition))
        }
        return Parsed(executable: URL(fileURLWithPath: path), arguments: arguments)
    }

    /// 空白区切り（シングル/ダブルクォート可）。
    static func tokenize(_ command: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for character in command {
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == " " || character == "\t" {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        guard quote == nil else { throw Failure.shellSyntax("閉じていない引用符") }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// 1 トークン中の `{bundle}` `{id}` を生の値で置き換える（シェル無しなので安全）。
    static func expand(_ token: String, definition: WidgetDefinition?, values: [String: String]) -> String {
        guard let definition else { return token }
        var result = token
        if let bundle = definition.bundlePath {
            result = result.replacingOccurrences(of: "{bundle}", with: bundle)
        }
        for parameter in definition.parameters {
            let raw = values[parameter.id] ?? parameter.defaultValue
            result = result.replacingOccurrences(of: "{\(parameter.id)}", with: WidgetLibrary.sanitize(raw))
        }
        return result
    }

    /// 引数として危険なもの（別のコマンドを起動させる指定）を弾く。
    static func checkArgument(_ argument: String, definition: WidgetDefinition?) throws -> String {
        guard !argument.contains("\n"), !argument.contains("\0") else {
            throw Failure.badArgument("改行")
        }
        if argument.hasPrefix("-") {
            // `ps -o command=...` のような書式指定は許可しつつ、
            // 外部ファイルを実行させる類の指定は拒否する。
            let banned = ["--exec", "-exec", "--file", "-f", "--rcfile", "--init-file"]
            if banned.contains(where: { argument == $0 || argument.hasPrefix($0 + "=") }) {
                throw Failure.badArgument(argument)
            }
        }
        // cat はバンドル内のファイルだけ読ませる（任意のファイルを表示させない）。
        if definition?.bundlePath != nil, argument.hasPrefix("/"),
           let bundle = definition?.bundlePath, !argument.hasPrefix(bundle) {
            throw Failure.badArgument(argument)
        }
        return argument
    }
}
