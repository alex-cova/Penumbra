@preconcurrency import AppKit
import CoreText
import Foundation
import simd

struct GlyphExtractRequest {
    var line: CTLine
    var fragmentFrame: CGRect
    var descent: CGFloat
    var baseSize: CGSize
    var scaledSize: CGSize
    var unfocusedAlpha: CGFloat
    var focusedRanges: [NSRange]
    var scale: CGFloat
    var emitRect: CGRect
    var atlasWarmRect: CGRect
    var fallbackFont: CTFont
    var fallbackColor: NSColor
    var appearance: NSAppearance?
    var colorSpace: NSColorSpace = .sRGB
    var previousColors: [GlyphColorSample] = []
}

struct GlyphColorSample {
    var stringIndex: Int
    var color: SIMD4<Float>
}

enum GlyphRunSkipReason: Equatable {
    case shadow
    case oversize
    case rasterCap
    case lookupFailed
}

struct GlyphRunSkip: Equatable {
    var runIndex: Int
    var reason: GlyphRunSkipReason
}

struct ExtractedGlyph {
    var instance: GlyphInstance
    /// Unpadded glyph origin in content space (layout X, baseline Y).
    var contentOrigin: CGPoint
    var stringIndex: Int
    var isColor: Bool
    var matrixHash: UInt64
    var glyph: CGGlyph
}

struct GlyphExtractResult {
    var glyphs: [ExtractedGlyph]
    var baselineY: CGFloat
    var emitRect: CGRect
    var skips: [GlyphRunSkip]
    var warmedGlyphCount: Int

    var instances: [GlyphInstance] {
        glyphs.map(\.instance)
    }
}

struct GlyphRasterBudget {
    /// Bounded CPU raster work per layout pass. Highlighted Swift with several font traits can
    /// exceed 64 distinct cold glyphs in an ordinary viewport; 128 avoids multi-frame holes while
    /// retaining a hard ceiling for CJK/emoji-heavy cold scrolls.
    static let perFrameLimit = 128

    var remaining: Int

    init(limit: Int = perFrameLimit) {
        remaining = limit
    }

    var hasRemaining: Bool {
        remaining > 0
    }

    mutating func consume() -> Bool {
        guard remaining > 0 else {
            return false
        }
        remaining -= 1
        return true
    }
}

/// Instance rebuild key. A pan that moves `canvas.frame` must re-extract even when the line is
/// unchanged. Keyed on `LineFragment.revision`, not `ObjectIdentifier(CTLine)`: a re-typeset frees
/// the old `CTLine` and CoreFoundation readily reuses that address, so a brand-new (differently
/// colored) `CTLine` could otherwise alias a just-freed one and produce a false cache hit that
/// keeps stale (e.g. pre-syntax-highlight) colors on screen.
struct GlyphExtractCacheKey: Equatable {
    var revision: UInt64
    var emitRect: CGRect
    var isPending: Bool

    init(revision: UInt64, emitRect: CGRect, isPending: Bool = false) {
        self.revision = revision
        self.emitRect = emitRect
        self.isPending = isPending
    }

    /// The part of `emitRect` that can decide which of this fragment's glyphs are emitted.
    ///
    /// The canvas frame moves with every scroll step, so keying on the whole `emitRect` re-extracted
    /// every visible fragment every frame (~18% of main-thread time while scrolling). A glyph quad
    /// stays within the fragment frame widened by the margins below, so equal clipped rects give
    /// the same instances: a line that stays fully on screen keeps its key.
    static func relevantEmitRect(_ emitRect: CGRect, fragmentFrame: CGRect, scale: CGFloat) -> CGRect {
        let pad = CGFloat(GlyphRunExtractor.padPixels) / max(scale, 0.001)
        let horizontalMargin = CGFloat(GlyphRunExtractor.maxGlyphExtentPixels) / max(scale, 0.001) + pad
        let verticalMargin = fragmentFrame.height + pad
        let reach = fragmentFrame.insetBy(dx: -horizontalMargin, dy: -verticalMargin)
        let clipped = emitRect.intersection(reach)
        return clipped.isNull ? .zero : clipped
    }

    static func shouldRebuild(
        previous: GlyphExtractCacheKey?,
        revision: UInt64,
        emitRect: CGRect,
        isPending: Bool = false
    ) -> Bool {
        previous != GlyphExtractCacheKey(revision: revision, emitRect: emitRect, isPending: isPending)
    }
}

