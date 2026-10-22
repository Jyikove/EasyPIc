import Foundation
import os

/// Bounded, opt-in traces. No filenames, recognized text, image pixels or QR payloads.
public final class InteractionMetrics: @unchecked Sendable {
    public static let shared = InteractionMetrics()
    private let lock = NSLock()
    private let log = OSLog(subsystem: "local.jyikove.EasyPic", category: "Interaction")
    private struct Trace: Codable {
        let id: UUID
        let parent: UUID?
        let kind: String
        let start: Double
        var events: [Event] = []
        var counters: [String: Int] = [:]
    }
    private struct Event: Codable { let stage: String; let elapsedMS: Double }
    private var recording = false
    private var traces: [UUID: Trace] = [:]
    private var order: [UUID] = []
    public var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return recording }
    public func setEnabled(_ enabled: Bool) { lock.lock(); recording = enabled; lock.unlock() }
    public func reset() { lock.lock(); traces.removeAll(); order.removeAll(); lock.unlock() }
    public func begin(_ kind: String, at time: Double? = nil, parent: UUID? = nil) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard recording else { return nil }
        let id = UUID()
        traces[id] = Trace(id: id, parent: parent, kind: kind, start: time ?? ProcessInfo.processInfo.systemUptime)
        order.append(id)
        while order.count > 1024 { traces.removeValue(forKey: order.removeFirst()) }
        os_signpost(.event, log: log, name: "Interaction", "%{public}s", kind)
        return id
    }
    public func mark(_ id: UUID?, _ stage: String, at time: Double? = nil) {
        guard let id else { return }
        lock.lock(); defer { lock.unlock() }
        guard recording, var trace = traces[id], trace.events.count < 48 else { return }
        trace.events.append(Event(stage: stage, elapsedMS: max(0, (time ?? ProcessInfo.processInfo.systemUptime) - trace.start) * 1000))
        traces[id] = trace
        os_signpost(.event, log: log, name: "Stage", "%{public}s", stage)
    }
    public func count(_ id: UUID?, _ key: String, _ amount: Int = 1) {
        guard let id else { return }; lock.lock(); defer { lock.unlock() }
        if recording { traces[id]?.counters[key, default: 0] += amount }
    }
    public func report() throws -> Data {
        lock.lock(); let snapshot = order.compactMap { traces[$0] }; lock.unlock()
        let byID = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
        struct CompletedInteraction: Encodable {
            let id: UUID
            let kind: String
            let inputToViewUpdateMS: Double
            let inputToDisplayOpportunityEstimateMS: Double
        }
        let completed: [CompletedInteraction] = snapshot.compactMap { trace in
            guard let view = trace.events.first(where: { $0.stage == "ViewUpdate" }),
                  let display = trace.events.first(where: { $0.stage == "NextDisplayOpportunityEstimate" }) else { return nil }
            var first = trace, visited: Set<UUID> = [trace.id]
            while let parent = first.parent, !visited.contains(parent), let ancestor = byID[parent] {
                visited.insert(parent); first = ancestor
            }
            let precedingMS = max(0, trace.start - first.start) * 1000
            return CompletedInteraction(id: trace.id, kind: trace.kind,
                                        inputToViewUpdateMS: precedingMS + view.elapsedMS,
                                        inputToDisplayOpportunityEstimateMS: precedingMS + display.elapsedMS)
        }
        struct Report: Encodable {
            let schema = 1
            let presentation = "next display-link opportunity after view update; estimate, not measured hardware presentation"
            let traces: [Trace]
            let completedInteractions: [CompletedInteraction]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Report(traces: snapshot, completedInteractions: completed))
    }
}
