// Stand-in for the parts of BackgroundTasks the app uses.
import Foundation

public class BGTaskRequest: NSObject {
    public let identifier: String
    public var earliestBeginDate: Date?
    fileprivate init(id: String) { identifier = id }
}

public final class BGAppRefreshTaskRequest: BGTaskRequest {
    public init(identifier: String) { super.init(id: identifier) }
}

public final class BGTaskScheduler: NSObject, @unchecked Sendable {
    public static let shared = BGTaskScheduler()
    public private(set) var submitted: [BGTaskRequest] = []
    public func submit(_ taskRequest: BGTaskRequest) throws { submitted.append(taskRequest) }
}
