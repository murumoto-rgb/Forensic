import UIKit
import MapKit
import CoreLocation

struct PDFExportService {
    let project: Project
    let store: ProjectStore

    /// Build a PDF that matches the web-app export layout:
    ///   Page 1 – Cover (project info + map)
    ///   Page 2 – Annotated floor plan (if set)
    ///   Pages 3+ – 2-column × 3-row photo contact sheet
    /// Returns a URL to a temp file, or nil on failure.
    func buildPDF(onProgress: @escaping @Sendable (String) -> Void) async -> URL? {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)  // Letter at 72 dpi
        let margin: CGFloat = 36  // 0.5 in

        // ── 1. Pre-load everything asynchronously ──────────────────────────────

        let sortedPhotos = project.photos.sorted { $0.sequenceNumber < $1.sequenceNumber }
        var loaded: [(photo: Photo, image: UIImage)] = []
        for (i, photo) in sortedPhotos.enumerated() {
            onProgress("Loading photo \(i + 1) of \(sortedPhotos.count)…")
            let url = store.imageURL(for: photo, in: project)
            if let data = await store.loadFileBytes(at: url),
               let img = downsample(data: data, maxPixel: 900) {
                loaded.append((photo, img))
            }
        }

        onProgress("Loading floor plan…")
        var planImage: UIImage?
        if let url = store.floorPlanURL(for: project),
           let data = await store.loadFileBytes(at: url),
           let img = UIImage(data: data) {
            planImage = img
        }

        onProgress("Generating map…")
        var mapSnap: MapSnap?
        if let gps = project.projectGPS {
            let mapW = pageRect.width - 2 * margin
            mapSnap = await mapSnapshot(lat: gps.latitude, lon: gps.longitude,
                                        sizePt: CGSize(width: mapW, height: pageRect.height - 130 - margin))
        }

        // ── 2. Render synchronously with UIGraphicsPDFRenderer ─────────────────

        onProgress("Building PDF…")
        let logo = UIImage(named: "BaykalLogo")
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let pdfData = renderer.pdfData { ctx in
            ctx.beginPage()
            drawCover(ctx.cgContext, pageRect: pageRect, margin: margin, mapSnap: mapSnap)
            drawLogo(logo, pageRect: pageRect, margin: margin)

            if let img = planImage, project.floorPlan != nil {
                ctx.beginPage()
                drawPlan(ctx.cgContext, pageRect: pageRect, margin: margin, planImage: img)
                drawLogo(logo, pageRect: pageRect, margin: margin)
            }

            let perPage = 6
            for start in stride(from: 0, to: loaded.count, by: perPage) {
                ctx.beginPage()
                let slice = Array(loaded[start..<min(start + perPage, loaded.count)])
                drawContactSheet(ctx.cgContext, pageRect: pageRect, margin: margin,
                                 photos: slice, rangeStart: start, total: loaded.count)
                drawLogo(logo, pageRect: pageRect, margin: margin)
            }
        }

