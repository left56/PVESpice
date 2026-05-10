import Foundation

/// 列表中的一行：已判定为具备 SPICE（QXL）显示配置的 QEMU 虚拟机。
struct PVEVirtualMachineRow: Identifiable, Hashable {
    var id: String { "\(node)-\(vmid)" }
    var vmid: Int
    var name: String
    var node: String
    /// cluster/resources 的 status，如 running、stopped
    var powerStatus: String

    var powerStatusLabel: String {
        switch powerStatus.lowercased() {
        case "running": return "运行中"
        case "stopped": return "已停止"
        default: return powerStatus
        }
    }
}
