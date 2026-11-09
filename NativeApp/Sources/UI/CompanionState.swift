import SwiftUI

@MainActor final class CompanionState: ObservableObject {
    static let shared = CompanionState()
    enum Phase: String { case watching, received, processing, delivering, success, failed, cancelled }
    @Published var phase: Phase = .watching
    @Published var gaze: CGFloat = 0
    @Published var caption = "Choose a target"
    private var generation = 0
    func watch(label: String? = nil, direction: CGFloat = 0) {
        guard phase == .watching else { return }
        gaze = max(-1, min(1, direction))
        caption = label.map { "Over \($0)" } ?? "Choose a target"
    }
    func set(_ phase: Phase) {
        generation += 1
        self.phase = phase
        switch phase {
        case .watching: caption = "Choose a target"
        case .received: caption = "Received"
        case .processing: caption = "Converting…"
        case .delivering: caption = "Saving…"
        case .success: caption = "Done"
        case .failed: caption = "Something went wrong"
        case .cancelled: caption = "Stopped. The original is unchanged"
        }
    }
    @discardableResult
    func transition(from: Phase, to: Phase, after delay: Double) -> Task<Void, Never> {
        set(from)
        let token = generation
        return Task {
            try? await Task.sleep(for: .seconds(delay))
            guard generation == token else { return }
            set(to)
        }
    }
}
