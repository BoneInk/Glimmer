import Darwin
import Foundation
import SystemConfiguration

/// One of the Mac's IPv4 addresses on a local network, which "Send over Wi-Fi" listens on and puts
/// in the QR code. Only private (RFC 1918) and link-local (169.254/16) addresses of interfaces that
/// are up, not loopback and not point-to-point (VPN tunnels) count: the server never listens on an
/// address the internet could reach.
///
/// IPv6 isn't offered: a link-local address needs a zone (`%en0`) that Android's browsers don't
/// accept in a URL.
struct AndroidLANAddress: Hashable, Identifiable, Sendable {
    /// The BSD name (`en0`).
    var interface: String
    /// What System Settings calls the interface (Wi-Fi, Ethernet), when it has a name.
    var displayName: String?
    /// The address and its netmask, in host byte order.
    var address: UInt32
    var netmask: UInt32

    var id: String { "\(interface) \(host)" }
    var host: String { Self.dotted(address) }

    /// Whether `remote` is on this address's subnet.
    func contains(_ remote: UInt32) -> Bool { remote & netmask == address & netmask }

    /// The Mac's local-network addresses, the primary interface's first.
    static func current() -> [AndroidLANAddress] {
        let primary = primaryInterface()
        let names = displayNames()
        var found: [AndroidLANAddress] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else {
            OWELog.error(.app, "Send over Wi-Fi: getifaddrs failed (errno \(errno))")
            return []
        }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let socket = entry.ifa_addr, socket.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.ifa_netmask,
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0 else { continue }
            let address = ipv4(socket), netmask = ipv4(mask)
            guard isLocalNetwork(address) else { continue }
            let interface = String(cString: entry.ifa_name)
            found.append(AndroidLANAddress(interface: interface, displayName: names[interface], address: address, netmask: netmask))
        }
        return order(found, primary: primary)
    }

    /// The primary interface's addresses first, then by interface name.
    static func order(_ addresses: [AndroidLANAddress], primary: String?) -> [AndroidLANAddress] {
        addresses.sorted { lhs, rhs in
            if (lhs.interface == primary) != (rhs.interface == primary) { return lhs.interface == primary }
            return lhs.interface.compare(rhs.interface, options: .numeric) == .orderedAscending
        }
    }

    /// 10/8, 172.16/12, 192.168/16 and 169.254/16.
    static func isLocalNetwork(_ address: UInt32) -> Bool {
        address >> 24 == 10 || address >> 20 == 0xAC1 || address >> 16 == 0xC0A8 || address >> 16 == 0xA9FE
    }

    static func dotted(_ address: UInt32) -> String {
        "\(address >> 24).\(address >> 16 & 0xFF).\(address >> 8 & 0xFF).\(address & 0xFF)"
    }

    /// `a.b.c.d` in host byte order.
    static func parse(_ text: String) -> UInt32? {
        var value = in_addr()
        guard inet_pton(AF_INET, text, &value) == 1 else { return nil }
        return UInt32(bigEndian: value.s_addr)
    }

    private static func ipv4(_ socket: UnsafeMutablePointer<sockaddr>) -> UInt32 {
        socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
    }

    /// The interface macOS routes through by default (`State:/Network/Global/IPv4`).
    private static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "OpenWallpaperEngine" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return nil }
        return global["PrimaryInterface"] as? String
    }

    private static func displayNames() -> [String: String] {
        var names: [String: String] = [:]
        for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? else { continue }
            names[bsd] = name
        }
        return names
    }
}
