import CoreGraphics
import Foundation
import ImageIO
import Vision

/// A photo or image in a group of look-alikes.
public struct SimilarImage: Identifiable, Hashable, Sendable {
    public enum Flaw: String, Sendable { case blurry }

    public var id: String { path }
    public let path: String
    public let bytes: Int64
    public let pixels: Int
    /// Edge contrast; higher is sharper.
    public let sharpness: Double
    public let modified: Date
    public var flaw: Flaw?

    public var name: String { (path as NSString).lastPathComponent }
}

public struct SimilarGroup: Identifiable, Hashable, Sendable {
    public var id: String { images.first?.path ?? UUID().uuidString }
    public var images: [SimilarImage]
    /// The one worth keeping: sharpest, then largest.
    public var best: String

    public var reclaimable: Int64 { images.filter { $0.path != best }.reduce(0) { $0 + $1.bytes } }
}

public struct SimilarProgress: Sendable, Equatable {
    public var found = 0
    public var analysed = 0
    public var currentPath = ""
    public init(found: Int = 0, analysed: Int = 0, currentPath: String = "") {
        self.found = found
        self.analysed = analysed
        self.currentPath = currentPath
    }
}

/// Finds near-identical images (bursts, edits, re-saves) with Vision's image feature prints.
/// Works on folders of image files; the Photos library is not opened.
public struct SimilarImageFinder: Sendable {
    public var threshold: Float = 0.38
    public var limit = 6_000
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp"]

    public init() {}

    public func find(in roots: [String], progress: @escaping @Sendable (SimilarProgress) -> Void = { _ in }) async throws -> [SimilarGroup] {
        DiskUsage.avoidDownloadingCloudFiles()
        var paths: [(String, Int64, Date)] = []
        for root in ProjectScanner.minimalRoots(roots) {
            DiskUsage.walk(root) { (entry: UnsafeMutablePointer<FTSENT>) -> Bool in
                switch Int32(entry.pointee.fts_info) {
                case FTS_D where entry.pointee.fts_level > 0:
                    let path = String(cString: entry.pointee.fts_path)
                    let name = (path as NSString).lastPathComponent
                    // Hidden folders, bundles (Photos libraries, apps, asset catalogs) and code projects,
                    // whose images are icons, charts and assets rather than photos.
                    return !(name.hasPrefix(".") || name.hasSuffix(".photoslibrary") || name.hasSuffix(".app")
                        || name.hasSuffix(".xcassets") || name.hasSuffix(".swiftpm")
                        || ArtifactRules.classify(name: name, path: path) != nil || FolderSuggestions.isProject(path))
                case FTS_F:
                    guard paths.count < limit, let st = entry.pointee.fts_statp?.pointee,
                          st.st_size >= 40_000, Int64(st.st_blocks) * 512 >= Int64(st.st_size) / 2 else { return true }
                    let path = String(cString: entry.pointee.fts_path)
                    guard Self.extensions.contains((path as NSString).pathExtension.lowercased()) else { return true }
                    paths.append((path, Int64(st.st_blocks) * 512, Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))))
                    return true
                default:
                    return true
                }
            }
        }
        progress(SimilarProgress(found: paths.count, analysed: 0, currentPath: ""))

        // Feature prints, four at a time.
        let reporter = SimilarReporter(found: paths.count, sink: progress)
        var analysed: [(SimilarImage, VNFeaturePrintObservation)] = []
        try await withThrowingTaskGroup(of: (SimilarImage, VNFeaturePrintObservation)?.self) { group in
            var next = paths.makeIterator()
            func enqueue() {
                guard let (path, bytes, modified) = next.next() else { return }
                group.addTask {
                    try Task.checkCancellation()
                    defer { reporter.tick(path) }
                    return Self.analyse(path, bytes: bytes, modified: modified)
                }
            }
            for _ in 0..<4 { enqueue() }
            while let result = try await group.next() {
                if let result { analysed.append(result) }
                enqueue()
            }
        }

        // Group greedily: each image joins the first group whose first member is close enough.
        var groups: [[(SimilarImage, VNFeaturePrintObservation)]] = []
        for item in analysed.sorted(by: { $0.0.modified < $1.0.modified }) {
            try Task.checkCancellation()
            var placed = false
            for index in groups.indices {
                var distance: Float = .infinity
                try? groups[index][0].1.computeDistance(&distance, to: item.1)
                if distance <= threshold {
                    groups[index].append(item)
                    placed = true
                    break
                }
            }
            if !placed { groups.append([item]) }
        }

        return groups.filter { $0.count > 1 }.map { members in
            var images = members.map(\.0)
            let sharpest = images.map(\.sharpness).max() ?? 1
            for i in images.indices where images[i].sharpness < sharpest * 0.45 { images[i].flaw = .blurry }
            let best = images.max { ($0.sharpness * log(Double(max($0.pixels, 2)))) < ($1.sharpness * log(Double(max($1.pixels, 2)))) }!
            return SimilarGroup(images: images, best: best.path)
        }
        .sorted { $0.reclaimable > $1.reclaimable }
    }

    static func analyse(_ path: String, bytes: Int64, modified: Date) -> (SimilarImage, VNFeaturePrintObservation)? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 384,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? thumbnail.width
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? thumbnail.height
        let request = VNGenerateImageFeaturePrintRequest()
        do {
            try VNImageRequestHandler(cgImage: thumbnail, options: [:]).perform([request])
        } catch {
            return nil
        }
        guard let print = request.results?.first as? VNFeaturePrintObservation else { return nil }
        let image = SimilarImage(path: path, bytes: bytes, pixels: width * height, sharpness: sharpness(thumbnail),
                                 modified: modified, flaw: nil)
        return (image, print)
    }

    /// Variance of the Laplacian on a small grayscale copy: blurry images have little of it.
    static func sharpness(_ image: CGImage) -> Double {
        let side = 192
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var sum = 0.0
        var sumSquares = 0.0
        var count = 0.0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let i = y * side + x
                let laplacian = Double(pixels[i - side]) + Double(pixels[i + side]) + Double(pixels[i - 1]) + Double(pixels[i + 1])
                    - 4 * Double(pixels[i])
                sum += laplacian
                sumSquares += laplacian * laplacian
                count += 1
            }
        }
        let mean = sum / count
        return sumSquares / count - mean * mean
    }
}

private final class SimilarReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var state: SimilarProgress
    private var lastSent = Date.distantPast
    private let sink: @Sendable (SimilarProgress) -> Void

    init(found: Int, sink: @escaping @Sendable (SimilarProgress) -> Void) {
        state = SimilarProgress(found: found, analysed: 0, currentPath: "")
        self.sink = sink
    }

    func tick(_ path: String) {
        lock.lock()
        state.analysed += 1
        state.currentPath = path
        let send = Date().timeIntervalSince(lastSent) > 0.2
        if send { lastSent = Date() }
        let snapshot = state
        lock.unlock()
        if send { sink(snapshot) }
    }
}
