import SwiftUI

extension Widget {
    /// 設定の色名から実際の色へ。
    var tintColor: Color {
        switch tint {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "gray": return .gray
        default: return .accentColor
        }
    }
}

/// ウィジェットの見た目（帯のタイルと、設定の選択肢のプレビューで共通）。
/// 見え方・値・色・大きさを受け取って描くだけ。状態は持たない。
struct WidgetFaceView: View {
    let face: WidgetFace
    let big: String
    /// 0...1 の割合（数値でなければ nil）。
    let fraction: Double?
    let symbol: String
    let tint: Color
    let size: CGFloat
    /// グラフの点（0...100）。
    let history: [Double]

    var body: some View {
        switch face {
        case .ring: ring
        case .text: squareText
        case .wideText: wideText
        case .wideBar: wideBar
        case .wideChart: wideChart
        case .tallText: tallText
        case .tallBar: tallBar
        }
    }

    // MARK: - 縦長（左右に置くとき。高さは WidgetSizing が内容から決める）

    /// 縦長・文字：記号の下に、行を分けた文字を積む（時刻は「時:分」と「:秒」）。
    private var tallText: some View {
        VStack(spacing: 1) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.22))
                .foregroundStyle(tint)
            ForEach(Array(TallText.lines(big).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: size * 0.26, weight: .semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 6)
    }

    /// 縦長・文字＋縦のバー（下から伸びる）。
    private var tallBar: some View {
        VStack(spacing: 4) {
            Text(big)
                .font(.system(size: size * 0.22, weight: .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color.primary.opacity(0.15))
                    Capsule().fill(tint).frame(height: geo.size.height * CGFloat(max(0.02, min(1, fraction ?? 0))))
                }
            }
            .frame(width: max(6, size * 0.16))
            Image(systemName: symbol).font(.system(size: size * 0.16)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    // MARK: - 正方形

    @ViewBuilder
    private var ring: some View {
        if let value = fraction {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.15), lineWidth: ringWidth)
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, value)))
                    .stroke(tint, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(big)
                    .font(.system(size: size * 0.26, weight: .semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
            .frame(width: size - 10, height: size - 10)
        } else {
            squareText
        }
    }

    private var squareText: some View {
        VStack(spacing: 2) {
            Text(big)
                .font(.system(size: size * 0.22, weight: .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Image(systemName: symbol)
                .font(.system(size: size * 0.16))
                .foregroundStyle(.secondary)
        }
        .padding(4)
    }

    // MARK: - 横長（幅は WidgetSizing が内容から決める）

    /// 横長・文字：記号＋大きな文字を 1 行で。時刻が切れない。
    private var wideText: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.24))
                .foregroundStyle(tint)
            Text(big)
                .font(.system(size: size * 0.30, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
    }

    /// 横長・文字＋バー。
    private var wideBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: size * 0.18)).foregroundStyle(.secondary)
                Text(big)
                    .font(.system(size: size * 0.28, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.15))
                    Capsule().fill(tint).frame(width: geo.size.width * CGFloat(max(0.02, min(1, fraction ?? 0))))
                }
            }
            .frame(height: max(4, size * 0.10))
        }
        .padding(.horizontal, 10)
    }

    /// 横長・文字＋推移のグラフ（面＋線）。
    private var wideChart: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(big)
                    .font(.system(size: size * 0.30, weight: .semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Image(systemName: symbol).font(.system(size: size * 0.15)).foregroundStyle(.secondary)
            }
            .frame(width: size * 0.9, alignment: .leading)
            chart.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var chart: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let step = history.count > 1 ? w / CGFloat(history.count - 1) : w
            let y: (Double) -> CGFloat = { h - h * CGFloat(min(100, max(0, $0)) / 100) }
            ZStack {
                ForEach([0.25, 0.5, 0.75], id: \.self) { level in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: h * (1 - level)))
                        path.addLine(to: CGPoint(x: w, y: h * (1 - level)))
                    }
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
                if history.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: h))
                        for (index, value) in history.enumerated() {
                            path.addLine(to: CGPoint(x: CGFloat(index) * step, y: y(value)))
                        }
                        path.addLine(to: CGPoint(x: w, y: h))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                    Path { path in
                        for (index, value) in history.enumerated() {
                            let point = CGPoint(x: CGFloat(index) * step, y: y(value))
                            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                } else {
                    Text("データを集めています…").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var ringWidth: CGFloat { max(3, size * 0.08) }
}

/// 設定の見え方の選択肢。各選択肢を、帯と同じ部品で描いたプレビュー付きで並べる。
struct WidgetFacePicker: View {
    @Binding var widget: Widget
    let big: String
    let fraction: Double?
    let tint: Color
    let history: [Double]
    /// 左右に置くときの見え方を選ぶ（下置きとは別に保存する）。
    var vertical = false

    private let previewIcon: CGFloat = 46

    var body: some View {
        let faces = vertical ? widget.kind.sideFaces : widget.kind.availableFaces
        // 下置きは横長なので 1 列、左右は縦長なので横に並べる（どちらも重ならない）。
        let columns = vertical ? [GridItem(.adaptive(minimum: 96), spacing: 8)] : [GridItem(.flexible())]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(faces) { face in
                let selected = widget.look(vertical: vertical) == face
                let tile = WidgetSizing.size(face: face, sample: widget.sampleText, icon: previewIcon)
                Button {
                    if vertical { widget.sideFace = face } else { widget.face = face }
                } label: {
                    VStack(spacing: 6) {
                        WidgetFaceView(
                            face: face, big: big, fraction: fraction, symbol: widget.symbol, tint: tint,
                            size: previewIcon, history: history.count > 1 ? history : WidgetFacePicker.demoHistory)
                            .frame(width: tile.width, height: tile.height)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.10)))
                            .frame(height: vertical ? previewIcon * 2 + 4 : previewIcon + 4)
                        Text(face.title).font(.caption)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// まだ点が無いときのプレビュー用の推移。
    static let demoHistory: [Double] = [22, 35, 30, 48, 41, 60, 52, 66, 58, 72]
}