enum GlyphRunExtractor {
    static let padPixels = GlyphRasterizer.padPixels
    static let maxGlyphExtentPixels = GlyphRasterizer.maxGlyphExtentPixels
    static let verticalLayoutPadding: CGFloat = 350
    static let perFrameRasterLimit = GlyphRasterBudget.perFrameLimit

    /// Fragment-local baseline from the top, matching `LineController.caretRect` vertical centering.
    static func baselineY(baseSize: CGSize, scaledSize: CGSize, descent: CGFloat) -> CGFloat {
        (scaledSize.height + baseSize.height) / 2 - descent
    }

    @MainActor
    static func extract(_ request: GlyphExtractRequest, atlas: GlyphAtlas) -> GlyphExtractResult {
        var budget = GlyphRasterBudget()
        return extract(request, atlas: atlas, budget: &budget)
    }

    @MainActor
    static func extract(
        _ request: GlyphExtractRequest,
        atlas: GlyphAtlas,
        budget: inout GlyphRasterBudget
    ) -> GlyphExtractResult {
        let baselineY = baselineY(
            baseSize: request.baseSize,
            scaledSize: request.scaledSize,
            descent: request.descent
        )
        var result = GlyphExtractResult(
            glyphs: [],
            baselineY: baselineY,
            emitRect: request.emitRect,
            skips: [],
            warmedGlyphCount: 0
        )
        guard let runs = CTLineGetGlyphRuns(request.line) as? [CTRun] else {
            return result
        }
        var prepared: [PreparedRun] = []
        prepared.reserveCapacity(runs.count)
        for (runIndex, run) in runs.enumerated() {
            switch prepare(run, runIndex: runIndex, request: request, baselineY: baselineY) {
            case .skip(let skip):
                result.skips.append(skip)
            case .run(let preparedRun):
                prepared.append(preparedRun)
            }
        }
        var fallbackRuns = Set<Int>()
        for preparedRun in prepared {
            if let reason = preparedRun.forcedFallback {
                fallbackRuns.insert(preparedRun.runIndex)
                appendRunFallback(preparedRun, reason: reason, request: request, baselineY: baselineY,
                                  atlas: atlas, budget: &budget, into: &result)
                continue
            }
            let runInstanceStart = result.glyphs.count
            var capped: GlyphRunSkipReason?
            for pending in preparedRun.glyphs where pending.band == .emit {
                switch resolve(pending, preparedRun: preparedRun, request: request, atlas: atlas, budget: &budget) {
                case .instance(let extracted):
                    result.glyphs.append(extracted)
                case .warmed, .skipped:
                    break
                case .needsRasterCap:
                    capped = .rasterCap
                case .failed:
                    capped = .lookupFailed
                }
                if capped != nil {
                    break
                }
            }
            guard let reason = capped else {
                continue
            }
            // Drop this run's partial per-glyph instances and rasterize it whole instead.
            if result.glyphs.count > runInstanceStart {
                result.glyphs.removeLast(result.glyphs.count - runInstanceStart)
            }
            fallbackRuns.insert(preparedRun.runIndex)
            appendRunFallback(preparedRun, reason: reason, request: request, baselineY: baselineY,
                              atlas: atlas, budget: &budget, into: &result)
        }
        let cappedRuns = fallbackRuns.union(result.skips.compactMap { skip -> Int? in
            skip.reason == .rasterCap ? skip.runIndex : nil
        })
        for preparedRun in prepared where !cappedRuns.contains(preparedRun.runIndex) {
            for pending in preparedRun.glyphs where pending.band == .warm {
                if case .warmed = resolve(
                    pending,
                    preparedRun: preparedRun,
                    request: request,
                    atlas: atlas,
                    budget: &budget
                ) {
                    result.warmedGlyphCount += 1
                }
            }
        }
        return result
    }
}

private extension GlyphRunExtractor {
    enum Band {
        case emit
        case warm
        case none
    }

    struct PendingGlyph {
        var glyph: CGGlyph
        var position: CGPoint
        var stringIndex: Int
        var color: SIMD4<Float>
        var band: Band
    }

    struct PreparedRun {
        var runIndex: Int
        var font: CTFont
        var runMatrix: CGAffineTransform
        var isColor: Bool
        var matrixHash: UInt64
        var glyphs: [PendingGlyph]
        /// Set when the per-glyph coverage atlas cannot represent this run (`NSShadow`, a glyph over
        /// the size cap). The whole run is rasterized into one BGRA tile instead — see PR 8.
        var forcedFallback: GlyphRunSkipReason?
        var rawGlyphs: [CGGlyph] = []
        var rawPositions: [CGPoint] = []
        var stringIndexRange: Range<Int> = 0..<0
        var runColor: SIMD4<Float> = SIMD4(0, 0, 0, 1)
        var foregroundColor: NSColor = .textColor
        var shadow: NSShadow?
    }

