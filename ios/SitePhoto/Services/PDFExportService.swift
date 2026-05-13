import UIKit
import MapKit
import CoreLocation

struct PDFExportService {
    let project: Project
    let store: ProjectStore
    /// User preferences for layout (photos-per-page, section order,
    /// bucket grouping, metadata table). Defaults preserve the previous
    /// fixed layout so callers that don't pass options keep their old
    /// output shape.
    var options: PDFExportOptions = .defaults

    /// Approximate rows that fit on a Letter-page metadata table after
    /// chrome (header line + column header row + footer). Used by the
    /// pre-pass page counter and the renderer alike — keep in sync with
    /// `drawMetadataTable`.
    private static let metadataRowsPerPage: Int = 28

    /// Build a PDF that matches the web-app export layout. Page 1 is
    /// always the cover; remaining sections render in
    /// `options.sectionOrder`, skipping sections whose data is absent
    /// or whose toggle is off. Page numbers are computed in a pre-pass
    /// so the footer "Page N of M" is accurate without re-rendering.
    /// Returns a URL to a temp file, or nil on failure.
    func buildPDF(onProgress: @escaping @Sendable (String) -> Void) async -> URL? {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)  // Letter at 72 dpi
        let margin: CGFloat = 36  // 0.5 in

        // ── 1. Pre-load everything asynchronously ──────────────────────────────

