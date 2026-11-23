// Stand-in for the parts of Network.framework the app uses.
// A connection to any endpoint becomes ready at once and reports `NWConnection.stubRemote`
// as the address it reached; the browser reports nothing until a test calls `deliver`.
import Foundation

public final class NWInterface: Hashable, @unchecked Sendable {
    public let name: String
    public init(name: String) { self.name = name }
    public static func == (a: NWInterface, b: NWInterface) -> Bool { a.name == b.name }
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

public struct IPv4Address: Hashable, Sendable, CustomDebugStringConvertible {
    public let text: String
    public init?(_ string: String) { text = string }
    public var debugDescription: String { text }
}

public struct IPv6Address: Hashable, Sendable, CustomDebugStringConvertible {
    public let text: String
    public init?(_ string: String) { text = string }
    public var debugDescription: String { text }
}

public enum NWError: Error, Equatable, Sendable {
    case posix(POSIXErrorCode)
    case dns(Int32)
    case tls(Int32)
}

public enum NWEndpoint: Hashable, Sendable {
    public enum Host: Hashable, Sendable {
        case name(String, NWInterface?)
        case ipv4(IPv4Address)
        case ipv6(IPv6Address)
    }

    public struct Port: Hashable, Sendable, RawRepresentable {
        public let rawValue: UInt16
        public init?(rawValue: UInt16) { self.rawValue = rawValue }
    }

    case hostPort(host: NWEndpoint.Host, port: NWEndpoint.Port)
    case service(name: String, type: String, domain: String, interface: NWInterface?)
    case unix(path: String)
    case url(URL)
}

public struct NWPath: Sendable {
    public var remoteEndpoint: NWEndpoint?
    public var localEndpoint: NWEndpoint?
}

public class NWProtocolOptions: @unchecked Sendable {}

public enum NWProtocolIP {
    public final class Options: NWProtocolOptions, @unchecked Sendable {
        public enum Version: Sendable { case any, v4, v6 }
        public var version: Version = .any
    }
}

public final class NWParameters: @unchecked Sendable {
    public final class ProtocolStack: @unchecked Sendable {
        public var internetProtocol: NWProtocolOptions? = NWProtocolIP.Options()
    }

    public let defaultProtocolStack = ProtocolStack()
    public init() {}
    public class var tcp: NWParameters { NWParameters() }
    public class var udp: NWParameters { NWParameters() }
}

public final class NWConnection: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case setup
        case waiting(NWError)
        case preparing
        case ready
        case failed(NWError)
        case cancelled
    }

    /// Test fixture: where a connection "ends up". nil makes connections fail.
    nonisolated(unsafe) public static var stubRemote: NWEndpoint?

    public let endpoint: NWEndpoint
    public let parameters: NWParameters
    public var stateUpdateHandler: (@Sendable (_ state: NWConnection.State) -> Void)?
    public private(set) var currentPath: NWPath?
    public private(set) var cancelled = false

    public init(to: NWEndpoint, using: NWParameters) {
        endpoint = to
        parameters = using
    }

    public func start(queue: DispatchQueue) {
        queue.async { [self] in
            guard !cancelled else { return }
            if let remote = NWConnection.stubRemote {
                currentPath = NWPath(remoteEndpoint: remote, localEndpoint: nil)
                stateUpdateHandler?(.ready)
            } else {
                stateUpdateHandler?(.waiting(.posix(.ECONNREFUSED)))
            }
        }
    }

    public func cancel() { cancelled = true }
}

public final class NWBrowser: @unchecked Sendable {
    public enum Descriptor: Hashable, Sendable {
        case bonjour(type: String, domain: String?)
        case bonjourWithTXTRecord(type: String, domain: String?)
    }

    public struct Result: Hashable, Sendable {
        public enum Change: Hashable, Sendable {
            case identical
            case added(NWBrowser.Result)
            case removed(NWBrowser.Result)
        }

        public let endpoint: NWEndpoint
        public init(endpoint: NWEndpoint) { self.endpoint = endpoint }
    }

    public enum State: Equatable, Sendable {
        case setup
        case ready
        case failed(NWError)
        case cancelled
        case waiting(NWError)
    }

    public let descriptor: Descriptor
    public var stateUpdateHandler: (@Sendable (_ newState: NWBrowser.State) -> Void)?
    public var browseResultsChangedHandler:
        (@Sendable (_ newResults: Set<NWBrowser.Result>, _ changes: Set<NWBrowser.Result.Change>) -> Void)?
    private var queue: DispatchQueue?

    public init(for descriptor: Descriptor, using parameters: NWParameters) { self.descriptor = descriptor }

    public func start(queue: DispatchQueue) {
        self.queue = queue
        queue.async { [self] in stateUpdateHandler?(.ready) }
    }

    public func cancel() { queue = nil }

    /// Test hook: pretend these services were found.
    public func deliver(_ results: Set<NWBrowser.Result>) {
        queue?.async { [self] in browseResultsChangedHandler?(results, []) }
    }
}