        let tmpURL = FileManager.default.temporaryDirectory
            .appending(path: "\(safeFilename(project.name)).pdf")
        do {
            try pdfData.write(to: tmpURL, options: .atomic)
            return tmpURL
        } catch {
            return nil
        }
    }

    // MARK: - Cover page

    /// Map snapshot bundled with the GPS-coordinate point so the PDF can put
    /// a star marker exactly on top of the project location.
    private struct MapSnap {
        let image: UIImage
        let starPointInImage: CGPoint
    }

    private func drawCover(_ ctx: CGContext, pageRect: CGRect, margin: CGFloat, mapSnap: MapSnap?) {
        let contentW = pageRect.width - 2 * margin
        var y = margin

        // Project name
        drawText(project.name, at: CGPoint(x: margin, y: y),
                 font: .boldSystemFont(ofSize: 14), color: .black)
        y += 22

        let small = UIFont.systemFont(ofSize: 9)
        let dim = UIColor(white: 0.3, alpha: 1)

        if let gps = project.projectGPS {
            let acc = gps.accuracyFeet.map { String(format: " ±%.1f ft", $0) } ?? ""
            let s = String(format: "GPS: %.5f, %.5f%@", gps.latitude, gps.longitude, acc)
            drawText(s, at: CGPoint(x: margin, y: y), font: small, color: dim)
            y += 13
        }

        if let addr = project.projectAddress {
            y = drawWrapped(addr, x: margin, y: y, maxW: contentW, font: small, color: dim, lineH: 12)
            y += 2
        }

        if let started = project.startedAt {
            let fmt = DateFormatter(); fmt.dateStyle = .medium; fmt.timeStyle = .short
            drawText("Started: \(fmt.string(from: started))",
                     at: CGPoint(x: margin, y: y), font: small, color: dim)
            y += 13
        }

        let n = project.photos.count
        drawText("\(n) photo\(n == 1 ? "" : "s")",
                 at: CGPoint(x: margin, y: y), font: small, color: dim)
        y += 18

        let mapRect = CGRect(x: margin, y: y,
                             width: contentW, height: pageRect.height - y - margin)
        if let snap = mapSnap {
            snap.image.draw(in: mapRect)
            // Convert the star point from snapshot-image space → mapRect space.
            let imgSize = snap.image.size
            let scaleX = mapRect.width / imgSize.width
            let scaleY = mapRect.height / imgSize.height
            let starCenter = CGPoint(
                x: mapRect.minX + snap.starPointInImage.x * scaleX,
                y: mapRect.minY + snap.starPointInImage.y * scaleY
            )
            drawStar(ctx, center: starCenter, outerRadius: 11)
        } else if project.projectGPS == nil {
            drawText("(no GPS recorded for this project)",
                     at: CGPoint(x: margin, y: y + 8),
                     font: .italicSystemFont(ofSize: 9), color: .lightGray)
        }
    }

    /// 5-point star with a white halo so it stays visible on any map style.
    private func drawStar(_ ctx: CGContext, center: CGPoint, outerRadius: CGFloat) {
        let points = 5
        let innerRadius = outerRadius * 0.45
        let path = CGMutablePath()
        for i in 0..<(points * 2) {
            let r = i.isMultiple(of: 2) ? outerRadius : innerRadius
            let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / CGFloat(points)
            let p = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()

        ctx.saveGState()
        // White halo behind the star.
        ctx.addPath(path)
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(3.5)
        ctx.strokePath()
        // Filled star on top.
        ctx.addPath(path)
        ctx.setFillColor(UIColor.systemRed.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // MARK: - Floor plan page

    private func drawPlan(_ ctx: CGContext, pageRect: CGRect, margin: CGFloat, planImage: UIImage) {
        guard let plan = project.floorPlan else { return }
        var y = margin
        drawText("\(project.name) · Floor Plan",
                 at: CGPoint(x: margin, y: y), font: .boldSystemFont(ofSize: 12), color: .black)
        y += 22

        let contentW = pageRect.width - 2 * margin
        let areaH = pageRect.height - y - margin
        let imgSize = planImage.size
        let scale = min(contentW / imgSize.width, areaH / imgSize.height)
        let dispW = imgSize.width * scale
        let dispH = imgSize.height * scale
        let imgX = margin + (contentW - dispW) / 2
        let imgY = y + (areaH - dispH) / 2

        planImage.draw(in: CGRect(x: imgX, y: imgY, width: dispW, height: dispH))
        drawBubbles(ctx, plan: plan, originX: imgX, originY: imgY,
                    scale: scale, imgSize: imgSize)
    }

    // MARK: - Contact sheet page

    private func drawContactSheet(_ ctx: CGContext, pageRect: CGRect, margin: CGFloat,
                                   photos: [(photo: Photo, image: UIImage)],
                                   rangeStart: Int, total: Int) {
        let end = rangeStart + photos.count
        drawText("\(project.name) · Photos \(rangeStart + 1)–\(end) of \(total)",
                 at: CGPoint(x: margin, y: margin),
                 font: .boldSystemFont(ofSize: 11), color: .black)

        let contentW = pageRect.width - 2 * margin
        let headerH: CGFloat = 24
        let cols = 2; let rows = 3
        let cellW = contentW / CGFloat(cols)
        let cellH = (pageRect.height - 2 * margin - headerH) / CGFloat(rows)
        let pad: CGFloat = 4
        // 28pt caption area gives one line for seq + date and a second line
        // for tags. Photos without tags simply leave the second line blank.
        let captionH: CGFloat = 28

        let dateFmt = DateFormatter(); dateFmt.dateStyle = .short; dateFmt.timeStyle = .medium

        for (i, item) in photos.enumerated() {
            let col = i % cols; let row = i / cols
            let cx = margin + CGFloat(col) * cellW
            let cy = margin + headerH + CGFloat(row) * cellH

            let innerW = cellW - 2 * pad
            let innerH = cellH - 2 * pad - captionH
            let aspect = item.image.size.width / item.image.size.height
            let cellAspect = innerW / innerH
            let (dW, dH): (CGFloat, CGFloat) = aspect > cellAspect
                ? (innerW, innerW / aspect) : (innerH * aspect, innerH)
            // Left-align horizontally so portrait photos hug the cell's left
            // edge instead of floating in the middle. Vertical centering is
            // preserved so landscape photos still sit in the middle of the row.
            let ox = cx + pad
            let oy = cy + pad + (innerH - dH) / 2
            item.image.draw(in: CGRect(x: ox, y: oy, width: dW, height: dH))

            let captionY = cy + cellH - captionH + 4
            drawText("#\(item.photo.sequenceNumber)",
                     at: CGPoint(x: cx + pad, y: captionY),
                     font: .boldSystemFont(ofSize: 9), color: .black)
            drawText(dateFmt.string(from: item.photo.timestamp),
                     at: CGPoint(x: cx + pad + 30, y: captionY + 1),
                     font: .systemFont(ofSize: 7.5), color: UIColor(white: 0.35, alpha: 1))

            if !item.photo.tags.isEmpty {
                let tagsLine = item.photo.tags.joined(separator: " · ")
                drawTruncatedText(
                    tagsLine,
                    at: CGPoint(x: cx + pad, y: captionY + 12),
                    maxWidth: cellW - 2 * pad,
                    font: .systemFont(ofSize: 7),
                    color: UIColor(red: 0.42, green: 0.20, blue: 0.55, alpha: 1)
                )
            }
        }
    }

    /// Draw a single line of text, truncating with an ellipsis when it
    /// doesn't fit `maxWidth`. UIKit's `drawText` doesn't truncate by
    /// default, so we measure and shorten manually.
    private func drawTruncatedText(_ text: String, at p: CGPoint,
                                    maxWidth: CGFloat,
                                    font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var s = text
        var size = (s as NSString).size(withAttributes: attrs)
        if size.width <= maxWidth {
            (s as NSString).draw(at: p, withAttributes: attrs)
            return
        }
        let ellipsis = "…"
        while !s.isEmpty {
            s.removeLast()
            let trial = s + ellipsis
            size = (trial as NSString).size(withAttributes: attrs)
            if size.width <= maxWidth {
                (trial as NSString).draw(at: p, withAttributes: attrs)
                return
            }
        }
    }

    // MARK: - Bubble drawing (mirrors PlanViewerView logic)

    /// Read the same bubble scale the plan viewer uses (@AppStorage key) so the
    /// PDF matches whatever the user has dialed in on screen.
    private var bubbleScale: CGFloat {
        let v = UserDefaults.standard.double(forKey: "sitephoto.bubbleScale")
        return v > 0 ? CGFloat(v) : 1.5
    }

    private func drawBubbles(_ ctx: CGContext, plan: FloorPlan,
                              originX: CGFloat, originY: CGFloat,
                              scale: CGFloat, imgSize: CGSize) {
        let bs = bubbleScale

        // Bubbles/arrows are sized in PDF points to occupy the same fraction
        // of the plan as they would on the iPhone 17 Pro Max screen the
        // app is designed against. Without this, PDF pages are bigger than
        // a phone screen, so the plan renders at a higher pt-per-pixel
        // ratio and constant-pt bubbles look proportionally smaller.
        //
        // sizeMultiplier = (PDF scale) / (reference-screen fit). This also
        // makes the cluster-fanning thresholds match: primaryR / scale
        // collapses to primaryR_base / referenceFit, independent of PDF
        // scale, so the same set of photos cluster either way.
        let referenceScreenW: CGFloat = 430   // iPhone 17 Pro Max width
        let referenceScreenH: CGFloat = 800   // approximate plan-area height
        let referenceFit = min(referenceScreenW / imgSize.width,
                                referenceScreenH / imgSize.height)
        let sizeMultiplier = scale / max(referenceFit, 0.0001)

        let primaryR = 18 * bs * sizeMultiplier
        let secR     = 13 * bs * sizeMultiplier
        // Gaps are computed in PDF points first (same as screen), then converted
        // to plan-pixel space so the buildMarkers offsets work in plan coords.
        let firstGapView = primaryR + secR - 2 * bs * sizeMultiplier
        let stepGapView  = secR * 2     - 2 * bs * sizeMultiplier
        let firstGapPlan = Double(firstGapView) / Double(scale)
        let stepGapPlan  = Double(stepGapView)  / Double(scale)
        let arrowLength  = primaryR + 38 * bs * sizeMultiplier
        let arrowBase    = 14 * bs * sizeMultiplier
        let strokeWidth  = 3 * bs * sizeMultiplier

        var groups: [String: [Photo]] = [:]
        for p in project.photos where p.planPixelX != nil {
            let key = p.groupID?.uuidString ?? p.id.uuidString
            groups[key, default: []].append(p)
        }

        struct M { var photo: Photo; var x, y: Double; var isPrimary: Bool; var bearing: Double? }
        var markers: [M] = []
        // Iterate in stable key order — same defence-in-depth as PlanViewerView.
        for key in groups.keys.sorted() {
            let members = groups[key]!
            let sorted = members.sorted { $0.sequenceNumber < $1.sequenceNumber }
            let lead = sorted.first(where: { $0.isPrimary }) ?? sorted.first!
            markers.append(M(photo: lead, x: lead.planPixelX!, y: lead.planPixelY!,
                              isPrimary: true, bearing: lead.headingDegrees))
            let oppRad = ((lead.headingDegrees ?? 0) + 90) * .pi / 180
            for (i, t) in sorted.filter({ $0.id != lead.id }).enumerated() {
                let d = firstGapPlan + Double(i) * stepGapPlan
                markers.append(M(photo: t,
                                  x: lead.planPixelX! + cos(oppRad) * d,
                                  y: lead.planPixelY! + sin(oppRad) * d,
                                  isPrimary: false, bearing: nil))
            }
        }

        // MARK: cluster-fanning (matches PlanViewerView)
        let primaryRplan    = Double(primaryR    / scale)
        let secRplan        = Double(secR        / scale)
        let arrowLengthPlan = Double(arrowLength / scale)
        let fanResult = ClusterFanning.apply(
            markers: markers,
            sortKey: { $0.photo.sequenceNumber },
            groupKey: { ($0.photo.groupID ?? $0.photo.id).uuidString },
            position: { CGPoint(x: $0.x, y: $0.y) },
            isPrimary: { $0.isPrimary },
            setPosition: { m, p in
                M(photo: m.photo, x: p.x, y: p.y,
                  isPrimary: m.isPrimary, bearing: m.bearing)
            },
            collisionRadius: primaryRplan * 2.0,
            minSpacing: primaryRplan * 1.0
        )
        markers = fanResult.adjusted

        let arrowLengthsByID = ClusterFanning.arrowLengthAdjustments(
            markers: markers,
            id: { $0.photo.id },
            position: { CGPoint(x: $0.x, y: $0.y) },
            isPrimary: { $0.isPrimary },
            bearingDegrees: { $0.bearing },
            primaryRadius: primaryRplan,
            secondaryRadius: secRplan,
            defaultArrowLength: arrowLengthPlan
        )
        // MARK: end cluster-fanning

        // MARK: cluster-fanning leader lines
        // Match PlanViewerView's leader-line styling exactly so the
        // dashed connector reads the same on screen and on paper.
        ctx.saveGState()
        ctx.setStrokeColor(UIColor(white: 1, alpha: 0.4).cgColor)
        ctx.setLineWidth(1.0 * sizeMultiplier)
        ctx.setLineDash(phase: 0, lengths: [4 * sizeMultiplier, 3 * sizeMultiplier])
        for line in fanResult.leaderLines {
            ctx.beginPath()
            ctx.move(to: CGPoint(
                x: originX + CGFloat(line.from.x) * scale,
                y: originY + CGFloat(line.from.y) * scale))
            ctx.addLine(to: CGPoint(
                x: originX + CGFloat(line.to.x) * scale,
                y: originY + CGFloat(line.to.y) * scale))
            ctx.strokePath()
        }
        ctx.restoreGState()
        // MARK: end cluster-fanning leader lines

        // SwiftUI Color.green maps to UIColor.systemGreen (#34C759 in light mode).
        let green = UIColor(red: 52.0/255, green: 199.0/255, blue: 89.0/255, alpha: 1).cgColor

        for m in markers where !m.isPrimary {
            paintBubble(ctx, cx: originX + CGFloat(m.x) * scale,
                        cy: originY + CGFloat(m.y) * scale,
                        radius: secR, seq: m.photo.sequenceNumber, bearing: nil,
                        arrowLength: arrowLength, arrowBase: arrowBase,
                        strokeWidth: strokeWidth, color: green)
        }
        for m in markers where m.isPrimary {
            // MARK: cluster-fanning per-marker arrow length
            let myArrowLengthPlan = arrowLengthsByID[m.photo.id] ?? arrowLengthPlan
            let myArrowLength = CGFloat(myArrowLengthPlan) * scale
            // MARK: end cluster-fanning per-marker arrow length
            paintBubble(ctx, cx: originX + CGFloat(m.x) * scale,
                        cy: originY + CGFloat(m.y) * scale,
                        radius: primaryR, seq: m.photo.sequenceNumber, bearing: m.bearing,
                        arrowLength: myArrowLength, arrowBase: arrowBase,
                        strokeWidth: strokeWidth, color: green)
        }
    }

    private func paintBubble(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, radius: CGFloat,
                              seq: Int, bearing: Double?,
                              arrowLength: CGFloat, arrowBase: CGFloat, strokeWidth: CGFloat,
                              color: CGColor) {
        if let b = bearing {
            let ang = CGFloat((b - 90) * .pi / 180)
            let tipX = cx + cos(ang) * arrowLength
            let tipY = cy + sin(ang) * arrowLength
            ctx.saveGState()
            ctx.setStrokeColor(color)
            ctx.setLineWidth(strokeWidth)
            ctx.setLineCap(.round)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: cx, y: cy))
            ctx.addLine(to: CGPoint(x: tipX, y: tipY))
            ctx.strokePath()
            let back = ang + .pi
            ctx.setFillColor(color)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: tipX, y: tipY))
            ctx.addLine(to: CGPoint(x: tipX + cos(back + 0.42) * arrowBase,
                                     y: tipY + sin(back + 0.42) * arrowBase))
            ctx.addLine(to: CGPoint(x: tipX + cos(back - 0.42) * arrowBase,
                                     y: tipY + sin(back - 0.42) * arrowBase))
            ctx.closePath()
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: cx - radius, y: cy - radius,
                                    width: radius * 2, height: radius * 2))

        let numStr = String(seq) as NSString
        var fontSize = radius * 1.1
        var attrs: [NSAttributedString.Key: Any] = [
            .font: roundedBoldFont(size: fontSize),
            .foregroundColor: UIColor.white
        ]
        let maxW = radius * 1.6
        var measured = numStr.size(withAttributes: attrs)
        if measured.width > maxW {
            // Match SwiftUI's minimumScaleFactor(0.4).
            let factor = max(0.4, maxW / measured.width)
            fontSize *= factor
            attrs[.font] = roundedBoldFont(size: fontSize)
            measured = numStr.size(withAttributes: attrs)
        }
        numStr.draw(at: CGPoint(x: cx - measured.width / 2, y: cy - measured.height / 2),
                    withAttributes: attrs)
    }

    private func roundedBoldFont(size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: .bold)
        if let descriptor = base.fontDescriptor.withDesign(.rounded) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }

    // MARK: - Helpers

    private func mapSnapshot(lat: Double, lon: Double, sizePt: CGSize) async -> MapSnap? {
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let opts = MKMapSnapshotter.Options()
        opts.region = MKCoordinateRegion(center: coord,
                                         latitudinalMeters: 300, longitudinalMeters: 300)
        opts.size = CGSize(width: sizePt.width * 2, height: sizePt.height * 2)
        opts.mapType = .standard
        guard let snapshot = try? await MKMapSnapshotter(options: opts).start() else { return nil }
        return MapSnap(image: snapshot.image, starPointInImage: snapshot.point(for: coord))
    }

    private func downsample(data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func drawText(_ text: String, at point: CGPoint, font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (text as NSString).draw(at: point, withAttributes: attrs)
    }

    @discardableResult
    private func drawWrapped(_ text: String, x: CGFloat, y: CGFloat,
                              maxW: CGFloat, font: UIFont, color: UIColor, lineH: CGFloat) -> CGFloat {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: style
        ]
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: maxW, height: 200),
            options: .usesLineFragmentOrigin, attributes: attrs, context: nil)
        (text as NSString).draw(
            in: CGRect(x: x, y: y, width: maxW, height: bounds.height + 2),
            withAttributes: attrs)
        return y + bounds.height + 2
    }

    /// Draws the Baykal Consulting logo in the top-right corner of the page.
    /// Sized to ~75pt wide so it stays out of the way of headers and project
    /// names while still being legible on a printed page.
    private func drawLogo(_ logo: UIImage?, pageRect: CGRect, margin: CGFloat) {
        guard let logo, logo.size.width > 0, logo.size.height > 0 else { return }
        let targetW: CGFloat = 75
        let aspect = logo.size.width / logo.size.height
        let targetH = targetW / aspect
        let rect = CGRect(
            x: pageRect.maxX - margin - targetW,
            y: max(8, margin - targetH / 2 + 4),
            width: targetW, height: targetH
        )
        logo.draw(in: rect)
    }

    private func safeFilename(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let s = String(cleaned.prefix(40))
        return s.isEmpty ? "export" : s
    }
}
