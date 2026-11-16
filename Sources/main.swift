import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = Store()
    private var settings: SettingsWindowController!
    private var picker: AppPickerWindowController!
    private var widgetSettings: WidgetSettingsWindowController!
    private var gallery: WidgetGalleryWindowController!
    private var groupSettings: GroupSettingsWindowController!
    /// 画面ごとの帯（メイン画面＋「全ディスプレイ」のときの他の画面）。
    private var docks: [DockWindowController] = []
    private var primaryDock: DockWindowController!
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private var lastHideSystemDock: Bool?
    private let watchdog = Watchdog()

    func applicationDidFinishLaunching(_ notification: Notification) {
        gallery = WidgetGalleryWindowController(store: store)
        settings = SettingsWindowController(
            store: store,
            openPicker: { [weak self] in self?.picker.show() },
            openGallery: { [weak self] in self?.gallery.show() }
        )
        picker = AppPickerWindowController(store: store)
        widgetSettings = WidgetSettingsWindowController(store: store)
        groupSettings = GroupSettingsWindowController(store: store)
        NotificationCenter.default.addObserver(forName: .groupDockOpenGroupSettings, object: nil, queue: .main) { [weak self] note in
            guard let id = note.object as? UUID else { return }
            self?.groupSettings.show(groupID: id)
        }
        rebuildDocks()

        // ポップアップは、外をクリックしたら閉じる（中のクリックでは閉じない）。
        let dismiss: (NSWindow?) -> Void = { window in
            let name = window.map { String(describing: type(of: $0)) }
            guard PopoverDismissal.shouldDismiss(clickedWindowClass: name) else { return }
            NotificationCenter.default.post(name: .groupDockDismissPopovers, object: nil)
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in dismiss(nil) }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            dismiss(event.window)
            return event
        }

        // 固まったら標準 Dock を自動で戻す（強制終了の一覧に出ないアプリなので保険）。
        watchdog.start()

        LoginItem.enableByDefaultOnce()
        applySystemDockWhenChanged(store.prefs.hideSystemDock, force: false)
        watchApplicationLaunches()

        // 「全ディスプレイ」が変わったら、ディスプレイの抜き差しでも作り直す。
        store.$prefs
            .map(\.allDisplays)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildDocks() }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildDocks()
        }

        // 設定が変わったら Dock の表示にも反映する。
        store.$prefs
            .receive(on: RunLoop.main)
            .sink { [weak self] prefs in
                self?.applySystemDockWhenChanged(prefs.hideSystemDock, force: false)
            }
            .store(in: &cancellables)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "square.grid.2x2",
            accessibilityDescription: "GroupDock"
        )

        let menu = NSMenu()
        menu.delegate = self          // 開くたびにグループ / ウィジェットの項目を作り直す
        add(to: menu, "設定…", #selector(openSettings), key: ",")
        menu.addItem(.separator())
        add(to: menu, "Dock を表示 / 隠す", #selector(toggleDock))
        add(to: menu, "Dock のアプリを取り込む", #selector(importDock))
        add(to: menu, "グループを追加", #selector(addGroup))
        add(to: menu, "グループを閉じる", #selector(closeGroup))
        menu.addItem(.separator())
        add(to: menu, "Dock を戻す（非常用）", #selector(restoreDockNow))
        add(to: menu, "再起動（許可の変更を反映）", #selector(relaunch))
        menu.addItem(withTitle: "GroupDock を終了",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        statusItem.menu = menu
    }

    /// 標準 Dock の表示設定。起動のたびに killall Dock しないよう、変化したときだけ触る。
    private func applySystemDockWhenChanged(_ hide: Bool, force: Bool) {
        if !force, lastHideSystemDock == hide { return }
        // 初回は前回このアプリが適用した値と同じなら触らない。
        let applied = UserDefaults.standard.object(forKey: "GroupDockAppliedHideDock") as? Bool
        if !force, applied == hide {
            lastHideSystemDock = hide
            return
        }
        SystemDock.apply(hiding: hide)
        UserDefaults.standard.set(hide, forKey: "GroupDockAppliedHideDock")
        lastHideSystemDock = hide
    }

    /// グループに入っているアプリの起動・終了を知らせる。
    private func watchApplicationLaunches() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.announce(note, launched: true)
        }
        center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.announce(note, launched: false)
        }
    }

    private func announce(_ note: Notification, launched: Bool) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let path = app.bundleURL?.resolvingSymlinksInPath().path else { return }

        if launched {
            store.autoAdd(path)
        } else {
            store.removeOnQuit(path)
        }

    }

    /// メニューを開くたびに「グループ」「ウィジェットを追加」を作り直す。
    /// SwiftUI のボタンが効かない環境でも、ここからは必ず操作できる。
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.tag == 9001 || item.tag == 9002 {
            menu.removeItem(item)
        }
        guard let first = menu.items.first else { return }

        let groupItem = NSMenuItem(title: "グループを開く", action: nil, keyEquivalent: "")
        groupItem.tag = 9001
        let groupMenu = NSMenu()
        if store.groups.isEmpty {
            groupMenu.addItem(withTitle: "グループがありません", action: nil, keyEquivalent: "")
        } else {
            for group in store.groups {
                let item = NSMenuItem(title: group.name, action: #selector(openGroup(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = group.id
                groupMenu.addItem(item)
            }
        }
        groupItem.submenu = groupMenu
        menu.insertItem(groupItem, at: 1)

        let widgetItem = NSMenuItem(title: "ウィジェットを追加", action: nil, keyEquivalent: "")
        widgetItem.tag = 9002
        let widgetMenu = NSMenu()
        for kind in WidgetKind.allCases where kind != .custom {
            let item = NSMenuItem(title: kind.title, action: #selector(addWidget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            widgetMenu.addItem(item)
        }
        WidgetLibrary.reload()
        if !WidgetLibrary.definitions.isEmpty {
            widgetMenu.addItem(.separator())
            for def in WidgetLibrary.definitions {
                let item = NSMenuItem(title: "ライブラリ: \(def.title)", action: #selector(addLibraryWidget(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = def.id
                widgetMenu.addItem(item)
            }
        }
        widgetMenu.addItem(.separator())
        let gallery = NSMenuItem(title: "ギャラリー…", action: #selector(openGallery), keyEquivalent: "")
        gallery.target = self
        widgetMenu.addItem(gallery)
        widgetItem.submenu = widgetMenu
        menu.insertItem(widgetItem, at: 2)
        _ = first
    }

    @objc private func openGroup(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        primaryDock.openGroup(id)
    }

    @objc private func addWidget(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = WidgetKind(rawValue: raw) else { return }
        store.prefs.widgets.append(Widget(kind: kind))
    }

    @objc private func addLibraryWidget(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let def = WidgetLibrary.definition(id: id) else { return }
        store.prefs.widgets.append(Widget(definition: def))
    }

    @objc private func openGallery() { gallery.show() }

    private func add(to menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func openSettings() { settings.show() }

    @objc private func toggleDock() { primaryDock.toggle() }

    /// 「全ディスプレイ」の設定に合わせて、帯を作り直す。
    private func rebuildDocks() {
        for dock in docks { dock.close() }
        docks = []

        let main = NSScreen.main ?? NSScreen.screens.first
        primaryDock = DockWindowController(
            store: store,
            screen: main,
            openSettings: { [weak self] in self?.settings.show() },
            openPicker: { [weak self] in self?.picker.show() },
            openWidgetSettings: { [weak self] id in self?.widgetSettings.show(widgetID: id) },
            openGallery: { [weak self] in self?.gallery.show() }
        )
        docks = [primaryDock]

        guard store.prefs.allDisplays else { return }
        for screen in NSScreen.screens where screen != main {
            docks.append(DockWindowController(
                store: store,
                screen: screen,
                openSettings: { [weak self] in self?.settings.show() },
                openPicker: { [weak self] in self?.picker.show() },
                openWidgetSettings: { [weak self] id in self?.widgetSettings.show(widgetID: id) },
                openGallery: { [weak self] in self?.gallery.show() }
            ))
        }
    }

    @objc private func importDock() {
        store.importDockApps(into: store.expanded ?? store.groups.first?.id)
    }

    @objc private func addGroup() { store.addGroup() }

    @objc private func closeGroup() { primaryDock.closeGroup() }

    /// 固まったときの保険。標準 Dock をすぐ戻す（GroupDock は動いたままでよい）。
    @objc private func restoreDockNow() {
        SystemDock.showDock()
        NotificationLog.write("メニューから標準 Dock を戻しました")
    }

    /// アクセシビリティの許可は再起動で効くので、そのまま作り直す。
    @objc private func relaunch() { SelfRestart.run(store: store) }

    /// 終了時に、待たずに設定を書き出す。
    func applicationWillTerminate(_ notification: Notification) {
        watchdog.stop()
        store.flushPrefs()
        // 終了したら標準 Dock を必ず表示する（隠していた場合）。
        if store.prefs.hideSystemDock {
            SystemDock.showDock()
            UserDefaults.standard.set(false, forKey: "GroupDockAppliedHideDock")
        }
    }
}

// `--login-item on|off|status` は設定してすぐ終わる（自動化用）。
if LoginItem.handleArgumentIfPresent() {
    exit(0)
}

// 二重起動を防ぐ。すでに動いていたら、そのアプリを前面に出して終わる。
if SingleInstance.anotherIsRunning() {
    SingleInstance.activateExisting()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