        let sortedPhotos = project.photos.sorted { $0.sequenceNumber < $1.sequenceNumber }
        var loaded: [(photo: Photo, image: UIImage, includeMarkup: Bool)] = []
        for (i, photo) in sortedPhotos.enumerated() {
            onProgress("Loading photo \(i + 1) of \(sortedPhotos.count)…")
            let url = store.imageURL(for: photo, in: project)
            if let data = await store.loadFileBytes(at: url),
               let img = downsample(data: data, maxPixel: 900) {
                // Clean copy first so the engineer can compare side-by-side
                // in the contact sheet (clean cell, then marked cell).
                loaded.append((photo, img, false))
                if photo.markupOverlayFilename != nil {
                    loaded.append((photo, img, true))
                }
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

        // ── 2. Pre-pass: count pages so footers can read "Page N of M" ─────────

        let contactSheetGroups = makeContactSheetGroups(loaded: loaded)
        let totalPages = countPages(
            planAvailable: planImage != nil && project.floorPlan != nil,
            contactSheetGroups: contactSheetGroups,
            metadataPhotoCount: sortedPhotos.count
        )

        // ── 3. Render synchronously with UIGraphicsPDFRenderer ─────────────────

        onProgress("Building PDF…")
        let branding = store.reportBranding
        let logo = store.brandingLogoImage()
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        var pageIndex = 0
        let pdfData = renderer.pdfData { ctx in
            // Cover is always page 1 — locked in the user-chosen
            // section order so it can't be moved or removed.
            ctx.beginPage()
            pageIndex += 1
            drawCover(ctx.cgContext, pageRect: pageRect, margin: margin,
                      mapSnap: mapSnap, branding: branding)
            drawPageChrome(ctx.cgContext, logo: logo, branding: branding,
                            pageRect: pageRect, margin: margin,
                            pageIndex: pageIndex, total: totalPages)

            for section in options.sectionOrder {
                switch section {
                case .plan:
                    guard let img = planImage, project.floorPlan != nil else { continue }
                    ctx.beginPage()
                    pageIndex += 1
                    drawPlan(ctx.cgContext, pageRect: pageRect, margin: margin, planImage: img)
                    drawPageChrome(ctx.cgContext, logo: logo, branding: branding,
                                    pageRect: pageRect, margin: margin,
                                    pageIndex: pageIndex, total: totalPages)
                case .contactSheets:
                    for group in contactSheetGroups {
                        if let header = group.header {
                            ctx.beginPage()
                            pageIndex += 1
                            drawBucketHeader(ctx.cgContext,
                                              name: header.name,
                                              color: header.color,
                                              photoCount: group.items.count,
                                              pageRect: pageRect, margin: margin)
                            drawPageChrome(ctx.cgContext, logo: logo, branding: branding,
                                            pageRect: pageRect, margin: margin,
                                            pageIndex: pageIndex, total: totalPages)
                        }
                        for start in stride(from: 0, to: group.items.count, by: options.perPage) {
                            ctx.beginPage()
                            pageIndex += 1
                            let slice = Array(
                                group.items[start..<min(start + options.perPage, group.items.count)]
                            )
                            drawContactSheet(ctx.cgContext, pageRect: pageRect, margin: margin,
                                             photos: slice,
                                             rangeStart: start,
                                             total: group.items.count,
                                             perPage: options.perPage,
                                             groupName: group.header?.name)
                            drawPageChrome(ctx.cgContext, logo: logo, branding: branding,
                                            pageRect: pageRect, margin: margin,
                                            pageIndex: pageIndex, total: totalPages)
                        }
                    }
                case .metadataTable:
                    guard options.includeMetadataTable, !sortedPhotos.isEmpty else { continue }
                    let pages = Int((Double(sortedPhotos.count)
                                      / Double(Self.metadataRowsPerPage)).rounded(.up))
                    for p in 0..<pages {
                        ctx.beginPage()
                        pageIndex += 1
                        let start = p * Self.metadataRowsPerPage
                        let end = min(start + Self.metadataRowsPerPage, sortedPhotos.count)
                        drawMetadataTable(ctx.cgContext,
                                           photos: Array(sortedPhotos[start..<end]),
                                           pageRect: pageRect, margin: margin,
                                           rangeStart: start,
                                           total: sortedPhotos.count)
                        drawPageChrome(ctx.cgContext, logo: logo, branding: branding,
                                        pageRect: pageRect, margin: margin,
                                        pageIndex: pageIndex, total: totalPages)
                    }
                }
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

    // MARK: - Pre-pass: page counting + bucket grouping

    /// One contiguous run of contact-sheet items, optionally introduced
    /// by a bucket header page. `header == nil` means the run renders
    /// without a divider — used both for the un-grouped path (single
    /// run spanning every loaded photo) and the Unbucketed sentinel
    /// when `groupByBucket` is on.
    private struct ContactSheetGroup {
        let header: (name: String, color: UIColor)?
        let items: [(photo: Photo, image: UIImage, includeMarkup: Bool)]
    }

    private func makeContactSheetGroups(
        loaded: [(photo: Photo, image: UIImage, includeMarkup: Bool)]
    ) -> [ContactSheetGroup] {
        guard options.groupByBucket else {
            return loaded.isEmpty ? [] : [ContactSheetGroup(header: nil, items: loaded)]
        }
        let sortedBuckets = project.buckets.sorted { $0.sortOrder < $1.sortOrder }
        var groups: [ContactSheetGroup] = []
        for bucket in sortedBuckets {
            let items = loaded.filter { $0.photo.bucketID == bucket.id }
            guard !items.isEmpty else { continue }
            let color = uiColor(fromHex: bucket.colorHex) ?? .systemGray
            groups.append(ContactSheetGroup(
                header: (name: bucket.name, color: color),
                items: items
            ))
        }
        let unbucketed = loaded.filter { $0.photo.bucketID == nil }
        if !unbucketed.isEmpty {
            groups.append(ContactSheetGroup(
                header: (name: "Unbucketed", color: .systemGray),
                items: unbucketed
            ))
        }
        return groups
    }

    private func countPages(planAvailable: Bool,
                              contactSheetGroups: [ContactSheetGroup],
                              metadataPhotoCount: Int) -> Int {
        var pages = 1  // cover
        for section in options.sectionOrder {
            switch section {
            case .plan:
                if planAvailable { pages += 1 }
            case .contactSheets:
                for group in contactSheetGroups {
                    if group.header != nil { pages += 1 }
                    pages += Int((Double(group.items.count)
                                   / Double(options.perPage)).rounded(.up))
                }
            case .metadataTable:
                guard options.includeMetadataTable, metadataPhotoCount > 0 else { continue }
                pages += Int((Double(metadataPhotoCount)
                               / Double(Self.metadataRowsPerPage)).rounded(.up))
            }
        }
        return pages
    }

    /// Convenience that draws every "always present" piece of page
    /// chrome — logo, branding footer text, and the new page number.
    /// Keeps each render-site to one line.
    private func drawPageChrome(_ ctx: CGContext,
                                  logo: UIImage?,
                                  branding: ReportBranding,
                                  pageRect: CGRect,
                                  margin: CGFloat,
                                  pageIndex: Int,
                                  total: Int) {
        drawLogo(logo, pageRect: pageRect, margin: margin)
        drawFooter(branding.footerText, pageRect: pageRect, margin: margin)
        drawPageNumber(ctx, pageIndex: pageIndex, total: total,
                        pageRect: pageRect, margin: margin)
    }

    // MARK: - Cover page

    /// Map snapshot bundled with the GPS-coordinate point so the PDF can put
    /// a star marker exactly on top of the project location.
    private struct MapSnap {
        let image: UIImage
        let starPointInImage: CGPoint
    }

    private func drawCover(_ ctx: CGContext, pageRect: CGRect, margin: CGFloat,
                            mapSnap: MapSnap?, branding: ReportBranding) {
        let contentW = pageRect.width - 2 * margin
        var y = margin

        // Branded cover title sits above the project name when set — e.g.
        // firm name on top, project name underneath.
        if let title = branding.coverTitle, !title.isEmpty {
            drawText(title, at: CGPoint(x: margin, y: y),
                     font: .boldSystemFont(ofSize: 16), color: .black)
            y += 24
        }
        if let subtitle = branding.coverSubtitle, !subtitle.isEmpty {
            y = drawWrapped(subtitle, x: margin, y: y, maxW: contentW,
                            font: .systemFont(ofSize: 10),
                            color: UIColor(white: 0.25, alpha: 1),
                            lineH: 13)
            y += 6
        }

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
        // Reserve a bit of bottom space in case a "Photo stacks" legend
        // needs to render below the image. Cheap to reserve even when no
        // stacks exist on this plan — the image just sits a few points
        // higher than before.
        let legendReserve: CGFloat = 80
        let areaH = pageRect.height - y - margin - legendReserve
        let imgSize = planImage.size
        let scale = min(contentW / imgSize.width, areaH / imgSize.height)
        let dispW = imgSize.width * scale
        let dispH = imgSize.height * scale
        let imgX = margin + (contentW - dispW) / 2
        // Top-align the image inside the area so any leftover space sits
        // beneath the image, where the photo-stacks legend goes.
        let imgY = y

        planImage.draw(in: CGRect(x: imgX, y: imgY, width: dispW, height: dispH))
        let stacks = drawBubbles(ctx, plan: plan, originX: imgX, originY: imgY,
                                  scale: scale, imgSize: imgSize)
        if !stacks.isEmpty {
            drawPhotoStacksLegend(ctx, pageRect: pageRect, margin: margin,
                                   stacks: stacks,
                                   topY: imgY + dispH + 12)
        }
    }

    // MARK: - Contact sheet page

    private func drawContactSheet(_ ctx: CGContext, pageRect: CGRect, margin: CGFloat,
                                   photos: [(photo: Photo, image: UIImage, includeMarkup: Bool)],
                                   rangeStart: Int, total: Int,
                                   perPage: Int,
                                   groupName: String?) {
        let end = rangeStart + photos.count
        let prefix = groupName ?? project.name
        drawText("\(prefix) · Photos \(rangeStart + 1)–\(end) of \(total)",
                 at: CGPoint(x: margin, y: margin),
                 font: .boldSystemFont(ofSize: 11), color: .black)

        let contentW = pageRect.width - 2 * margin
        let headerH: CGFloat = 24
        // Grid shape per the user-picked density:
        //   2 → 1 col × 2 rows (tall cells, full-width photos)
        //   4 → 2 cols × 2 rows
        //   6 → 2 cols × 3 rows (legacy default)
        let (cols, rows): (Int, Int)
        switch perPage {
        case 2:  (cols, rows) = (1, 2)
        case 4:  (cols, rows) = (2, 2)
        default: (cols, rows) = (2, 3)
        }
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
            // Composite the PencilKit markup overlay only when this cell
            // is the "marked" copy. Photos with markup land in the contact
            // sheet twice — once clean (this branch off), once marked (on).
            if item.includeMarkup,
               let markupURL = store.markupOverlayURL(for: item.photo, in: project),
               let markupData = try? Data(contentsOf: markupURL),
               let markupImage = UIImage(data: markupData) {
                markupImage.draw(in: CGRect(x: ox, y: oy, width: dW, height: dH))
            }

            let captionY = cy + cellH - captionH + 4
            let seqLabel = item.includeMarkup
                ? "#\(item.photo.sequenceNumber) (marked)"
                : "#\(item.photo.sequenceNumber)"
            drawText(seqLabel,
                     at: CGPoint(x: cx + pad, y: captionY),
                     font: .boldSystemFont(ofSize: 9), color: .black)
            // Marked cells live next to their clean partner which already
            // shows the date — skip it on the marked one so the wider
            // "(marked)" label has room and the row stays uncluttered.
            if !item.includeMarkup {
                drawText(dateFmt.string(from: item.photo.timestamp),
                         at: CGPoint(x: cx + pad + 30, y: captionY + 1),
                         font: .systemFont(ofSize: 7.5),
                         color: UIColor(white: 0.35, alpha: 1))
            }

            // Match the on-screen threshold so the PDF and the app agree on
            // which tags are "active" for this photo.
            let threshold = UserDefaults.standard.double(
                forKey: "sitephoto.tagConfidenceThreshold"
            )
            let visible = item.photo.tags.filter { $0.confidence >= threshold }
            if !visible.isEmpty {
                let tagsLine = visible.map { $0.label }.joined(separator: " · ")
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

    /// Draws bubbles (singletons + stack badges) on the floor plan and
    /// returns the list of multi-member stacks so the caller can render
    /// the legend below the plan image.
    @discardableResult
    private func drawBubbles(_ ctx: CGContext, plan: FloorPlan,
                              originX: CGFloat, originY: CGFloat,
                              scale: CGFloat, imgSize: CGSize) -> [PhotoStack] {
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

        // Per-project digit scale — bubbles grow uniformly when the
        // largest photo number in the project is 3+ digits so the
        // sequence-number text inside stays crisp. Matches the
        // SwiftUI renderers in PlanViewerView / PhotoGroupPickerSheet
        // / LocateSheet.
        let maxSeq = project.photos.map(\.sequenceNumber).max() ?? 0
        let digitScale: CGFloat = {
            switch String(maxSeq).count {
            case 0, 1, 2: return 1.0
            case 3:       return 1.18
            default:      return 1.30
            }
        }()
        let primaryR = 18 * bs * sizeMultiplier * digitScale
        // Secondary radius is no longer used to position tail bubbles
        // (tails were dropped when grouped photos collapsed to a single
        // ringed lead) but the arrow-shortening collision math still
        // wants a "non-primary radius" value to compare against, so keep
        // the constant.
        let secR     = 13 * bs * sizeMultiplier * digitScale
        let arrowLength  = primaryR + 38 * bs * sizeMultiplier
        let arrowBase    = 14 * bs * sizeMultiplier
        let strokeWidth  = 3 * bs * sizeMultiplier

        var groups: [String: [Photo]] = [:]
        for p in project.photos where p.planPixelX != nil {
            let key = p.groupID?.uuidString ?? p.id.uuidString
            groups[key, default: []].append(p)
        }

        struct M {
            var photo: Photo
            var x, y: Double
            var isPrimary: Bool
            var bearing: Double?
            /// Group size — > 1 means the bubble represents a group
            /// lead, in which case the renderer paints a black ring
            /// around the bubble. Tail bubbles are no longer rendered.
            var groupSize: Int
        }
        var markers: [M] = []
        // Iterate in stable key order — same defence-in-depth as PlanViewerView.
        for key in groups.keys.sorted() {
            let members = groups[key]!
            let sorted = members.sorted { $0.sequenceNumber < $1.sequenceNumber }
            let lead = sorted.first(where: { $0.isPrimary }) ?? sorted.first!
            markers.append(M(photo: lead, x: lead.planPixelX!, y: lead.planPixelY!,
                              isPrimary: true, bearing: lead.headingDegrees,
                              groupSize: members.count))
        }

        // MARK: cluster detection — mirrors PlanViewerView's stack-badge
        // approach. No rosette, no leader lines: each overlap cluster
        // renders ONE bubble at the centroid with a "+N" pill badge, and
        // the photo-stacks legend below the plan lists the members.
        let primaryRplan    = Double(primaryR    / scale)
        let secRplan        = Double(secR        / scale)
        let arrowLengthPlan = Double(arrowLength / scale)
        let primaryClusters = ClusterFanning.detectPrimaryClusters(
            markers: markers,
            position: { CGPoint(x: $0.x, y: $0.y) },
            isPrimary: { $0.isPrimary },
            collisionRadius: primaryRplan * 1.0
        )

        // Lead-at-centroid for each cluster, plus the member list so the
        // legend pass can describe the stack.
        struct ClusterDraw {
            let lead: M
            let centroid: CGPoint
            let members: [M]
        }
        let displayedPrimaries: [ClusterDraw] = primaryClusters.map { cluster in
            let lead = cluster.members.min(by: { $0.photo.sequenceNumber < $1.photo.sequenceNumber })
                ?? cluster.members[0]
            return ClusterDraw(lead: lead, centroid: cluster.centroid, members: cluster.members)
        }

        // Arrow shortening — only cluster representatives exist now;
        // there are no tail markers to consider as obstacles.
        let allDisplayedForArrowMath: [M] = displayedPrimaries.map { dp in
            M(photo: dp.lead.photo,
              x: dp.centroid.x, y: dp.centroid.y,
              isPrimary: true, bearing: dp.lead.bearing,
              groupSize: dp.lead.groupSize)
        }
        let arrowLengthsByID = ClusterFanning.arrowLengthAdjustments(
            markers: allDisplayedForArrowMath,
            id: { $0.photo.id },
            position: { CGPoint(x: $0.x, y: $0.y) },
            isPrimary: { $0.isPrimary },
            bearingDegrees: { $0.bearing },
            primaryRadius: primaryRplan,
            secondaryRadius: secRplan,
            defaultArrowLength: arrowLengthPlan
        )

        // Look up the user's plan colour mode once per render. The PDF and
        // the on-screen plan resolve colours through the same helper so the
        // two stay in sync.
        let colorMode = PlanColorMode.stored

        // Cluster representatives. Singletons paint as a normal bubble at
        // the lead's position (centroid == position when N==1). Multi-
        // member clusters paint the same bubble + a "+N" pill badge.
        // Group leads (groupSize > 1) get a black ring painted around
        // the bubble.
        var stacks: [PhotoStack] = []
        for dp in displayedPrimaries {
            let cx = originX + CGFloat(dp.centroid.x) * scale
            let cy = originY + CGFloat(dp.centroid.y) * scale
            let myArrowLengthPlan = arrowLengthsByID[dp.lead.photo.id] ?? arrowLengthPlan
            let myArrowLength = CGFloat(myArrowLengthPlan) * scale
            let color = PlanMarkerColors.cgColor(for: dp.lead.photo,
                                                  mode: colorMode,
                                                  project: project)
            paintBubble(ctx, cx: cx, cy: cy,
                        radius: primaryR,
                        seq: dp.lead.photo.sequenceNumber,
                        bearing: dp.lead.bearing,
                        arrowLength: myArrowLength, arrowBase: arrowBase,
                        strokeWidth: strokeWidth, color: color,
                        groupSize: dp.lead.groupSize)
            if dp.members.count >= 2 {
                paintStackBadge(ctx, cx: cx, cy: cy,
                                radius: primaryR,
                                additionalCount: dp.members.count - 1,
                                sizeMultiplier: sizeMultiplier)
                let seqs = dp.members.map { $0.photo.sequenceNumber }.sorted()
                stacks.append(PhotoStack(memberSeqs: seqs))
            }
        }

        return stacks
    }

    struct PhotoStack {
        let memberSeqs: [Int]
    }

    /// Pill badge in the top-right corner of a stack bubble. Mirrors the
    /// SwiftUI `stackBadge` view in `PlanViewerView` so the PDF and the
    /// on-screen plan match. Drawn AFTER the underlying bubble so the
    /// pill always sits on top.
    private func paintStackBadge(_ ctx: CGContext, cx: CGFloat, cy: CGFloat,
                                  radius: CGFloat, additionalCount: Int,
                                  sizeMultiplier: CGFloat) {
        let badgeFontSize = max(8, floor(radius * 0.5))
        let text = "+\(additionalCount)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: badgeFontSize, weight: .bold),
            .foregroundColor: UIColor.white
        ]
        let textSize = text.size(withAttributes: attrs)
        let padH = max(3, radius * 0.18)
        let padV = max(1, radius * 0.05)
        let badgeW = textSize.width + 2 * padH
        let badgeH = textSize.height + 2 * padV
        // Anchor at the top-right corner of the bubble, similar to a
        // notification count badge.
        let centerOffsetX = radius * 0.25
        let centerOffsetY = -radius * 0.25
        let badgeRect = CGRect(
            x: cx + centerOffsetX - badgeW / 2,
            y: cy + centerOffsetY - badgeH / 2,
            width: badgeW, height: badgeH
        )

        ctx.saveGState()
        let path = CGPath(roundedRect: badgeRect,
                           cornerWidth: badgeH / 2,
                           cornerHeight: badgeH / 2,
                           transform: nil)
        ctx.setFillColor(UIColor(white: 0, alpha: 0.78).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setStrokeColor(UIColor(white: 1, alpha: 0.9).cgColor)
        ctx.setLineWidth(1.0 * sizeMultiplier)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()

        text.draw(at: CGPoint(x: badgeRect.minX + padH,
                               y: badgeRect.minY + padV),
                   withAttributes: attrs)
    }

    /// Draw the "Photo stacks" legend below the floor plan image. Lists
    /// every cluster of size ≥ 2 so the reader of a static PDF can see
    /// the inventory of overlapping photos (no popover available on
    /// paper). Truncates with "+ N more" when the legend would overflow
    /// the available vertical space; engineers reading the truncated
    /// form can re-export with a smaller plan image area.
    private func drawPhotoStacksLegend(_ ctx: CGContext,
                                        pageRect: CGRect,
                                        margin: CGFloat,
                                        stacks: [PhotoStack],
                                        topY: CGFloat) {
        guard !stacks.isEmpty else { return }
        let availableH = pageRect.height - topY - margin
        guard availableH > 18 else { return }

        let headingFont = UIFont.boldSystemFont(ofSize: 10)
        let lineFont = UIFont.systemFont(ofSize: 9)
        let lineHeight: CGFloat = 12
        let headingHeight: CGFloat = 14

        let heading = "Photo stacks (\(stacks.count) on this plan)" as NSString
        heading.draw(at: CGPoint(x: margin, y: topY),
                      withAttributes: [.font: headingFont, .foregroundColor: UIColor.black])
        var y = topY + headingHeight

        let availableLines = max(0, Int((availableH - headingHeight) / lineHeight))
        let visible = stacks.prefix(availableLines)
        for (i, stack) in visible.enumerated() {
            let nums = stack.memberSeqs.map { "#\($0)" }.joined(separator: ", ")
            let line = "Stack \(i + 1): \(nums) (\(stack.memberSeqs.count) photos)" as NSString
            line.draw(at: CGPoint(x: margin + 12, y: y),
                       withAttributes: [.font: lineFont, .foregroundColor: UIColor.darkGray])
            y += lineHeight
        }
        if stacks.count > availableLines {
            let more = "+ \(stacks.count - availableLines) more stack\(stacks.count - availableLines == 1 ? "" : "s")" as NSString
            more.draw(at: CGPoint(x: margin + 12, y: y),
                       withAttributes: [.font: lineFont, .foregroundColor: UIColor.gray])
        }
    }

    private func paintBubble(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, radius: CGFloat,
                              seq: Int, bearing: Double?,
                              arrowLength: CGFloat, arrowBase: CGFloat, strokeWidth: CGFloat,
                              color: CGColor,
                              groupSize: Int = 1) {
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

        // Black band signalling this bubble represents a group of >1
        // photos. Stroke sits on the bubble's perimeter — same
        // strokeBorder geometry the SwiftUI bubble uses on screen.
        if groupSize > 1 {
            let ringWidth = max(2, radius * 0.18)
            ctx.saveGState()
            ctx.setStrokeColor(UIColor.black.cgColor)
            ctx.setLineWidth(ringWidth)
            // Inset by half the line width so the stroke's outer edge
            // sits flush with the bubble's perimeter (CG strokes are
            // centred on the path).
            let inset = ringWidth / 2
            ctx.strokeEllipse(in: CGRect(x: cx - radius + inset,
                                          y: cy - radius + inset,
                                          width: radius * 2 - 2 * inset,
                                          height: radius * 2 - 2 * inset))
            ctx.restoreGState()
        }

        let numStr = String(seq) as NSString
        // Round to an integer point size so glyphs land on exact pixel
        // boundaries during PDF rasterisation — matches the SwiftUI
        // Canvas bubble renderers in PlanViewerView / PhotoGroupPickerSheet
        // / LocateSheet, which also use floor(radius * 1.1).
        var fontSize = max(8, floor(radius * 1.1))
        // SF Pro Text (non-rounded, bold) holds shape at small sizes
        // better than the rounded design — matches the SwiftUI bubble
        // renderers in PlanViewerView et al.
        var attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: UIColor.white
        ]
        let maxW = radius * 1.75
        var measured = numStr.size(withAttributes: attrs)
        if measured.width > maxW {
            // Match SwiftUI's minimumScaleFactor(0.6); also round so
            // the shrunken size stays integer.
            let factor = max(0.6, maxW / measured.width)
            fontSize = max(8, floor(fontSize * factor))
            attrs[.font] = UIFont.systemFont(ofSize: fontSize, weight: .bold)
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

    /// Single-line footer drawn at the bottom margin of every page. Used
    /// for firm phone / website / disclaimer when `ReportBranding.footerText`
    /// is set. No-op when the text is nil or empty so unbranded PDFs still
    /// keep their clean bottom edge.
    private func drawFooter(_ text: String?, pageRect: CGRect, margin: CGFloat) {
        guard let text, !text.isEmpty else { return }
        let font = UIFont.systemFont(ofSize: 8)
        let color = UIColor(white: 0.35, alpha: 1)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        let x = (pageRect.width - size.width) / 2
        let y = pageRect.height - margin / 2 - size.height
        drawText(text, at: CGPoint(x: x, y: y), font: font, color: color)
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

    // MARK: - Bucket header page

    /// Full-page section divider for a single bucket. Reuses the
    /// contact-sheet chrome (margins, logo, footer, page number — drawn
    /// separately by the caller) and adds a coloured band carrying the
    /// bucket name in large type, plus a photo-count subtitle. Visual
    /// intent: feel like a chapter break, not a different document.
    private func drawBucketHeader(_ ctx: CGContext,
                                    name: String,
                                    color: UIColor,
                                    photoCount: Int,
                                    pageRect: CGRect,
                                    margin: CGFloat) {
        let contentW = pageRect.width - 2 * margin
        // Band sits at vertical centre so the page reads as a chapter
        // divider rather than a header floating at the top.
        let bandH: CGFloat = 110
        let bandY = (pageRect.height - bandH) / 2
        let bandRect = CGRect(x: margin, y: bandY,
                               width: contentW, height: bandH)

        ctx.saveGState()
        ctx.setFillColor(color.cgColor)
        ctx.fill(bandRect)
        ctx.restoreGState()

        // Name in large white type — wrap if it overflows.
        let titleFont = UIFont.systemFont(ofSize: 30, weight: .bold)
        _ = drawWrapped(name,
                         x: margin + 18,
                         y: bandY + 22,
                         maxW: contentW - 36,
                         font: titleFont,
                         color: .white,
                         lineH: 34)

        // Photo-count subtitle in a slightly transparent white so it
        // sits visually under the title.
        let subFont = UIFont.systemFont(ofSize: 13, weight: .medium)
        let subtitle = "\(photoCount) photo\(photoCount == 1 ? "" : "s")"
        drawText(subtitle,
                  at: CGPoint(x: margin + 18, y: bandY + bandH - 26),
                  font: subFont,
                  color: UIColor(white: 1, alpha: 0.85))
    }

    // MARK: - Metadata table

    /// Single-page slice of the evidence metadata table. The caller
    /// strides through `photos` in `metadataRowsPerPage` chunks and
    /// hands each chunk here; we draw the title, column headers, then
    /// rows. Columns are tuned for portrait Letter @ 540pt content
    /// width (612 page − 36 × 2 margin).
    private func drawMetadataTable(_ ctx: CGContext,
                                     photos: [Photo],
                                     pageRect: CGRect,
                                     margin: CGFloat,
                                     rangeStart: Int,
                                     total: Int) {
        let end = rangeStart + photos.count
        drawText("\(project.name) · Evidence Metadata · \(rangeStart + 1)–\(end) of \(total)",
                  at: CGPoint(x: margin, y: margin),
                  font: .boldSystemFont(ofSize: 11), color: .black)

        // Column widths sum to 540 (= 612 − 2×36 margin) — keep this
        // invariant when tweaking individual columns.
        let columns: [(title: String, width: CGFloat)] = [
            ("#",       22),
            ("Time",    92),
            ("Bucket",  70),
            ("Lens/Zoom", 80),
            ("Flash",   50),
            ("Source",  60),
            ("Position", 166)
        ]
        let rowH: CGFloat = 22
        let headerRowY = margin + 24
        let headerFont = UIFont.boldSystemFont(ofSize: 9)
        let bodyFont   = UIFont.systemFont(ofSize: 9)
        let mutedColor = UIColor(white: 0.35, alpha: 1)

        // Header row background — subtle gray so the header sticks out.
        ctx.saveGState()
        ctx.setFillColor(UIColor(white: 0.92, alpha: 1).cgColor)
        ctx.fill(CGRect(x: margin, y: headerRowY,
                         width: pageRect.width - 2 * margin, height: rowH))
        ctx.restoreGState()

        var x = margin
        for col in columns {
            drawText(col.title,
                      at: CGPoint(x: x + 4, y: headerRowY + 6),
                      font: headerFont, color: .black)
            x += col.width
        }

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "yyyy-MM-dd HH:mm"

        let bucketByID: [UUID: Bucket] = Dictionary(
            uniqueKeysWithValues: project.buckets.map { ($0.id, $0) }
        )

        for (i, photo) in photos.enumerated() {
            let rowY = headerRowY + rowH + CGFloat(i) * rowH

            // Faint divider line between rows.
            ctx.saveGState()
            ctx.setStrokeColor(UIColor(white: 0.85, alpha: 1).cgColor)
            ctx.setLineWidth(0.4)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: margin, y: rowY))
            ctx.addLine(to: CGPoint(x: pageRect.width - margin, y: rowY))
            ctx.strokePath()
            ctx.restoreGState()

            let bucketName = photo.bucketID.flatMap { bucketByID[$0]?.name } ?? "—"
            let lensZoom: String = {
                let lens = photo.lensName ?? "wide"
                let zoom = String(format: "%g×", photo.cameraZoom)
                return "\(lens) \(zoom)"
            }()
            let flash: String
            switch photo.flashMode {
            case .auto: flash = "auto"
            case .on:   flash = "on"
            case .off:  flash = "off"
            }
            let source: String
            switch photo.positionSource {
            case .manual: source = "manual"
            case .gps:    source = "gps"
            case .none:   source = "—"
            }
            // Photos store no per-photo GPS — that lives on the project
            // (covered on page 1). Use this column for the plan-relative
            // position so the table is still useful when a plan is set.
            let gps: String = {
                if let lx = photo.localXFeet, let ly = photo.localYFeet {
                    return String(format: "x=%.1fft y=%.1fft", lx, ly)
                }
                if let px = photo.planPixelX, let py = photo.planPixelY {
                    return String(format: "plan px=%.0f,%.0f", px, py)
                }
                return "—"
            }()

            let values: [String] = [
                "\(photo.sequenceNumber)",
                timeFmt.string(from: photo.timestamp),
                bucketName,
                lensZoom,
                flash,
                source,
                gps
            ]

            x = margin
            for (idx, col) in columns.enumerated() {
                drawTruncatedText(values[idx],
                                   at: CGPoint(x: x + 4, y: rowY + 6),
                                   maxWidth: col.width - 8,
                                   font: bodyFont, color: mutedColor)
                x += col.width
            }
        }
    }

    // MARK: - Page number footer

    /// "Page N of M" centred just above the branding-footer line. Drawn
    /// on every page including the cover so the reader can always
    /// orient. Sits left of `drawFooter`'s baseline so the two don't
    /// collide when both are present.
    private func drawPageNumber(_ ctx: CGContext,
                                  pageIndex: Int,
                                  total: Int,
                                  pageRect: CGRect,
                                  margin: CGFloat) {
        let text = "Page \(pageIndex) of \(total)"
        let font = UIFont.systemFont(ofSize: 8)
        let color = UIColor(white: 0.35, alpha: 1)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        let x = pageRect.maxX - margin - size.width
        let y = pageRect.height - margin / 2 - size.height
        (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
    }

    /// Parse "#RRGGBB" into a UIColor with explicit RGB components, so
    /// we go through Core Graphics' RGB color space directly rather than
    /// SwiftUI's `Color` (which can introduce surprises around
    /// extended-sRGB on iOS 17+).
    private func uiColor(fromHex hex: String) -> UIColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let rgb = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >>  8) & 0xFF) / 255.0
        let b = CGFloat( rgb        & 0xFF) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }

    private func safeFilename(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let s = String(cleaned.prefix(40))
        return s.isEmpty ? "export" : s
    }
}
