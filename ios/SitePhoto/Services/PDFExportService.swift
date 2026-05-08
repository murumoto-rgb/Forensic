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
        var mapImage: UIImage?
        if let gps = project.projectGPS {
            let mapW = pageRect.width - 2 * margin
            mapImage = await mapSnapshot(lat: gps.latitude, lon: gps.longitude,
                                         sizePt: CGSize(width: mapW, height: pageRect.height - 130 - margin))
        }

        // ── 2. Render synchronously with UIGraphicsPDFRenderer ─────────────────

        onProgress("Building PDF…")
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let pdfData = renderer.pdfData { ctx in
            ctx.beginPage()
            drawCover(ctx.cgContext, pageRect: pageRect, margin: margin, mapImage: mapImage)

            if let img = planImage, project.floorPlan != nil {
                ctx.beginPage()
                drawPlan(ctx.cgContext, pageRect: pageRect, margin: margin, planImage: img)
            }

            let perPage = 6
            for start in stride(from: 0, to: loaded.count, by: perPage) {
                ctx.beginPage()
                let slice = Array(loaded[start..<min(start + perPage, loaded.count)])
                drawContactSheet(ctx.cgContext, pageRect: pageRect, margin: margin,
                                 photos: slice, rangeStart: start, total: loaded.count)
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

    private func drawCover(_ ctx: CGContext, pageRect: CGRect, margin: CGFloat, mapImage: UIImage?) {
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
        if let img = mapImage {
            img.draw(in: mapRect)
        } else if project.projectGPS == nil {
            drawText("(no GPS recorded for this project)",
                     at: CGPoint(x: margin, y: y + 8),
                     font: .italicSystemFont(ofSize: 9), color: .lightGray)
        }
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
        drawBubbles(ctx, plan: plan, originX: imgX, originY: imgY, scale: scale)
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
        let captionH: CGFloat = 20

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
            let ox = cx + pad + (innerW - dW) / 2
            let oy = cy + pad + (innerH - dH) / 2
            item.image.draw(in: CGRect(x: ox, y: oy, width: dW, height: dH))

            let captionY = cy + cellH - captionH + 4
            drawText("#\(item.photo.sequenceNumber)",
                     at: CGPoint(x: cx + pad, y: captionY),
                     font: .boldSystemFont(ofSize: 9), color: .black)
            drawText(dateFmt.string(from: item.photo.timestamp),
                     at: CGPoint(x: cx + pad + 30, y: captionY + 1),
                     font: .systemFont(ofSize: 7.5), color: UIColor(white: 0.35, alpha: 1))
        }
    }

    // MARK: - Bubble drawing (mirrors PlanViewerView logic)

    private func drawBubbles(_ ctx: CGContext, plan: FloorPlan,
                              originX: CGFloat, originY: CGFloat, scale: CGFloat) {
        let primaryR: CGFloat = 9
        let secR: CGFloat = 6.5
        let firstGap = Double(primaryR + secR) / Double(scale)
        let stepGap  = Double(secR * 2)      / Double(scale)

        var groups: [String: [Photo]] = [:]
        for p in project.photos where p.planPixelX != nil {
            let key = p.groupID?.uuidString ?? p.id.uuidString
            groups[key, default: []].append(p)
        }

        struct M { var photo: Photo; var x, y: Double; var isPrimary: Bool; var bearing: Double? }
        var markers: [M] = []
        for (_, members) in groups {
            let sorted = members.sorted { $0.sequenceNumber < $1.sequenceNumber }
            let lead = sorted.first(where: { $0.isPrimary }) ?? sorted.first!
            markers.append(M(photo: lead, x: lead.planPixelX!, y: lead.planPixelY!,
                              isPrimary: true, bearing: lead.headingDegrees))
            let oppRad = ((lead.headingDegrees ?? 0) + 90) * .pi / 180
            for (i, t) in sorted.filter({ $0.id != lead.id }).enumerated() {
                let d = firstGap + Double(i) * stepGap
                markers.append(M(photo: t,
                                  x: lead.planPixelX! + cos(oppRad) * d,
                                  y: lead.planPixelY! + sin(oppRad) * d,
                                  isPrimary: false, bearing: nil))
            }
        }

        let green = UIColor(red: 0.18, green: 0.80, blue: 0.44, alpha: 1).cgColor
        for m in markers where !m.isPrimary {
            paintBubble(ctx, cx: originX + CGFloat(m.x) * scale,
                        cy: originY + CGFloat(m.y) * scale,
                        radius: secR, seq: m.photo.sequenceNumber, bearing: nil, color: green)
        }
        for m in markers where m.isPrimary {
            paintBubble(ctx, cx: originX + CGFloat(m.x) * scale,
                        cy: originY + CGFloat(m.y) * scale,
                        radius: primaryR, seq: m.photo.sequenceNumber, bearing: m.bearing, color: green)
        }
    }

    private func paintBubble(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, radius: CGFloat,
                              seq: Int, bearing: Double?, color: CGColor) {
        if let b = bearing {
            let ang = CGFloat((b - 90) * .pi / 180)
            let arrowLen = radius * 2.5
            let tipLen   = radius * 3.0
            let baseLen  = radius * 2.0
            ctx.setStrokeColor(color); ctx.setLineWidth(1.2)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: cx, y: cy))
            ctx.addLine(to: CGPoint(x: cx + cos(ang) * arrowLen, y: cy + sin(ang) * arrowLen))
            ctx.strokePath()
            let tipX = cx + cos(ang) * tipLen; let tipY = cy + sin(ang) * tipLen
            let back = ang + .pi
            ctx.setFillColor(color); ctx.beginPath()
            ctx.move(to: CGPoint(x: tipX, y: tipY))
            ctx.addLine(to: CGPoint(x: tipX + cos(back + 0.45) * baseLen,
                                     y: tipY + sin(back + 0.45) * baseLen))
            ctx.addLine(to: CGPoint(x: tipX + cos(back - 0.45) * baseLen,
                                     y: tipY + sin(back - 0.45) * baseLen))
            ctx.closePath(); ctx.fillPath()
        }
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: cx - radius, y: cy - radius,
                                    width: radius * 2, height: radius * 2))

        let numStr = String(seq) as NSString
        var fontSize = radius * 1.4
        var attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: fontSize),
            .foregroundColor: UIColor.white
        ]
        let measured = numStr.size(withAttributes: attrs)
        if measured.width > radius * 1.6 {
            fontSize *= radius * 1.6 / measured.width
            attrs[.font] = UIFont.boldSystemFont(ofSize: fontSize)
        }
        let ts = numStr.size(withAttributes: attrs)
        numStr.draw(at: CGPoint(x: cx - ts.width / 2, y: cy - ts.height / 2), withAttributes: attrs)
    }

    // MARK: - Helpers

    private func mapSnapshot(lat: Double, lon: Double, sizePt: CGSize) async -> UIImage? {
        let opts = MKMapSnapshotter.Options()
        opts.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            latitudinalMeters: 300, longitudinalMeters: 300)
        opts.size = CGSize(width: sizePt.width * 2, height: sizePt.height * 2)
        opts.mapType = .standard
        return try? await MKMapSnapshotter(options: opts).start().image
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

    private func safeFilename(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let s = String(cleaned.prefix(40))
        return s.isEmpty ? "export" : s
    }
}
