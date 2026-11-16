import AppKit

/// 帯・吹き出しの右クリックメニューの組み立て（`DockWindowController` から分けた）。
/// 項目の中身は純粋関数（`StripMenuSpec`・`FinderOpen`・`TrashMenuSpec`）で決め、ここは `NSMenu` に並べて、押したときの処理を付けるだけ。
extension DockWindowController {
    /// 右クリック位置にあるアプリのメニュー。帯と吹き出しのどちらでも、同じ計算済みの枠で当てる。
    func buildMenu(at point: NSPoint) -> NSMenu? {
        _ = point
        if let ref = appUnderMouse() { return appMenu(for: ref) }
        return stripMenu()
    }

    /// 右クリックの対象。アプリなら .app、仕切り線・空きなら .strip。他のタイル（ウィジェット・グループ・ボタン）は SwiftUI 側のメニューに任せる。
    enum RightClickKind { case app, strip }

    func rightClickKind() -> RightClickKind? {
        if appUnderMouse() != nil { return .app }
        let mouse = NSEvent.mouseLocation
        guard panel.frame.contains(mouse) else { return nil }
        guard let id = tileID(atScreenPoint: mouse) else { return .strip }       // 空き
        return id.hasPrefix("sep:") ? .strip : nil                              // 仕切り線
    }

    /// 仕切り線・空きの右クリックメニュー。ウィジェットの追加から、プレビューと取り込みのある窓を開く。
    func stripMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // 窓の中に、各ウィジェットのプレビューと外部ウィジェットの取り込みがある（1 か所で足せる）。
        add(menu, title: StripMenuSpec.addItem().title, action: MenuAction { [weak self] in self?.openGallery() })
        menu.addItem(.separator())

        // 設定画面を開かずに切り替えられるもの（自動で隠す・表示する場所）。
        let prefs = store.prefs
        addChecked(menu, StripMenuSpec.autoHideItem(autoHide: prefs.autoHide))
        let placeMenu = NSMenu()
        placeMenu.autoenablesItems = false
        for item in StripMenuSpec.placeItems(position: prefs.position) { addChecked(placeMenu, item) }
        let holder = NSMenuItem(title: "表示する場所", action: nil, keyEquivalent: "")
        holder.submenu = placeMenu
        menu.addItem(holder)
        return menu
    }

    /// チェック付きの項目。押すと、設定を変える（設定画面と同じ値なので、画面側にも反映される）。
    func addChecked(_ menu: NSMenu, _ spec: StripMenuSpec.Item) {
        add(menu, title: spec.title, action: MenuAction { [weak self] in
            guard let self else { return }
            let next = StripMenuSpec.apply(spec.action, autoHide: self.store.prefs.autoHide, position: self.store.prefs.position)
            if next.autoHide != self.store.prefs.autoHide { self.store.prefs.autoHide = next.autoHide }
            if next.position != self.store.prefs.position { self.store.prefs.position = next.position }
        })
        menu.items.last?.state = spec.checked ? .on : .off
    }

    /// カーソルの下のアプリ（帯・吹き出し）。軽い判定なので押した瞬間に使える。
    func appUnderMouse() -> AppRef? {
        guard let id = tileID(atScreenPoint: NSEvent.mouseLocation), id.hasPrefix("app:") else { return nil }
        return store.appRef(id: String(id.dropFirst(4))) ?? pinnedRef(id: String(id.dropFirst(4)))
    }

    /// 固定アプリ（Finder・Apps）は一覧に無いので、id から作る。
    func pinnedRef(id: String) -> AppRef? {
        AppRef.pinnedPaths.contains(id) ? AppRef(path: id) : nil
    }

    func appMenu(for ref: AppRef) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        add(menu, title: "Finder で開く（\(ref.name)の場所）", action: MenuAction {
            // アプリの束そのものを Finder で選んだ状態にする。
            Launcher.revealInFinder(ref)
        })
        if ref.bundleID == "com.apple.finder" {
            // Finder：開いているウィンドウを使うか、毎回新しいウィンドウを開くか（チェックはいまの選択）。
            for item in FinderOpen.menuItems(newWindow: store.prefs.finderNewWindow) {
                add(menu, title: item.title, action: MenuAction { [weak self] in
                    self?.store.prefs.finderNewWindow = item.newWindow
                })
                menu.items.last?.state = item.checked ? .on : .off
            }
            menu.addItem(.separator())
        }
        add(menu, title: "パス: \(ref.path)（クリックでコピー）", action: MenuAction {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ref.path, forType: .string)
        })

        let args = ref.arguments.isEmpty ? "なし" : ref.arguments
        add(menu, title: "引数: \(args)", action: MenuAction {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ref.arguments, forType: .string)
        })

        if Launcher.isRunning(ref) {
            add(menu, title: "起動中のコマンドラインを見る…", action: MenuAction {
                if let command = Launcher.commandLine(ref) {
                    AppDialogs.showCommandLine(ref, command: command)
                }
            })
        }
        add(menu, title: "引数を指定して起動…", action: MenuAction {
            AppDialogs.askArguments(current: ref.arguments, title: ref.name) { args in
                Launcher.open(AppRef(path: ref.path, arguments: args, keepWhenQuit: ref.keepWhenQuit))
            }
        })
        add(menu, title: "引数を変えて複製…", action: MenuAction { [weak self] in
            AppDialogs.askArguments(current: ref.arguments, title: ref.name) { args in
                self?.store.duplicate(ref, arguments: args)
            }
        })

        menu.addItem(.separator())
        // 帯のアプリ（固定・残す・実行中）の項目。名前は「バーに残す」「終了」に揃える。
        if Launcher.isRunning(ref) {
            add(menu, title: "再起動", action: MenuAction { Launcher.restart(ref) })
            if store.hungPaths.contains(ref.path) {
                add(menu, title: "強制終了", action: MenuAction { Launcher.forceQuit(ref) })
            } else {
                add(menu, title: "終了", action: MenuAction { Launcher.quit(ref) })
            }
        }
        if !ref.isPinned {
            if store.isKept(ref.path) {
                add(menu, title: "バーから外す", action: MenuAction { [weak self] in
                    self?.store.removeEverywhere(id: ref.id)
                })
            } else {
                add(menu, title: "バーに残す", action: MenuAction { [weak self] in
                    self?.store.keepOnStrip(ref.path)
                })
            }
        }

        // アプリ自身が定義したメニュー（新規ウィンドウ・最近使った項目・オプションなど）を、区切り線の下にそのまま並べる。
        let appItems = DockMenu.menuItems(DockMenu.read(path: ref.path)) { titles in
            DispatchQueue.global(qos: .userInitiated).async { DockMenu.perform(path: ref.path, titles: titles) }
        }
        if !appItems.isEmpty {
            menu.addItem(.separator())
            appItems.forEach(menu.addItem)
        }
        return menu
    }

    func add(_ menu: NSMenu, title: String, action: MenuAction) {
        let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        menu.addItem(item)
    }

    @objc func runMenuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }
}
