import SwiftUI

/// グループ名の表示と直接編集。ダブルクリックで入力欄になり、Return か、ほかへ移ると確定する（規則は `GroupName`）。
/// 開くたびに入力欄が先頭の入力欄になって全文選択される処理が重いので、普段は文字で出し、編集するときだけ入力欄にする。
struct EditableGroupName: View {
    @Binding var name: String
    let font: Font
    /// 文字の幅。nil なら広がるだけ広がる。
    var width: CGFloat?
    var alignment: Alignment = .leading
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField("グループ名", text: $draft)
                .textFieldStyle(.plain)
                .font(font)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
                .frame(width: width, alignment: alignment)
                .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
                .focused($focused)
                .onSubmit { finish() }
                .onChange(of: focused) { _, isFocused in if !isFocused { finish() } }
                .onAppear { focused = true }
        } else {
            Text(name)
                .font(font)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: width, alignment: alignment)
                .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    draft = name
                    editing = true
                }
                .help("ダブルクリックで名前を変える")
        }
    }

    private func finish() {
        guard editing else { return }
        editing = false
        let next = GroupName.commit(draft, previous: name)
        if next != name { name = next }
    }
}
