import AppKit
import SwiftUI

/// クリップボード履歴のポップアップ。一覧からクリックでコピーし直し、固定・削除・一時停止・すべて消すができる。
struct ClipboardPopup: View {
    @Bindable var clipboard: ClipboardStore
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("コピーした履歴（\(clipboard.entries.count) 件）").font(.headline)
                Spacer()
                Toggle("一時停止", isOn: $clipboard.paused)
                    .toggleStyle(.checkbox)
                    .help("オンの間は、新しくコピーしたものを記録しません")
            }
            .font(.caption)

            if clipboard.entries.isEmpty {
                Text(clipboard.paused ? "一時停止中です。" : "まだありません。何かをコピーすると、ここに溜まります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(clipboard.entries) { entry in
                            ClipboardRow(clipboard: clipboard, entry: entry, onCopied: onClose)
                        }
                    }
                }
                .frame(height: min(320, CGFloat(clipboard.entries.count) * 46 + 8))
            }

            HStack {
                Text("パスワード管理アプリなどが「機密」と印を付けた内容は記録しません。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("消す") { clipboard.clear(keepPinned: true) }
                    .disabled(clipboard.entries.allSatisfy(\.pinned))
                    .help("固定していないものをすべて消します")
            }
            .font(.caption)
        }
        .padding(12)
        .frame(width: 340)
    }
}

/// 履歴の 1 行。押すとクリップボードへ入れ直す。右の印で固定、×で削除。
struct ClipboardRow: View {
    var clipboard: ClipboardStore
    let entry: ClipEntry
    var onCopied: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            thumb
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.callout).lineLimit(1)
                Text(Self.relative(entry.date)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { clipboard.togglePin(entry.id) } label: {
                Image(systemName: entry.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(entry.pinned ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(entry.pinned ? "固定を外す" : "固定する（上限で消えません）")
            if entry.kind == .image {
                Button { saveImage() } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("画像をファイルに保存…")
            }
            Button { clipboard.remove(entry.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("履歴から消す")
        }
        .padding(.horizontal, 6)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            clipboard.copyBack(entry)
            onCopied()
        }
        .help(entry.kind == .text ? String(entry.text.prefix(400)) : entry.title)
    }

    /// 保存パネルで場所を選び、元画像を復号して書き出す。ポップアップを閉じてから出す（ポップアップの外のクリックで閉じるため）。
    private func saveImage() {
        let store = clipboard
        let target = entry
        onCopied()
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = ClipboardExport.suggestedName(date: target.date)
            panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            panel.canCreateDirectories = true
            panel.prompt = "保存"
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            if !store.exportImage(target, to: url) {
                let alert = NSAlert()
                alert.messageText = "画像を保存できませんでした"
                alert.informativeText = "元の画像を読み出せないか、保存先に書き込めません。"
                alert.runModal()
            }
        }
    }

    @ViewBuilder
    private var thumb: some View {
        ZStack {
            switch entry.kind {
            case .image:
                if let image = clipboard.thumbnail(for: entry) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            case .files:
                Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
            case .text:
                Image(systemName: "text.alignleft").foregroundStyle(.secondary)
            }
        }
        .frame(width: 32, height: 32)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private static func relative(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "いま" }
        if seconds < 3600 { return "\(seconds / 60) 分前" }
        if seconds < 86400 { return "\(seconds / 3600) 時間前" }
        return "\(seconds / 86400) 日前"
    }
}
