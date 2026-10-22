import EasyPicCore
import AppKit

extension EditorModel {
    func rotateSVG(_ operation: EditOperation) {
        guard canRotate, let image else { return }
        let delta: Int
        switch operation { case .counterclockwise: delta = 1; case .clockwise: delta = -1; default: return }
        let transition = RotationTransition(image: image, angle: Double(-90 * delta))
        rotationTransition = transition; busy = true
        Task {
            do {
                let rotated = try await Task.detached { try ImageEngine.render(image, operations: [operation]) }.value
                await transition.waitForCompletion()
                self.image = rotated; documentPreview = rotated
                svgQuarterTurns = (svgQuarterTurns + delta + 4) % 4
            } catch { self.error = error.localizedDescription }
            rotationTransition = nil; busy = false
        }
    }
}
