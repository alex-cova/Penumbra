import CoreImage
import CoreImage.CIFilterBuiltins
import Metal

/// Metal-backed Core Image pipeline. Filter order is fixed:
/// 1. Geometry: flip → quarter-turns → straighten → redactions → crop (via `TransformEngine`)
/// 2. `CITemperatureAndTint`
/// 3. `CIExposureAdjust`
/// 4. `CIColorControls`
/// 5. `CIHighlightShadowAdjust`
/// 6. Tone curve (`CIToneCurve` / color cube)
/// 7. Selective HSL (color cube)
/// 8. `CIVignette`
/// 9. `CISharpenLuminance` (non-negative only)
/// 10. Preset (`PhotoPreset`)
///
/// RAW decode happens in `PhotoSourceLoader` before this pipeline runs.
/// Identity parameter values skip their filter so an untouched image runs the fewest steps.
/// `CIContext` is documented thread-safe; this type is `Sendable` so previews can hop off
/// the main actor via `Task.detached`.
nonisolated final class PhotoRenderEngine: Sendable {
    /// Small proxies only, so intermediate caching is a net win — consecutive drag ticks reuse the
    /// unchanged head of the filter chain.
    private let previewContext: CIContext
    /// Full-resolution export work, where the memory ceiling matters more than reuse.
    private let exportContext: CIContext

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            previewContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: true])
            exportContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            previewContext = CIContext(options: [.cacheIntermediates: true])
            exportContext = CIContext(options: [.cacheIntermediates: false])
        }
    }

    /// Downscales `source` so its max dimension ≈ `maxDimension` points. Cache the result and feed it
    /// to `renderPreview(proxy:adjustments:)` so a drag does not re-scale the full-resolution source
    /// on every tick.
    func makeProxy(source: CIImage, maxDimension: CGFloat) -> CIImage {
        Self.scaled(source, maxDimension: maxDimension)
    }

    /// Runs the recipe on an already-downscaled proxy from `makeProxy(source:maxDimension:)`.
    func renderPreview(proxy: CIImage, adjustments: EditAdjustment) -> CGImage? {
        render(source: proxy, adjustments: adjustments, colorSpace: proxy.colorSpace, context: previewContext)
    }

    /// Downscales `source` so its max dimension ≈ `maxDimension` points, then runs the full recipe.
    func renderPreview(source: CIImage, adjustments: EditAdjustment, maxDimension: CGFloat) -> CGImage? {
        let scaled = Self.scaled(source, maxDimension: maxDimension)
        return render(source: scaled, adjustments: adjustments, colorSpace: source.colorSpace, context: previewContext)
    }

    /// Identical recipe on the full-resolution source. Used for export only.
    func renderFull(sourceURL: URL, adjustments: EditAdjustment, format: CIFormat = .RGBA8) -> CGImage? {
        guard let source = PhotoSourceLoader.image(at: sourceURL, raw: adjustments.raw, draft: false) else {
            return nil
        }
        return render(
            source: source,
            adjustments: adjustments,
            colorSpace: source.colorSpace,
            format: format,
            context: exportContext
        )
    }

    /// One preset applied to a small thumbnail of the user's image, for the filter carousel.
    func thumbnail(source: CIImage, preset: PhotoPreset, size: CGFloat) -> CGImage? {
        var adjustments = EditAdjustment.identity
        adjustments.preset = preset
        let scaled = Self.scaled(source, maxDimension: size)
        return render(source: scaled, adjustments: adjustments, colorSpace: source.colorSpace, context: previewContext)
    }

    // MARK: - Pipeline

    private func render(
        source: CIImage,
        adjustments: EditAdjustment,
        colorSpace: CGColorSpace?,
        format: CIFormat = .RGBA8,
        context: CIContext
    ) -> CGImage? {
        var image = applyGeometry(source, adjustments: adjustments)
        image = applyTemperatureAndTint(image, adjustments: adjustments)
        image = applyExposure(image, adjustments: adjustments)
        image = applyColorControls(image, adjustments: adjustments)
        image = applyHighlightShadow(image, adjustments: adjustments)
        image = ToneCurveEngine.apply(image, curve: adjustments.toneCurve)
        image = SelectiveHSLEngine.apply(image, hsl: adjustments.selectiveHSL)
        image = applyVignette(image, adjustments: adjustments)
        image = applySharpen(image, adjustments: adjustments)
        image = applyPreset(image, preset: adjustments.preset)

        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }

        let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        if let space {
            return context.createCGImage(image, from: extent, format: format, colorSpace: space)
        }
        return context.createCGImage(image, from: extent)
    }

    private func applyGeometry(_ source: CIImage, adjustments: EditAdjustment) -> CIImage {
        let size = source.extent.size
        let (transform, outputSize) = TransformEngine.orientationTransform(
            flipH: adjustments.flipHorizontal,
            flipV: adjustments.flipVertical,
            quarterTurns: adjustments.rotationQuarterTurns,
            straightenDegrees: adjustments.straightenDegrees,
            size: size
        )

        var image = source
        let identityGeometry =
            !adjustments.flipHorizontal
            && !adjustments.flipVertical
            && adjustments.rotationQuarterTurns == 0
            && adjustments.straightenDegrees == 0

        if !identityGeometry {
            // Shift into the source's own extent origin before transforming, then crop to the
            // computed bounding size so subsequent filters see a finite, origin-zero image.
            let toOrigin = CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY)
            image = source.transformed(by: toOrigin.concatenating(transform))
            image = image.cropped(to: CGRect(origin: .zero, size: outputSize))
        }

        image = applyRedactions(image, regions: adjustments.redactions)

        if let crop = adjustments.crop {
            let pixel = TransformEngine.coreImageRect(forNormalizedUI: crop, in: image.extent)
            if !pixel.isNull, !pixel.isEmpty {
                image = image.cropped(to: pixel)
            }
        }
        return image
    }

    /// Pixelate / blur / block out each region before the crop. Filter strengths are a fraction of
    /// the region's *pixel* size in the image being rendered, so a preview proxy and the
    /// full-resolution export produce the same visual result.
    private func applyRedactions(_ image: CIImage, regions: [RedactionRegion]) -> CIImage {
        guard !regions.isEmpty else { return image }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.isInfinite == false else { return image }

        var result = image
        for region in regions {
            let unit = region.rect.standardized
            guard unit.width > 0.001, unit.height > 0.001 else { continue }
            // UI crop space is top-left origin; Core Image extents are bottom-left.
            let px = CGRect(
                x: extent.minX + unit.minX * extent.width,
                y: extent.minY + (1 - unit.maxY) * extent.height,
                width: unit.width * extent.width,
                height: unit.height * extent.height
            ).integral.intersection(extent)
            guard !px.isNull, px.width >= 1, px.height >= 1 else { continue }

            let minSide = min(px.width, px.height)
            let strength = max(0, min(1, region.strength / 100))
            let patch: CIImage
            switch region.style {
            case .solid:
                patch = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: px)
            case .pixelate:
                let filter = CIFilter.pixellate()
                filter.inputImage = result.clampedToExtent()
                filter.center = CGPoint(x: px.midX, y: px.midY)
                filter.scale = Float(max(2, minSide * (0.03 + strength * 0.22)))
                patch = (filter.outputImage ?? result).cropped(to: px)
            case .blur:
                let filter = CIFilter.gaussianBlur()
                filter.inputImage = result.clampedToExtent()
                filter.radius = Float(max(1, minSide * (0.02 + strength * 0.16)))
                patch = (filter.outputImage ?? result).cropped(to: px)
            }
            result = patch.composited(over: result)
        }
        return result
    }

    private func applyTemperatureAndTint(_ image: CIImage, adjustments: EditAdjustment) -> CIImage {
        guard adjustments.temperature != 0 || adjustments.tint != 0 else { return image }
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: 6500, y: 0)
        filter.targetNeutral = CIVector(
            x: CGFloat(adjustments.targetTemperatureKelvin),
            y: CGFloat(adjustments.targetTintAmount)
        )
        return filter.outputImage ?? image
    }

    private func applyExposure(_ image: CIImage, adjustments: EditAdjustment) -> CIImage {
        guard adjustments.exposure != 0 else { return image }
        let filter = CIFilter.exposureAdjust()
        filter.inputImage = image
        filter.ev = Float(adjustments.exposureEV)
        return filter.outputImage ?? image
    }

    private func applyColorControls(_ image: CIImage, adjustments: EditAdjustment) -> CIImage {
        guard adjustments.contrast != 0 || adjustments.saturation != 0 || adjustments.brightness != 0 else {
            return image
        }
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.contrast = Float(adjustments.contrastAmount)
        filter.saturation = Float(adjustments.saturationAmount)
        filter.brightness = Float(adjustments.brightnessAmount)
        return filter.outputImage ?? image
    }

    private func applyHighlightShadow(_ image: CIImage, adjustments: EditAdjustment) -> CIImage {
        guard adjustments.highlights != 0 || adjustments.shadows != 0 else { return image }
        let filter = CIFilter.highlightShadowAdjust()
        filter.inputImage = image
        filter.highlightAmount = Float(adjustments.highlightAmount)
        filter.shadowAmount = Float(adjustments.shadowAmount)
        return filter.outputImage ?? image
    }

    private func applyVignette(_ image: CIImage, adjustments: EditAdjustment) -> CIImage {
        guard adjustments.vignetteIntensity > 0 else { return image }
        let filter = CIFilter.vignette()
        filter.inputImage = image
        filter.intensity = Float(adjustments.vignetteIntensity)
        filter.radius = 1.2
        return filter.outputImage ?? image
    }

    private func applySharpen(_ image: CIImage, adjustments: EditAdjustment) -> CIImage {
        guard adjustments.sharpenAmount > 0 else { return image }
        let filter = CIFilter.sharpenLuminance()
        filter.inputImage = image
        filter.sharpness = Float(adjustments.sharpenAmount)
        return filter.outputImage ?? image
    }

    private func applyPreset(_ image: CIImage, preset: PhotoPreset) -> CIImage {
        switch preset {
        case .original:
            return image
        case .vivid:
            let vibrance = CIFilter.vibrance()
            vibrance.inputImage = image
            vibrance.amount = 0.6
            let vivid = vibrance.outputImage ?? image
            let controls = CIFilter.colorControls()
            controls.inputImage = vivid
            controls.saturation = 1.15
            return controls.outputImage ?? vivid
        case .noir:
            return photoEffect(image, named: "CIPhotoEffectNoir")
        case .chrome:
            return photoEffect(image, named: "CIPhotoEffectChrome")
        case .fade:
            return photoEffect(image, named: "CIPhotoEffectFade")
        case .silvertone:
            return photoEffect(image, named: "CIPhotoEffectTonal")
        case .warmVintage:
            let instant = photoEffect(image, named: "CIPhotoEffectInstant")
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = instant
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 6100, y: 0)
            return warm.outputImage ?? instant
        }
    }

    private func photoEffect(_ image: CIImage, named name: String) -> CIImage {
        guard let filter = CIFilter(name: name) else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage ?? image
    }

    private static func scaled(_ source: CIImage, maxDimension: CGFloat) -> CIImage {
        let extent = source.extent
        let longest = max(extent.width, extent.height)
        guard longest > maxDimension, longest > 0, maxDimension > 0 else { return source }
        let scale = maxDimension / longest
        return source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
}
