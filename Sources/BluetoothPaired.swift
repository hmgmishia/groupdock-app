import CoreBluetooth
import Foundation
import IOBluetooth

/// Bluetooth のペアリング済み機器の一覧（いまつないでいない AirPods なども含む）。固定の候補に出すためだけに読む。
/// - 読むのは名前とアドレスだけ。接続・操作・通信はしない。公開 API（IOBluetooth・CoreBluetooth）だけを使う。
/// - macOS の Bluetooth 許可が無いと、`IOBluetoothDevice` を触った時点でアプリが落ちる（実測）。
///   許可の状態（`CBManager.authorization`）を先に確かめ、許可済みのときだけ読む。
///   未決定・拒否のときは、空を返す（落ちない・勝手にダイアログも出さない）。許可は、ポップアップのボタンで求める。
enum BluetoothPaired {
    /// ペアリング済みの機器（アドレス・名前）。許可済みのときだけ。
    static func devices() -> [(address: String, name: String)] {
        guard isAuthorized else { return [] }
        let list = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return list.compactMap { device in
            guard let address = device.addressString else { return nil }
            return (address: address, name: device.name ?? "")
        }
    }

    /// 許可が出ているか（読み込めるか）。
    static var isAuthorized: Bool { CBManager.authorization == .allowedAlways }

    /// 許可をまだ求めていないか（ボタンで求められる）。
    static var canAsk: Bool { CBManager.authorization == .notDetermined }

    private static var requester: CBCentralManager?

    /// 許可を求める（macOS が確認ダイアログを 1 回出す）。メインのスレッドから呼ぶ。
    static func requestAccess() {
        guard canAsk, requester == nil else { return }
        requester = CBCentralManager(delegate: nil, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }
}