    enum PrepareResult {
        case skip(GlyphRunSkip)
        case run(PreparedRun)
    }

    enum ResolveResult {
        case instance(ExtractedGlyph)
        case warmed
        case skipped
        case needsRasterCap
        case failed
    }

    enum RunFallbackResult {
        case instance(ExtractedGlyph)
        case offscreen
        case budgetExhausted
        case failed
    }

    static func prepare(
        _ run: CTRun,
        runIndex: Int,
        request: GlyphExtractRequest,
        baselineY: CGFloat
    ) -> PrepareResult {
        // Read the CFDictionary directly: bridging it to a Swift dictionary per run was ~25% of prepare.
        let attributes = CTRunGetAttributes(run) as NSDictionary
        let shadow = attributes[NSAttributedString.Key.shadow] as? NSShadow
        let font = (attributes[NSAttributedString.Key.font] as? NSFont) ?? (request.fallbackFont as NSFont)
        let fontMatrix = CTFontGetMatrix(font)
        // Run text matrix copies CTFontGetMatrix for synthetic italic; extra is run * font⁻¹ so bounds are not sheared twice.
        let runMatrix = extraRunMatrix(CTRunGetTextMatrix(run), fontMatrix: fontMatrix)
        let applyRunMatrix = !runMatrix.isIdentity
        let isColor = GlyphRasterizer.isColorFont(font)
        let runColor = resolveColor(attributes: attributes, request: request)
        let foregroundColor = (attributes[NSAttributedString.Key.foregroundColor] as? NSColor) ?? request.fallbackColor
        let glyphCount = CTRunGetGlyphCount(run)
        let matrixHash = GlyphKey.matrixHash(fontMatrix: fontMatrix, runMatrix: runMatrix)
        var preparedRun = PreparedRun(
            runIndex: runIndex,
            font: font,
            runMatrix: runMatrix,
            isColor: isColor,
            matrixHash: matrixHash,
            glyphs: [],
            forcedFallback: shadow != nil ? .shadow : nil,
            runColor: runColor,
            foregroundColor: foregroundColor,
            shadow: shadow
        )
        guard glyphCount > 0 else {
            return .run(preparedRun)
        }
        var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
        var positions = [CGPoint](repeating: .zero, count: glyphCount)
        var stringIndices = [CFIndex](repeating: 0, count: glyphCount)
        let range = CFRange(location: 0, length: glyphCount)
        CTRunGetGlyphs(run, range, &glyphs)
        CTRunGetPositions(run, range, &positions)
        CTRunGetStringIndices(run, range, &stringIndices)
        preparedRun.rawGlyphs = glyphs
        preparedRun.rawPositions = positions
        let intIndices = stringIndices.map { Int($0) }
        preparedRun.stringIndexRange = (intIndices.min() ?? 0)..<((intIndices.max() ?? 0) + 1)
        var pending: [PendingGlyph] = []
        pending.reserveCapacity(glyphCount)
        let scale = max(request.scale, 0.001)
        // A glyph's quad lies within `maxGlyphExtent` of its pen position, so glyphs farther than
        // that from the emit/warm bands can be dropped before asking Core Text for their bounds.
        // On a long line this was a bounds query for every glyph to paint the ~100 on screen.
        let reach = CGFloat(maxGlyphExtentPixels + padPixels) / scale
        let bands = request.emitRect.union(request.atlasWarmRect)
        let minX = bands.isNull ? -CGFloat.infinity : bands.minX - reach
        let maxX = bands.isNull ? CGFloat.infinity : bands.maxX + reach
        for index in 0..<glyphCount {
            var position = positions[index]
            let penX = request.fragmentFrame.minX + (applyRunMatrix ? position.applying(runMatrix).x : position.x)
            if penX < minX || penX > maxX {
                continue
            }
            var glyph = glyphs[index]
            var bounds = CGRect.zero
            CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, &bounds, 1)
            if applyRunMatrix {
                position = position.applying(runMatrix)
                bounds = bounds.applying(runMatrix)
            }
            let pixelSize = paddedPixelSize(bounds: bounds, scale: scale)
            if pixelSize.width > maxGlyphExtentPixels || pixelSize.height > maxGlyphExtentPixels {
                // One oversize glyph forces the whole run through the raster fallback. `.oversize`
                // (not `.shadow`) so `makeRunFallback` always attempts it — there is no `pending`
                // list to prove it's on screen. The shadow, if any, is still baked in.
                preparedRun.forcedFallback = .oversize
                preparedRun.glyphs = []
                return .run(preparedRun)
            }
            if pixelSize.width == 0 || pixelSize.height == 0 {
                continue
            }
            let padPoints = CGFloat(padPixels) / scale
            let padded = bounds.insetBy(dx: -padPoints, dy: -padPoints)
            let quad = CGRect(
                x: request.fragmentFrame.minX + position.x + padded.origin.x,
                y: request.fragmentFrame.minY + baselineY - (padded.origin.y + padded.height),
                width: padded.width,
                height: padded.height
            )
            let band: Band
            if quad.intersects(request.emitRect) {
                band = .emit
            } else if quad.intersects(request.atlasWarmRect) {
                band = .warm
            } else {
                continue
            }
            var color = runColor
            let stringIndex = Int(stringIndices[index])
            if let previousColor = previousColor(at: stringIndex, request: request) {
                color = previousColor
            }
            if request.unfocusedAlpha < 1, !isFocused(stringIndex, ranges: request.focusedRanges) {
                color *= Float(request.unfocusedAlpha)
            }
            pending.append(PendingGlyph(
                glyph: glyph,
                position: position,
                stringIndex: stringIndex,
                color: color,
                band: band
            ))
        }
        preparedRun.glyphs = pending
        return .run(preparedRun)
    }

    @MainActor
    static func resolve(
        _ pending: PendingGlyph,
        preparedRun: PreparedRun,
        request: GlyphExtractRequest,
        atlas: GlyphAtlas,
        budget: inout GlyphRasterBudget
    ) -> ResolveResult {
        let subpixel = GlyphKey.subpixelBucket(
            forX: request.fragmentFrame.minX + pending.position.x,
            scale: request.scale
        )
        let key = GlyphKey.make(
            font: preparedRun.font,
            glyph: pending.glyph,
            scale: request.scale,
            runMatrix: preparedRun.runMatrix,
            subpixel: subpixel,
            isColor: preparedRun.isColor
        )
        if !atlas.hasEntry(key) {
            guard budget.consume() else {
                return pending.band == .emit ? .needsRasterCap : .skipped
            }
        }
        let slot: GlyphAtlasSlot
        switch atlas.lookup(
            font: preparedRun.font,
            glyph: pending.glyph,
            scale: request.scale,
            runMatrix: preparedRun.runMatrix,
            subpixel: subpixel,
            isColor: preparedRun.isColor
        ) {
        case .hit(let lookedUp):
            slot = lookedUp
        case .oversize:
            return pending.band == .emit ? .failed : .skipped
        case .failed:
            return pending.band == .emit ? .failed : .skipped
        }
        if pending.band == .warm {
            return slot.isEmpty ? .skipped : .warmed
        }
        guard !slot.isEmpty else {
            return .skipped
        }
        return .instance(makeExtractedGlyph(
            pending: pending,
            preparedRun: preparedRun,
            request: request,
            slot: slot
        ))
    }

    static func makeExtractedGlyph(
        pending: PendingGlyph,
        preparedRun: PreparedRun,
        request: GlyphExtractRequest,
        slot: GlyphAtlasSlot
    ) -> ExtractedGlyph {
        let scale = max(request.scale, 0.001)
        let width = CGFloat(slot.width) / scale
        let height = CGFloat(slot.height) / scale
        let originX = request.fragmentFrame.minX + pending.position.x + CGFloat(slot.originX) / scale
        let originY = request.fragmentFrame.minY + requestBaselineY(request) - (CGFloat(slot.originY) / scale + height)
        var color = pending.color
        if preparedRun.isColor {
            let alpha = color.w
            color = SIMD4(alpha, alpha, alpha, alpha)
        }
        let uv = uvRect(for: slot)
        let instance = GlyphInstance(
            origin: SIMD2(Float(originX), Float(originY)),
            size: SIMD2(Float(width), Float(height)),
            uvOrigin: uv.origin,
            uvSize: uv.size,
            color: color,
            atlasPage: slot.pageID
        )
        return ExtractedGlyph(
            instance: instance,
            contentOrigin: CGPoint(
                x: request.fragmentFrame.minX + pending.position.x,
                y: request.fragmentFrame.minY + requestBaselineY(request)
            ),
            stringIndex: pending.stringIndex,
            isColor: preparedRun.isColor,
            matrixHash: preparedRun.matrixHash,
            glyph: pending.glyph
        )
    }

    static func requestBaselineY(_ request: GlyphExtractRequest) -> CGFloat {
        baselineY(baseSize: request.baseSize, scaledSize: request.scaledSize, descent: request.descent)
    }

    // MARK: - Run-level raster fallback (PR 8)

    @MainActor
    static func appendRunFallback(
        _ run: PreparedRun,
        reason: GlyphRunSkipReason,
        request: GlyphExtractRequest,
        baselineY: CGFloat,
        atlas: GlyphAtlas,
        budget: inout GlyphRasterBudget,
        into result: inout GlyphExtractResult
    ) {
        switch makeRunFallback(run, request: request, baselineY: baselineY, atlas: atlas, budget: &budget) {
        case .instance(let extracted):
            result.glyphs.append(extracted)
        case .offscreen:
            break
        case .budgetExhausted:
            result.skips.append(GlyphRunSkip(runIndex: run.runIndex, reason: .rasterCap))
        case .failed:
            result.skips.append(GlyphRunSkip(runIndex: run.runIndex, reason: reason))
        }
    }

    @MainActor
    static func makeRunFallback(
        _ run: PreparedRun,
        request: GlyphExtractRequest,
        baselineY: CGFloat,
        atlas: GlyphAtlas,
        budget: inout GlyphRasterBudget
    ) -> RunFallbackResult {
        guard !run.rawGlyphs.isEmpty else {
            return .offscreen
        }
        // A shadow run whose per-glyph cull produced nothing is fully off-screen — don't spend a
        // raster on it. (Oversize runs keep no `pending`, so they always attempt; they're rare.)
        if run.forcedFallback == .shadow, run.glyphs.isEmpty {
            return .offscreen
        }
        let key = runFallbackKey(run, request: request)
        let slot: GlyphAtlasSlot
        if let cached = atlas.cached(key) {
            slot = cached
        } else {
            guard budget.consume() else {
                return .budgetExhausted
            }
            let input = GlyphRasterizer.RunRasterInput(
                font: run.font,
                glyphs: run.rawGlyphs,
                positions: run.rawPositions,
                runMatrix: run.runMatrix,
                foregroundColor: resolveCGColor(run.foregroundColor, appearance: request.appearance),
                shadow: run.shadow,
                scale: request.scale,
                key: key
            )
            switch GlyphRasterizer.rasterizeRun(input) {
            case .bitmap(let bitmap):
                guard case .hit(let uploaded) = atlas.upload(bitmap, allowingPageSizedTile: true) else {
                    return .failed
                }
                slot = uploaded
            case .oversize, .empty, .failed:
                return .failed
            }
        }
        guard !slot.isEmpty else {
            return .offscreen
        }
        let scale = max(request.scale, 0.001)
        let width = CGFloat(slot.width) / scale
        let height = CGFloat(slot.height) / scale
        let originX = request.fragmentFrame.minX + CGFloat(slot.originX) / scale
        let originY = request.fragmentFrame.minY + baselineY - (CGFloat(slot.originY) / scale + height)
        let quad = CGRect(x: originX, y: originY, width: width, height: height)
        guard quad.intersects(request.emitRect) else {
            return .offscreen
        }
        var alpha: Float = 1
        if request.unfocusedAlpha < 1, !runIsFocused(run.stringIndexRange, ranges: request.focusedRanges) {
            alpha = Float(request.unfocusedAlpha)
        }
        let uv = uvRect(for: slot)
        let instance = GlyphInstance(
            origin: SIMD2(Float(originX), Float(originY)),
            size: SIMD2(Float(width), Float(height)),
            uvOrigin: uv.origin,
            uvSize: uv.size,
            color: SIMD4(alpha, alpha, alpha, alpha),
            atlasPage: slot.pageID
        )
        return .instance(ExtractedGlyph(
            instance: instance,
            contentOrigin: CGPoint(x: request.fragmentFrame.minX, y: request.fragmentFrame.minY + baselineY),
            stringIndex: run.stringIndexRange.lowerBound,
            isColor: true,
            matrixHash: run.matrixHash,
            glyph: 0
        ))
    }

    /// Cache key for a whole-run tile. `UInt8.max` is reserved as the run-fallback discriminator,
    /// so it cannot collide with per-glyph horizontal phase buckets 0...2.
    static func runFallbackKey(_ run: PreparedRun, request: GlyphExtractRequest) -> GlyphKey {
        let pointSize = CTFontGetSize(run.font)
        let pixelSize = UInt16(clamping: Int((pointSize * request.scale * 64).rounded()))
        var hasher = Hasher()
        hasher.combine(run.matrixHash)
        hasher.combine(run.rawGlyphs)
        for position in run.rawPositions {
            hasher.combine(Int((position.x * 4).rounded()))
            hasher.combine(Int((position.y * 4).rounded()))
        }
        hasher.combine(run.runColor.x)
        hasher.combine(run.runColor.y)
        hasher.combine(run.runColor.z)
        hasher.combine(run.runColor.w)
        if let shadow = run.shadow {
            hasher.combine(Int((shadow.shadowBlurRadius * 16).rounded()))
            hasher.combine(Int((shadow.shadowOffset.width * 16).rounded()))
            hasher.combine(Int((shadow.shadowOffset.height * 16).rounded()))
        }
        return GlyphKey(
            fontID: GlyphKey.fontID(for: run.font),
            glyph: 0,
            pixelSize: pixelSize,
            matrixHash: UInt64(truncatingIfNeeded: hasher.finalize()),
            scale: UInt8(clamping: max(1, Int(request.scale.rounded()))),
            subpixel: .max,
            isColor: true
        )
    }

    static func runIsFocused(_ range: Range<Int>, ranges: [NSRange]) -> Bool {
        ranges.contains { NSIntersectionRange($0, NSRange(range)).length > 0 }
    }

    static func resolveCGColor(_ color: NSColor, appearance: NSAppearance?) -> CGColor {
        guard let appearance else {
            return color.cgColor
        }
        var resolved = color.cgColor
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }

    static func uvRect(for slot: GlyphAtlasSlot) -> (origin: SIMD2<Float>, size: SIMD2<Float>) {
        guard let texture = slot.texture, texture.width > 0, texture.height > 0 else {
            return (.zero, .zero)
        }
        let width = Float(texture.width)
        let height = Float(texture.height)
        return (
            SIMD2(Float(slot.x) / width, Float(slot.y) / height),
            SIMD2(Float(slot.width) / width, Float(slot.height) / height)
        )
    }

    static func extraRunMatrix(_ runMatrix: CGAffineTransform, fontMatrix: CGAffineTransform) -> CGAffineTransform {
        if runMatrix.isIdentity || affineComponentsEqual(runMatrix, fontMatrix) {
            return .identity
        }
        return runMatrix.concatenating(fontMatrix.inverted())
    }

    static func affineComponentsEqual(_ lhs: CGAffineTransform, _ rhs: CGAffineTransform) -> Bool {
        lhs.a == rhs.a && lhs.b == rhs.b && lhs.c == rhs.c && lhs.d == rhs.d && lhs.tx == rhs.tx && lhs.ty == rhs.ty
    }

    static func paddedPixelSize(bounds: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        let pixelMinX = floor(bounds.minX * scale)
        let pixelMinY = floor(bounds.minY * scale)
        let pixelMaxX = ceil(bounds.maxX * scale)
        let pixelMaxY = ceil(bounds.maxY * scale)
        let contentWidth = pixelMaxX - pixelMinX
        let contentHeight = pixelMaxY - pixelMinY
        if contentWidth <= 0 || contentHeight <= 0 {
            return (0, 0)
        }
        return (Int(contentWidth) + 2 * padPixels, Int(contentHeight) + 2 * padPixels)
    }

    static func isFocused(_ stringIndex: Int, ranges: [NSRange]) -> Bool {
        ranges.contains { NSLocationInRange(stringIndex, $0) }
    }

    static func resolveColor(attributes: NSDictionary, request: GlyphExtractRequest) -> SIMD4<Float> {
        let color = (attributes[NSAttributedString.Key.foregroundColor] as? NSColor) ?? request.fallbackColor
        return MetalColor.premultiplied(
            color,
            appearance: request.appearance,
            colorSpace: request.colorSpace
        )
    }

    static func previousColor(at stringIndex: Int, request: GlyphExtractRequest) -> SIMD4<Float>? {
        guard !request.previousColors.isEmpty else {
            return nil
        }
        return request.previousColors.min {
            abs($0.stringIndex - stringIndex) < abs($1.stringIndex - stringIndex)
        }?.color
    }
}
