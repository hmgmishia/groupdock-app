import AppKit
import SwiftUI

/// サムネ。画像が無いときは音符を出す。
struct NowPlayingThumb: View {
    let info: PlaybackInfo?
    let side: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.10))
            if let data = info?.artwork, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.4))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// 帯に置く「再生中」の見た目。表示パターンごとに中身を出し分ける。
struct NowPlayingFace: View {
    @ObservedObject var state: NowPlayingState
    let layout: PlayerLayout
    let size: CGFloat
    var tint: Color = .accentColor
    /// 左右に置くとき（縦に積む）。
    var vertical = false
    let control: (PlaybackAction) -> Void
    let seek: (Double) -> Void

    var body: some View {
        faceBody
            .tint(tint)
            .foregroundStyle(tint)
    }

    @ViewBuilder
    private var faceBody: some View {
        if vertical { verticalBody } else { horizontalBody }
    }

    /// 左右に置くとき：幅はアイコン 1 つ分。サムネ・曲名・操作・位置を上から積む。
    @ViewBuilder
    private var verticalBody: some View {
        let info = state.info
        switch layout {
        case .thumbnail:
            NowPlayingThumb(info: info, side: size - 8)
        case .thumbnailPlay:
            VStack(spacing: 4) {
                NowPlayingThumb(info: info, side: size - 8)
                playButton(info, font: size * 0.3)
            }
        case .transport:
            VStack(spacing: 2) { transport(info, font: size * 0.28) }
        case .full:
            VStack(spacing: 3) {
                NowPlayingThumb(info: info, side: size - 12)
                Text(info?.title ?? "再生していません")
                    .font(.system(size: 8, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                HStack(spacing: 0) { transport(info, font: 8) }
                if let info {
                    PlaybackSeekBar(info: info, seek: seek, compact: true)
                } else {
                    Slider(value: .constant(0), in: 0...1).controlSize(.mini)
                        .playbackEnabled(false, reason: "再生していません")
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .frame(maxWidth: size)
            .clipped()
        }
    }

    @ViewBuilder
    private var horizontalBody: some View {
        let info = state.info
        let side = size - 8
        switch layout {
        case .thumbnail:
            NowPlayingThumb(info: info, side: side)
        case .thumbnailPlay:
            HStack(spacing: 4) {
                NowPlayingThumb(info: info, side: side)
                playButton(info, font: size * 0.34)
            }
        case .transport:
            HStack(spacing: 2) { transport(info, font: size * 0.3) }
        case .full:
            // 帯の高さ（size）に収める：サムネは高さいっぱい、右は 曲名・操作・音量 を詰めて縦に並べる。
            HStack(spacing: 5) {
                NowPlayingThumb(info: info, side: size - 10)
                VStack(alignment: .leading, spacing: 0) {
                    Text(info?.title ?? "再生していません")
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 0) { transport(info, font: 10) }
                    // 帯のバーは再生位置（いまの位置を反映し、離したらその位置へ移動する）。音量はポップアップで変える。
                    if let info {
                        PlaybackSeekBar(info: info, seek: seek, compact: true)
                    } else {
                        Slider(value: .constant(0), in: 0...1).controlSize(.mini)
                            .playbackEnabled(false, reason: "再生していません")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .frame(maxHeight: size)
            .clipped()
        }
    }

    private func caps(_ info: PlaybackInfo?) -> PlaybackCapabilities { info?.capabilities ?? .none }

    private func playButton(_ info: PlaybackInfo?, font: CGFloat) -> some View {
        Button { control(.toggle) } label: {
            Image(systemName: info?.playing == true ? "pause.fill" : "play.fill")
                .font(.system(size: font))
                .frame(width: font + 8, height: font + 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .playbackEnabled(caps(info).toggle, reason: info == nil ? "再生していません" : "この再生元は再生/停止できません")
        .help(info?.playing == true ? "一時停止" : "再生")
    }

    @ViewBuilder
    private func transport(_ info: PlaybackInfo?, font: CGFloat) -> some View {
        Button { control(.previous) } label: {
            Image(systemName: "backward.fill").font(.system(size: font * 0.8))
                .frame(width: font + 6, height: font + 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .playbackEnabled(caps(info).previous, reason: PlaybackReason.previous(info))
        .help("前へ")
        playButton(info, font: font)
        Button { control(.next) } label: {
            Image(systemName: "forward.fill").font(.system(size: font * 0.8))
                .frame(width: font + 6, height: font + 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .playbackEnabled(caps(info).next, reason: PlaybackReason.next(info))
        .help("次へ")
    }
}

/// ポップアップ：サムネ・曲名・操作・音量（対象サービスの音量）。
struct NowPlayingPopup: View {
    @ObservedObject var state: NowPlayingState
    let store: Store

    @State private var volume = 0.0
    @State private var editingVolume = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let info = state.info {
                HStack(spacing: 10) {
                    NowPlayingThumb(info: info, side: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.title).font(.headline).lineLimit(2)
                        if !info.artist.isEmpty {
                            Text(info.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(info.source.title).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                PlaybackSeekBar(info: info, seek: { store.seekPlayback(to: $0) })
                HStack(spacing: 22) {
                    Button { store.playback(.previous) } label: { Image(systemName: "backward.fill") }
                        .playbackEnabled(info.capabilities.previous, reason: PlaybackReason.previous(info))
                    Button { store.playback(.toggle) } label: {
                        Image(systemName: info.playing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 30))
                    }
                    .playbackEnabled(info.capabilities.toggle, reason: "この再生元は再生/停止できません")
                    Button { store.playback(.next) } label: { Image(systemName: "forward.fill") }
                        .playbackEnabled(info.capabilities.next, reason: PlaybackReason.next(info))
                }
                .buttonStyle(.plain)
                .font(.system(size: 16))
                .frame(maxWidth: .infinity)
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").font(.caption)
                    Slider(value: $volume, in: 0...100, step: 1) { editing in
                        editingVolume = editing
                        if !editing { store.setPlaybackVolume(Int(volume)) }
                    }
                    Text(info.capabilities.volume ? "\(Int(volume))%" : "—")
                        .monospacedDigit().font(.caption).frame(width: 36, alignment: .trailing)
                }
                .playbackEnabled(info.capabilities.volume, reason: PlaybackReason.volume(info))
                Text(info.capabilities.volume
                     ? "音量は \(info.source.title) 自身の音量です"
                     : PlaybackReason.volume(info))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("再生していません").foregroundStyle(.secondary)
            }
            if let hint = state.hint {
                Text(hint).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minWidth: 240, idealWidth: 290, maxWidth: 380)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { volume = Double(state.info?.volume ?? 0) }
        .onChange(of: state.info?.volume) { _, new in
            if let new, !editingVolume { volume = Double(new) }
        }
    }
}

/// 操作できない理由（灰色の要素にホバーで出す）。
enum PlaybackReason {
    static func next(_ info: PlaybackInfo?) -> String {
        guard let info else { return "再生していません" }
        return info.source.isBrowser ? "このページには「次へ」がありません（YouTube の再生リストなどで使えます）" : "この再生元は次へ進めません"
    }

    static func previous(_ info: PlaybackInfo?) -> String {
        info == nil ? "再生していません" : "この再生元は前へ戻れません"
    }

    static func volume(_ info: PlaybackInfo?) -> String {
        guard let info else { return "再生していません" }
        return info.source == .system
            ? "システムの再生は、同じ曲を再生中のブラウザ（Chrome・Safari）が見つかったときだけ音量を変えられます。ブラウザの「Apple Events からの JavaScript を許可」をオンにしてください（全体の音量は音量ウィジェット）"
            : "この再生元の音量は読めません"
    }

    static func seek(_ info: PlaybackInfo?) -> String {
        guard let info else { return "再生していません" }
        return info.duration == nil ? "長さが分からない再生（ライブ配信など）は位置を動かせません" : "この再生元は位置を動かせません"
    }
}

extension View {
    /// 操作できないときは灰色にして押せなくし、ホバーで理由を出す。
    @ViewBuilder
    func playbackEnabled(_ enabled: Bool, reason: String) -> some View {
        if enabled {
            self
        } else {
            self.disabled(true).opacity(0.35).help(reason)
        }
    }
}

/// 再生位置のバー。つまみを動かしている間は表示だけ動かし、離したときに位置を送る。
struct PlaybackSeekBar: View {
    let info: PlaybackInfo
    let seek: (Double) -> Void
    /// 帯用：時刻の文字を出さず、小さく描く。
    var compact = false
    @State private var dragValue: Double?

    var body: some View {
        let duration = info.duration ?? 1
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let current = dragValue ?? info.currentPosition(at: context.date) ?? 0
            VStack(spacing: 2) {
                Slider(
                    value: Binding(get: { current }, set: { dragValue = $0 }),
                    in: 0...max(1, duration)
                ) { editing in
                    if !editing, let value = dragValue {
                        seek(value)
                        dragValue = nil
                    }
                }
                .controlSize(compact ? .mini : .small)
                if !compact {
                    HStack {
                        Text(info.duration == nil ? "—" : PlaybackInfo.clock(current))
                        Spacer()
                        Text(info.duration.map(PlaybackInfo.clock) ?? "—")
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
        .playbackEnabled(info.capabilities.seek, reason: PlaybackReason.seek(info))
    }
}
