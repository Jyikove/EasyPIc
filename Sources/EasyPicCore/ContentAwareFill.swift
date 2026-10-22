import Foundation

/// Local reconstruction from original unmasked observations. No model or network service.
/// Surface/periodic tests are conservative; the general fallback uses a coarse-to-fine patch field.
enum ContentAwareFill {
    private typealias Pixel = SIMD4<Float>
    private struct Level {
        let w: Int, h: Int
        let rgb: [Pixel]
        let hole: [Bool]
        var count: Int { w * h }
    }
    private struct Solution { let level: Level; let pixels: [Pixel]; let field: [Int] }
    private struct Random {
        var state: UInt64 = 0xE45A_53B1
        mutating func next(_ limit: Int) -> Int {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(max(1, limit)))
        }
    }
    static func fill(bytes: [UInt8], width: Int, height: Int, mask: [Float]) throws -> [UInt8] {
        guard width * height <= 2_000_000 else { throw FillError.tooLarge }
        let count = width * height
        let hole = mask.map { $0 > 0 }
        let missing = hole.indices.filter { hole[$0] }
        guard !missing.isEmpty else { return bytes }
        let known = hole.indices.filter { !hole[$0] && bytes[$0 * 4 + 3] > 8 }
        guard known.count >= 4 else { throw FillError.noSource }
        let rgb = (0..<count).map { i in Pixel(Float(bytes[i * 4]), Float(bytes[i * 4 + 1]), Float(bytes[i * 4 + 2]), Float(bytes[i * 4 + 3])) }
        let level = Level(w: width, h: height, rgb: rgb, hole: hole)
        let samples = stride(from: 0, to: known.count, by: max(1, known.count / 4096)).map { known[$0] }
        let surface = fitSurface(level, samples: samples)
        var result: [Pixel]?
        if let surface, supportsSurface(surface, level: level, samples: samples) {
            var pixels = rgb
            for i in missing { pixels[i] = predicted(surface, i, level) }
            result = pixels
        }
        if result == nil { result = try periodic(level, samples: samples, missing: missing) }
        if result == nil {
            var pyramid = [level]
            while let last = pyramid.last, max(last.w, last.h) > 160, min(last.w, last.h) >= 32 {
                let reduced = reduce(last)
                if donors(reduced).count < 16 { break }
                pyramid.append(reduced)
            }
            var solution: Solution?
            for (index, current) in pyramid.reversed().enumerated() {
                try Task.checkCancellation()
                solution = try reconstruct(current, coarse: solution, passes: index == 0 ? 5 : (current.w == width ? 2 : 3))
            }
            result = solution?.pixels
        }
        guard let result else { throw FillError.noSource }
        var output = bytes
        for i in missing {
            for c in 0..<3 { output[i * 4 + c] = UInt8(min(Float(bytes[i * 4 + 3]), max(0, result[i][c])).rounded()) }
            // Preserve the source alpha; repair changes color, never the image coverage.
        }
        return output
    }
    private static func fitSurface(_ l: Level, samples: [Int]) -> [Pixel]? {
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        var rhs = [Pixel](repeating: .zero, count: 3)
        for i in samples {
            let p = [1.0, Double(i % l.w) / Double(max(1, l.w - 1)), Double(i / l.w) / Double(max(1, l.h - 1))]
            for a in 0..<3 {
                rhs[a] += l.rgb[i] * Float(p[a])
                for b in 0..<3 { matrix[a][b] += p[a] * p[b] }
            }
        }
        for column in 0..<3 {
            let pivot = (column..<3).max { abs(matrix[$0][column]) < abs(matrix[$1][column]) }!
            guard abs(matrix[pivot][column]) > 1e-8 else { return nil }
            matrix.swapAt(column, pivot); rhs.swapAt(column, pivot)
            let divisor = matrix[column][column]
            for j in column..<3 { matrix[column][j] /= divisor }; rhs[column] /= Float(divisor)
            for row in 0..<3 where row != column {
                let factor = matrix[row][column]
                for j in column..<3 { matrix[row][j] -= factor * matrix[column][j] }
                rhs[row] -= rhs[column] * Float(factor)
            }
        }
        return rhs
    }
    private static func predicted(_ fit: [Pixel], _ i: Int, _ l: Level) -> Pixel {
        fit[0] + fit[1] * (Float(i % l.w) / Float(max(1, l.w - 1))) + fit[2] * (Float(i / l.w) / Float(max(1, l.h - 1)))
    }
    private static func supportsSurface(_ fit: [Pixel], level: Level, samples: [Int]) -> Bool {
        var supported = 0, error: Float = 0
        for i in samples {
            let d = predicted(fit, i, level) - level.rgb[i]
            let residual = max(abs(d.x), max(abs(d.y), abs(d.z)))
            if residual <= 3 { supported += 1 }; error += residual
        }
        return Float(supported) >= Float(samples.count) * 0.97 && error / Float(samples.count) < 1.5
    }
    private static func periodic(_ l: Level, samples: [Int], missing: [Int]) throws -> [Pixel]? {
        for axis in 0..<2 {
            for step in 1...min(48, max(1, (axis == 0 ? l.w : l.h) / 3)) {
                try Task.checkCancellation()
                let dx = axis == 0 ? step : 0, dy = axis == 1 ? step : 0
                var tested = 0, matched = 0
                for i in samples {
                    let x = i % l.w + dx, y = i / l.w + dy
                    guard x < l.w, y < l.h else { continue }
                    let j = y * l.w + x
                    guard !l.hole[j] else { continue }
                    tested += 1
                    let d = l.rgb[i] - l.rgb[j]
                    if max(abs(d.x), max(abs(d.y), abs(d.z))) <= 0.5 { matched += 1 }
                }
                guard tested >= max(12, samples.count / 3), Float(matched) >= Float(tested) * 0.995 else { continue }
                var pixels = l.rgb, complete = true
                for i in missing {
                    var donor: Int?
                    for distance in 1...max(l.w, l.h) / step {
                        for sign in [-1, 1] {
                            let x = i % l.w + sign * dx * distance, y = i / l.w + sign * dy * distance
                            guard x >= 0, x < l.w, y >= 0, y < l.h else { continue }
                            let j = y * l.w + x
                            if !l.hole[j] && l.rgb[j].w > 8 { donor = j; break }
                        }
                        if donor != nil { break }
                    }
                    guard let donor else { complete = false; break }
                    pixels[i] = l.rgb[donor]
                }
                if complete { return pixels }
            }
        }
        return nil
    }
    private static func reduce(_ l: Level) -> Level {
        let w = (l.w + 1) / 2, h = (l.h + 1) / 2
        var rgb = [Pixel](repeating: .zero, count: w * h), hole = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w {
            var total: Float = 0
            for dy in 0..<2 { for dx in 0..<2 {
                let sx = x * 2 + dx, sy = y * 2 + dy
                guard sx < l.w, sy < l.h else { continue }
                let j = sy * l.w + sx
                // OR reduction prevents any masked source color becoming a coarse donor.
                if l.hole[j] { hole[y * w + x] = true }
                else { rgb[y * w + x] += l.rgb[j]; total += 1 }
            } }
            if total > 0 { rgb[y * w + x] /= total }
        } }
        return Level(w: w, h: h, rgb: rgb, hole: hole)
    }
    private static func donors(_ l: Level) -> [Int] {
        guard l.w >= 5, l.h >= 5 else { return [] }
        var integral = [Int](repeating: 0, count: (l.w + 1) * (l.h + 1))
        let stride = l.w + 1
        for y in 0..<l.h {
            var row = 0
            for x in 0..<l.w {
                if l.hole[y * l.w + x] || l.rgb[y * l.w + x].w < 8 { row += 1 }
                integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + row
            }
        }
        var result: [Int] = []
        for y in 2..<(l.h - 2) { for x in 2..<(l.w - 2) {
            let invalid = integral[(y + 3) * stride + x + 3] - integral[(y - 2) * stride + x + 3] - integral[(y + 3) * stride + x - 2] + integral[(y - 2) * stride + x - 2]
            if invalid == 0 { result.append(y * l.w + x) }
        } }
        return result
    }
    private static func lab(_ p: Pixel) -> Pixel {
        func linear(_ c: Float) -> Float { let v = c / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = linear(p.x), g = linear(p.y), b = linear(p.z)
        func f(_ x: Float) -> Float { x > 0.008856 ? pow(x, 1 / 3) : 7.787 * x + 16 / 116 }
        let x = f((0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047)
        let y = f(0.2126729 * r + 0.7151522 * g + 0.0721750 * b)
        let z = f((0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883)
        return Pixel((116 * y - 16) / 100, 500 * (x - y) / 128, 200 * (y - z) / 128, 0)
    }
    private static func squared(_ p: Pixel) -> Float { p.x * p.x + p.y * p.y + p.z * p.z }
    private static func backgroundGuide(_ l: Level, source: [Pixel], fit: [Pixel]?, mean: Pixel) -> [Pixel] {
        var horizontal = [Int32](repeating: -1, count: l.count), vertical = horizontal
        var best = [Float](repeating: .infinity, count: l.count)
        var guide = (0..<l.count).map { i in lab(fit.map { predicted($0, i, l) } ?? mean) }
        // The arrays store the nearest real observation, never a synthesized pixel.
        for y in 0..<l.h {
            var previous: Int32 = -1
            for x in 0..<l.w {
                let i = y * l.w + x
                if !l.hole[i] { previous = Int32(i) }; horizontal[i] = previous
            }
            previous = -1
            for x in (0..<l.w).reversed() {
                let i = y * l.w + x
                if !l.hole[i] { previous = Int32(i); continue }
                let a = Int(horizontal[i]), b = Int(previous)
                if a >= 0, b >= 0 {
                    let contrast = squared(source[a] - source[b]), distance = Float(b - a)
                    if contrast < 0.3 {
                        best[i] = (0.002 + contrast) * sqrt(distance)
                        let t = Float(i - a) / distance
                        guide[i] = lab(l.rgb[a] * (1 - t) + l.rgb[b] * t)
                    }
                } else if a >= 0 || b >= 0 { guide[i] = source[max(a, b)] }
            }
        }
        for x in 0..<l.w {
            var previous: Int32 = -1
            for y in 0..<l.h {
                let i = y * l.w + x
                if !l.hole[i] { previous = Int32(i) }; vertical[i] = previous
            }
            previous = -1
            for y in (0..<l.h).reversed() {
                let i = y * l.w + x
                if !l.hole[i] { previous = Int32(i); continue }
                let a = Int(vertical[i]), b = Int(previous)
                if a >= 0, b >= 0 {
                    let contrast = squared(source[a] - source[b]), distance = Float(b - a) / Float(l.w)
                    let confidence = (0.002 + contrast) * sqrt(distance)
                    if contrast < 0.3, confidence < best[i] {
                        let t = Float(i - a) / Float(b - a)
                        guide[i] = lab(l.rgb[a] * (1 - t) + l.rgb[b] * t)
                    }
                } else if !best[i].isFinite, a >= 0 || b >= 0 { guide[i] = source[max(a, b)] }
            }
        }
        return guide
    }
    private static func reconstruct(_ l: Level, coarse: Solution?, passes: Int) throws -> Solution {
        let candidates = donors(l)
        guard !candidates.isEmpty else { throw FillError.noSource }
        var eligible = [Bool](repeating: false, count: l.count)
        for i in candidates { eligible[i] = true }
        let missing = l.hole.indices.filter { l.hole[$0] }
        let source = l.rgb.map(lab)
        let samples = stride(from: 0, to: candidates.count, by: max(1, candidates.count / 2048)).map { candidates[$0] }
        let fit = fitSurface(l, samples: samples)
        let mean = candidates.reduce(Pixel.zero) { $0 + l.rgb[$1] } / Float(candidates.count)
        let guide = backgroundGuide(l, source: source, fit: fit, mean: mean)
        var output = source, field = [Int](repeating: -1, count: l.count), random = Random()
        for i in missing {
            output[i] = guide[i]
            var best = candidates[random.next(candidates.count)], bestCost = Float.greatestFiniteMagnitude
            if let coarse {
                let x = min(coarse.level.w - 1, i % l.w / 2), y = min(coarse.level.h - 1, i / l.w / 2)
                let c = y * coarse.level.w + x
                output[i] = lab(coarse.pixels[c])
                let donor = coarse.field[c]
                if donor >= 0 {
                    let sx = donor % coarse.level.w * 2 + i % l.w % 2, sy = donor / coarse.level.w * 2 + i / l.w % 2
                    if sx < l.w, sy < l.h, eligible[sy * l.w + sx] { best = sy * l.w + sx }
                }
            }
            for attempt in 0..<12 {
                let c = attempt == 0 ? best : candidates[random.next(candidates.count)]
                let cost = squared(source[c] - output[i])
                if cost < bestCost { best = c; bestCost = cost }
            }
            field[i] = best
        }
        var costs = [Float](repeating: 0, count: l.count)
        let expectedReuse = max(1, Float(missing.count) / Float(candidates.count))
        for pass in 0..<passes {
            try Task.checkCancellation()
            var reuse = [Int](repeating: 0, count: l.count)
            for i in missing { reuse[field[i]] += 1 }
            let order = pass % 2 == 0 ? missing : Array(missing.reversed())
            let direction = pass % 2 == 0 ? -1 : 1
            for (ordinal, i) in order.enumerated() {
                if ordinal % 128 == 0 { try Task.checkCancellation() }
                let tx = i % l.w, ty = i / l.w
                func score(_ donor: Int, limit: Float) -> Float {
                    let sx = donor % l.w, sy = donor / l.w
                    let fixed = squared(source[donor] - guide[i]) * 0.025 + Float(reuse[donor]) / expectedReuse * 0.0005
                    var sum: Float = 0, weight: Float = 0
                    for dy in -2...2 { for dx in -2...2 {
                        let x = tx + dx, y = ty + dy
                        guard x >= 0, x < l.w, y >= 0, y < l.h else { continue }
                        let target = y * l.w + x, sample = (sy + dy) * l.w + sx + dx
                        let w: Float = l.hole[target] ? 0.2 : 1
                        sum += squared(output[target] - source[sample]) * w; weight += w
                    } }
                    return sum / max(1, weight) + fixed
                }
                var best = field[i], bestCost = score(field[i], limit: .infinity)
                func consider(_ c: Int) {
                    guard c >= 0, c < l.count, eligible[c] else { return }
                    let cost = score(c, limit: bestCost)
                    if cost < bestCost { best = c; bestCost = cost }
                }
                if tx + direction >= 0, tx + direction < l.w {
                    let j = i + direction
                    if l.hole[j] { let c = field[j] - direction; if c / l.w == field[j] / l.w { consider(c) } }
                }
                if ty + direction >= 0, ty + direction < l.h, l.hole[i + direction * l.w] { consider(field[i + direction * l.w] - direction * l.w) }
                var radius = max(l.w, l.h)
                while radius >= 1 {
                    let x = min(l.w - 1, max(0, best % l.w + random.next(radius * 2 + 1) - radius))
                    let y = min(l.h - 1, max(0, best / l.w + random.next(radius * 2 + 1) - radius))
                    consider(y * l.w + x); radius /= 2
                }
                field[i] = best; costs[i] = bestCost
            }
            // Overlapping compatible votes reduce patch seams without blending unrelated colors.
            var voted = output
            for i in missing {
                let x = i % l.w, y = i / l.w, anchor = source[field[i]]
                var sum = anchor * 2, total: Float = 2
                for dy in -1...1 { for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < l.w, ny >= 0, ny < l.h else { continue }
                    let j = ny * l.w + nx
                    guard l.hole[j] else { continue }
                    let donor = field[j] - dy * l.w - dx
                    let color = source[donor]
                    guard squared(color - anchor) < 0.025 else { continue }
                    let weight = 1 / (1 + costs[j] * 40)
                    sum += color * weight; total += weight
                } }
                voted[i] = sum / total
            }
            output = voted
        }
        var result = l.rgb
        // Vote directly in source RGB, retaining compatible detail from original observations.
        for i in missing {
            let x = i % l.w, y = i / l.w, anchor = source[field[i]]
            var sum = l.rgb[field[i]] * 2, total: Float = 2
            for dy in -1...1 { for dx in -1...1 {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < l.w, ny >= 0, ny < l.h else { continue }
                let j = ny * l.w + nx
                guard l.hole[j] else { continue }
                let donor = field[j] - dy * l.w - dx
                guard squared(source[donor] - anchor) < 0.025 else { continue }
                let weight = 1 / (1 + costs[j] * 40)
                sum += l.rgb[donor] * weight; total += weight
            } }
            result[i] = sum / total
        }
        return Solution(level: l, pixels: result, field: field)
    }
    private enum FillError: LocalizedError {
        case noSource, tooLarge
        var errorDescription: String? {
            switch self {
            case .noSource: L10n.text("周围没有足够的图像内容，请缩小消除范围。")
            case .tooLarge: L10n.text("消除范围过大，请分几次涂抹。")
            }
        }
    }
}
