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

    // Build #6.4.1: per-export snapshots of two UserDefaults values
    // that were previously re-read inside per-page render loops (once
    // per contact-sheet page / per plan draw). The service is
    // constructed fresh for every export, so a stored value can't go
    // stale mid-run — and a value change mid-export would have been a
    // bug anyway (pages disagreeing about the threshold). Both the
    // countPages pre-pass and the render phase read the same snapshot.

    /// Match the on-screen threshold so the PDF and the app agree on
    /// which tags are "active" for a photo.
    private let tagConfidenceThreshold = UserDefaults.standard.double(
        forKey: "sitephoto.tagConfidenceThreshold"
    )

    /// Same bubble scale the plan viewer uses (@AppStorage key) so the
    /// PDF matches whatever the user has dialed in on screen.
    private let bubbleScale: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "sitephoto.bubbleScale")
        return v > 0 ? CGFloat(v) : 1.5
    }()

    /// Shared formatter for contact-sheet cell timestamps — was built
    /// fresh on every page.
    private static let cellDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    /// Shared formatter for metadata-table rows — was built fresh on
    /// every table page.
    private static let metadataTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// Build a PDF that matches the web-app export layout. Page 1 is
    /// always the cover; remaining sections render in
    /// `options.sectionOrder`, skipping sections whose data is absent
    /// or whose toggle is off. Page numbers are computed in a pre-pass
    /// so the footer "Page N of M" is accurate without re-rendering.
    /// A final report never silently omits selected evidence.
    struct IncompleteExportError: LocalizedError {
        let missingItems: [String]
        var errorDescription: String? {
            "Incomplete export — missing \(missingItems.count) item(s): \(missingItems.prefix(12).joined(separator: ", ")). Recover the missing files in Project Health and retry."
        }
    }

    func buildPDF(onProgress: @escaping @Sendable (String) -> Void) async throws -> URL {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)  // Letter at 72 dpi
        let margin: CGFloat = 36  // 0.5 in

        // ── 1. Pre-load everything asynchronously ──────────────────────────────

        let sortedPhotos = project.photos.sorted { $0.sequenceNumber < $1.sequenceNumber }
        // Target ≈ 200 PPI at the cell size the user picked. Anything beyond
        // that bloats the PDF without showing more on the printed page.
        let photoMaxPixel = contactSheetMaxPixel(perPage: options.perPage)
        var loaded: [(photo: Photo, image: UIImage, includeMarkup: Bool, markupImage: UIImage?)] = []
        var missingItems: [String] = []
        let contactPhotos = options.sectionOrder.contains(.contactSheets) ? sortedPhotos : []
        for (i, photo) in contactPhotos.enumerated() {
            onProgress("Loading photo \(i + 1) of \(sortedPhotos.count)…")
            let url = store.imageURL(for: photo, in: project)
            if let data = await store.loadFileBytes(at: url),
               let img = downsample(data: data, maxPixel: photoMaxPixel) {
                // Re-encode as JPEG so UIGraphicsPDFRenderer embeds DCT-encoded
                // bytes instead of raw bitmap — the single biggest factor in
                // PDF file size for photo-heavy exports.
                let compressed = jpegEncoded(img, quality: 0.82)
                // Clean copy first so the engineer can compare side-by-side
                // in the contact sheet (clean cell, then marked cell).
                loaded.append((photo, compressed, false, nil))
                if photo.markupOverlayFilename != nil {
                    var markupImage: UIImage?
                    if let overlay = store.markupOverlayURL(for: photo, in: project) {
                        if let bytes = await store.loadFileBytes(at: overlay),
                           let image = downsample(data: bytes, maxPixel: photoMaxPixel) {
                            markupImage = image
                        } else {
                            missingItems.append("markup for photo #\(photo.sequenceNumber)")
                        }
                    } else {
                        missingItems.append("markup for photo #\(photo.sequenceNumber)")
                    }
                    loaded.append((photo, compressed, true, markupImage))
                }
            } else {
                missingItems.append("photo #\(photo.sequenceNumber)")
            }
        }

        // All selected plans must be available before rendering a final report.
        let selectedPlans = options.sectionOrder.contains(.plan) ? self.selectedPlans : []
        var planImagesByID: [UUID: UIImage] = [:]
        for plan in selectedPlans {
            onProgress("Loading \(plan.label)…")
            guard let url = store.floorPlanURL(for: project, planID: plan.id),
                  let data = await store.loadFileBytes(at: url),
                  // Plan is drawn full-page (~7.5×9.7 in at 200 PPI ≈ 1934 px max).
                  let img = downsample(data: data, maxPixel: 2000) else {
                missingItems.append("plan \(plan.label)")
                continue
            }
            planImagesByID[plan.id] = jpegEncoded(img, quality: 0.85)
        }
        guard missingItems.isEmpty else {
            throw IncompleteExportError(missingItems: missingItems)
        }

        onProgress("Generating map…")
        var mapSnap: MapSnap?
        if let gps = project.projectGPS {
            let mapW = pageRect.width - 2 * margin
            mapSnap = await mapSnapshot(lat: gps.latitude, lon: gps.longitude,
                                        sizePt: CGSize(width: mapW, height: pageRect.height - 130 - margin))
        }

        // ── 2. Pre-pass: count pages so footers can read "Page N of M" ─────────

        let floorPartitions = partitionByFloor(loaded: loaded,
                                                selectedPlans: self.selectedPlans)
        let totalPages = countPages(
            selectedPlans: selectedPlans,
            planImagesByID: planImagesByID,
            floorPartitions: floorPartitions,
            metadataPhotoCount: sortedPhotos.count
        )

        // ── 3. Render synchronously with UIGraphicsPDFRenderer ─────────────────

        onProgress("Building PDF…")
        let branding = store.reportBranding
        if branding.logoStoragePath != nil && (store.brandingLogoURL == nil || branding.logoCachedStoragePath != branding.logoStoragePath) {
            throw IncompleteExportError(missingItems: ["shared report logo — retry branding sync in Settings"])
        }
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
                    // One pass per selected floor — each plan can yield
                    // multiple pages depending on the engineer's choice
                    // of `planMode` (photo only / distress only / both
                    // separate / merged). Floors whose image failed to
                    // load are skipped silently.
                    for plan in selectedPlans {
                        guard let img = planImagesByID[plan.id] else { continue }
                        for content in planPages(for: options.planMode, plan: plan) {
                            ctx.beginPage()
                            pageIndex += 1
                            drawPlan(ctx.cgContext, pageRect: pageRect, margin: margin,
                                     plan: plan, planImage: img, mode: content)
                            drawPageChrome(ctx.cgContext, logo: logo, branding: branding,
                                            pageRect: pageRect, margin: margin,
                                            pageIndex: pageIndex, total: totalPages)
                        }
                    }
                case .contactSheets:
                    // Per-floor first (floors render in floorPartitions
                    // order), then a separator + the "Unlocated photos"
                    // trailing section so every photo is accounted for
                    // in the final PDF.
                    for partition in floorPartitions.placed {
                        renderContactGroupBlock(
                            ctx: ctx, pageRect: pageRect, margin: margin,
                            groups: partition.groups,
                            allItemsInBlock: partition.allItems,
                            blockLabel: partition.floor.label,
                            logo: logo, branding: branding,
                            totalPages: totalPages,
                            pageIndex: &pageIndex
                        )
                    }
                    if !floorPartitions.unplaced.isEmpty {
                        ctx.beginPage()
                        pageIndex += 1
                        drawSeparator(ctx.cgContext, pageRect: pageRect,
                                       margin: margin, title: "Unlocated Photos")
                        drawPageChrome(ctx.cgContext, logo: logo, branding: branding,
                                        pageRect: pageRect, margin: margin,
                                        pageIndex: pageIndex, total: totalPages)
                        renderContactGroupBlock(
                            ctx: ctx, pageRect: pageRect, margin: margin,
                            groups: makeContactSheetGroups(loaded: floorPartitions.unplaced),
                            allItemsInBlock: floorPartitions.unplaced,
                            blockLabel: "Unlocated",
                            logo: logo, branding: branding,
                            totalPages: totalPages,
                            pageIndex: &pageIndex
                        )
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
        try pdfData.write(to: tmpURL, options: .atomic)
        return tmpURL
    }

    // MARK: - Pre-pass: page counting + bucket grouping

    /// One contiguous run of contact-sheet items, optionally introduced
    /// by a bucket header page. `header == nil` means the run renders
    /// without a divider — used both for the un-grouped path (single
    /// run spanning every loaded photo) and the Unbucketed sentinel
    /// when `groupByBucket` is on.
    private struct ContactSheetGroup {
        let header: (name: String, color: UIColor)?
        let items: [(photo: Photo, image: UIImage, includeMarkup: Bool, markupImage: UIImage?)]
    }

    private func makeContactSheetGroups(
        loaded: [(photo: Photo, image: UIImage, includeMarkup: Bool, markupImage: UIImage?)]
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

    // MARK: - Floor partitioning (multi-floor export support)

    /// Plans included in the export, in the project's natural
    /// declaration order. Honors `options.selectedFloorIDs` — `nil`
    /// (the default) means "every floor", an explicit set keeps only
    /// the listed plans.
    private var selectedPlans: [FloorPlan] {
        let allowed = options.selectedFloorIDs
        return project.floorPlans.filter { plan in
            allowed.map { $0.contains(plan.id) } ?? true
        }
    }

    private struct FloorPartition {
        let floor: FloorPlan
        let groups: [ContactSheetGroup]
        let allItems: [(photo: Photo, image: UIImage, includeMarkup: Bool, markupImage: UIImage?)]
    }

    private struct FloorPartitions {
        let placed: [FloorPartition]
        let unplaced: [(photo: Photo, image: UIImage, includeMarkup: Bool, markupImage: UIImage?)]
    }

    /// Slice `loaded` into per-floor partitions + a leftover bucket of
    /// photos not on any selected floor. Each per-floor partition then
    /// re-uses `makeContactSheetGroups` so the optional bucket grouping
    /// still applies inside each floor.
    private func partitionByFloor(
        loaded: [(photo: Photo, image: UIImage, includeMarkup: Bool, markupImage: UIImage?)],
        selectedPlans: [FloorPlan]
    ) -> FloorPartitions {
        let selectedIDs = Set(selectedPlans.map(\.id))
        var byFloor: [UUID: [(photo: Photo, image: UIImage, includeMarkup: Bool, markupImage: UIImage?)]] = [:]
        var unplaced: [(photo: Photo, image: UIImage, includeMarkup: Bool, markupImage: UIImage?)] = []
        for item in loaded {
            if let pid = item.photo.floorPlanID, selectedIDs.contains(pid) {
                byFloor[pid, default: []].append(item)
            } else {
                unplaced.append(item)
            }
        }
        let placed: [FloorPartition] = selectedPlans.compactMap { plan in
            let items = byFloor[plan.id] ?? []
            guard !items.isEmpty else { return nil }
            return FloorPartition(
                floor: plan,
                groups: makeContactSheetGroups(loaded: items),
                allItems: items
            )
        }
        return FloorPartitions(placed: placed, unplaced: unplaced)
    }

    /// Render one block of contact-sheet groups (e.g. all photos on a
    /// floor, or the trailing unlocated batch). Handles the bucket
    /// header pages + each group's slice loop. Mutates `pageIndex` so
    /// the page-number footer stays accurate across blocks.
    private func renderContactGroupBlock(
        ctx: UIGraphicsPDFRendererContext,
        pageRect: CGRect,
        margin: CGFloat,
        groups: [ContactSheetGroup],
        allItemsInBlock: [(photo: Photo, image: UIImage, includeMarkup: Bool, markupImage: UIImage?)],
        blockLabel: String,
        logo: UIImage?,
        branding: ReportBranding,
        totalPages: Int,
        pageIndex: inout Int
    ) {
        for group in groups {
            if let header = group.header {
                ctx.beginPage()
                pageIndex += 1
                drawBucketHeader(ctx.cgContext,
                                  name: "\(blockLabel) · \(header.name)",
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
                let headerName = group.header.map { "\(blockLabel) · \($0.name)" }
                    ?? blockLabel
                drawContactSheet(ctx.cgContext, pageRect: pageRect, margin: margin,
                                 photos: slice,
                                 rangeStart: start,
                                 total: group.items.count,
                                 perPage: options.perPage,
                                 groupName: headerName,
                                 allItemsInBlock: allItemsInBlock)
                drawPageChrome(ctx.cgContext, logo: logo, branding: branding,
                                pageRect: pageRect, margin: margin,
                                pageIndex: pageIndex, total: totalPages)
            }
        }
    }

    private func countPages(selectedPlans: [FloorPlan],
                              planImagesByID: [UUID: UIImage],
                              floorPartitions: FloorPartitions,
                              metadataPhotoCount: Int) -> Int {
        var pages = 1  // cover
        for section in options.sectionOrder {
            switch section {
            case .plan:
                for plan in selectedPlans
                    where planImagesByID[plan.id] != nil {
                    pages += planPages(for: options.planMode, plan: plan).count
                }
            case .contactSheets:
                for partition in floorPartitions.placed {
                    for group in partition.groups {
                        if group.header != nil { pages += 1 }
                        pages += Int((Double(group.items.count)
                                       / Double(options.perPage)).rounded(.up))
                    }
                }
                if !floorPartitions.unplaced.isEmpty {
                    pages += 1  // separator
                    for group in makeContactSheetGroups(loaded: floorPartitions.unplaced) {
                        if group.header != nil { pages += 1 }
                        pages += Int((Double(group.items.count)
                                       / Double(options.perPage)).rounded(.up))
                    }
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

    /// Renders one floor plan page. `mode` controls whether photo
    /// bubbles, distress marks, or both are overlaid. The legend space
    /// below the plan image is reserved unconditionally so the layout
    /// is stable across modes — when there are no photo stacks or
    /// distress marks, the bottom strip simply renders empty.
    private func drawPlan(_ ctx: CGContext,
                           pageRect: CGRect,
                           margin: CGFloat,
                           plan: FloorPlan,
                           planImage: UIImage,
                           mode: PlanPageContent) {
        var y = margin
        let title = "\(project.name) · \(plan.label)\(mode.titleSuffix)"
        drawText(title,
                 at: CGPoint(x: margin, y: y), font: .boldSystemFont(ofSize: 12), color: .black)
        y += 22

        let contentW = pageRect.width - 2 * margin
        let legendReserve: CGFloat = 80
        let areaH = pageRect.height - y - margin - legendReserve
        let imgSize = planImage.size
        let scale = min(contentW / imgSize.width, areaH / imgSize.height)
        let dispW = imgSize.width * scale
        let dispH = imgSize.height * scale
        let imgX = margin + (contentW - dispW) / 2
        let imgY = y

        planImage.draw(in: CGRect(x: imgX, y: imgY, width: dispW, height: dispH))

        var stacks: [PhotoStack] = []
        if mode.includePhotos {
            stacks = drawBubbles(ctx, plan: plan, originX: imgX, originY: imgY,
                                  scale: scale, imgSize: imgSize)
        }
        if mode.includeDistress {
            drawDistress(ctx, plan: plan, originX: imgX, originY: imgY,
                          scale: scale, imgSize: imgSize)
        }
        if !stacks.isEmpty {
            drawPhotoStacksLegend(ctx, pageRect: pageRect, margin: margin,
                                   stacks: stacks,
                                   topY: imgY + dispH + 12)
        }
        if mode.includeDistress, !plan.distress.isEmpty {
            // Distress legend sits below the stacks legend (or right
            // under the image if no stacks were drawn) — counts each
            // distress kind so a reviewer can interpret the marks at
            // a glance without flipping back to the legend page.
            drawDistressLegend(ctx, pageRect: pageRect, margin: margin,
                                marks: plan.distress,
                                topY: imgY + dispH + 12
                                    + (stacks.isEmpty ? 0 : 56))
        }
    }

    /// Per-page recipe — distinct from the user-chosen `PlanRenderMode`
    /// because the "separate pages" mode produces TWO `PlanPageContent`
    /// entries per plan (one for photos, one for distress).
    private struct PlanPageContent {
        let includePhotos: Bool
        let includeDistress: Bool

        var titleSuffix: String {
            switch (includePhotos, includeDistress) {
            case (true, true):    return ""
            case (true, false):   return " · Photos"
            case (false, true):   return " · Distress"
            case (false, false):  return ""
            }
        }
    }

    /// Expand the user's `PlanRenderMode` into the ordered list of
    /// page contents to render for one floor. `.photoOnly` → one photo
    /// page; `.distressOnly` → one distress page; `.merged` → one page
    /// with both; `.photoAndDistressSeparate` → photo page followed by
    /// distress page. Distress pages are skipped when the plan has no
    /// distress marks (so engineers don't get a blank page for empty
    /// plans).
    private func planPages(for mode: PDFExportOptions.PlanRenderMode,
                            plan: FloorPlan) -> [PlanPageContent] {
        let hasDistress = !plan.distress.isEmpty
        switch mode {
        case .photoOnly:
            return [PlanPageContent(includePhotos: true, includeDistress: false)]
        case .distressOnly:
            return hasDistress
                ? [PlanPageContent(includePhotos: false, includeDistress: true)]
                : []
        case .merged:
            return [PlanPageContent(includePhotos: true,
                                     includeDistress: hasDistress)]
        case .photoAndDistressSeparate:
            var pages = [PlanPageContent(includePhotos: true, includeDistress: false)]
            if hasDistress {
                pages.append(PlanPageContent(includePhotos: false, includeDistress: true))
            }
            return pages
        }
    }

    /// Render each distress mark onto the plan in its kind's colour.
    /// Dots are small filled circles with a white halo for visibility
    /// over busy line work; the floor-crack stroke is a smoothed
    /// polyline. Mirrors `DistressViewerView.renderMark`.
    private func drawDistress(_ ctx: CGContext,
                                plan: FloorPlan,
                                originX: CGFloat, originY: CGFloat,
                                scale: CGFloat, imgSize: CGSize) {
        for mark in plan.distress {
            let color = uiColor(for: mark.kind).cgColor
            if mark.kind.isStroke {
                guard mark.points.count >= 2 else { continue }
                ctx.saveGState()
                ctx.setStrokeColor(color)
                ctx.setLineWidth(2.5)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                let first = mark.points[0]
                ctx.move(to: CGPoint(x: originX + CGFloat(first.x) * scale,
                                      y: originY + CGFloat(first.y) * scale))
                for p in mark.points.dropFirst() {
                    ctx.addLine(to: CGPoint(x: originX + CGFloat(p.x) * scale,
                                             y: originY + CGFloat(p.y) * scale))
                }
                ctx.strokePath()
                ctx.restoreGState()
            } else if let pt = mark.points.first {
                let cx = originX + CGFloat(pt.x) * scale
                let cy = originY + CGFloat(pt.y) * scale
                let r: CGFloat = 5
                ctx.saveGState()
                // White halo first so coloured dots stay legible on
                // dark plan backgrounds.
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.fillEllipse(in: CGRect(x: cx - r - 1.2, y: cy - r - 1.2,
                                            width: 2 * (r + 1.2),
                                            height: 2 * (r + 1.2)))
                ctx.setFillColor(color)
                ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r,
                                            width: 2 * r, height: 2 * r))
                ctx.restoreGState()
            }
        }
    }

    /// Compact legend listing the distress kinds present on this plan
    /// with the count of each. Rendered below the image, optionally
    /// stacked under the photo-stacks legend.
    private func drawDistressLegend(_ ctx: CGContext,
                                     pageRect: CGRect,
                                     margin: CGFloat,
                                     marks: [DistressMark],
                                     topY: CGFloat) {
        var counts: [DistressKind: Int] = [:]
        for m in marks { counts[m.kind, default: 0] += 1 }
        drawText("Distress markers on this plan",
                 at: CGPoint(x: margin, y: topY),
                 font: .boldSystemFont(ofSize: 9),
                 color: .black)
        var y = topY + 12
        for kind in DistressKind.allCases {
            guard let n = counts[kind] else { continue }
            ctx.saveGState()
            ctx.setFillColor(uiColor(for: kind).cgColor)
            ctx.fillEllipse(in: CGRect(x: margin, y: y + 1, width: 7, height: 7))
            ctx.restoreGState()
            drawText("\(kind.displayName) — \(n)",
                     at: CGPoint(x: margin + 12, y: y - 1),
                     font: .systemFont(ofSize: 8.5),
                     color: .black)
            y += 12
        }
    }

    private func uiColor(for kind: DistressKind) -> UIColor {
        switch kind {
        case .outOfPlumbDoor:    return UIColor.systemYellow
        case .doorNotLatching:   return UIColor.systemOrange
        case .crackGradeBeam:    return UIColor.systemPurple
        case .crackFloor:        return UIColor.systemRed
        }
    }

    /// Full-page separator with a centred title. Used to introduce the
    /// "Unlocated photos" trailing section so reviewers can tell where
    /// the per-floor contact sheets end.
    private func drawSeparator(_ ctx: CGContext,
                                 pageRect: CGRect,
                                 margin: CGFloat,
                                 title: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 22),
            .foregroundColor: UIColor.black
        ]
        let s = NSAttributedString(string: title, attributes: attrs)
        let bounds = s.boundingRect(
            with: CGSize(width: pageRect.width - 2 * margin,
                          height: pageRect.height),
            options: [.usesLineFragmentOrigin],
            context: nil
        )
        let x = (pageRect.width - bounds.width) / 2
        let y = (pageRect.height - bounds.height) / 2
        s.draw(at: CGPoint(x: x, y: y))
    }

    // MARK: - Contact sheet page

    private func drawContactSheet(_ ctx: CGContext, pageRect: CGRect, margin: CGFloat,
                                   photos: [(photo: Photo, image: UIImage, includeMarkup: Bool, markupImage: UIImage?)],
                                   rangeStart: Int, total: Int,
                                   perPage: Int,
                                   groupName: String?,
                                   allItemsInBlock: [(photo: Photo, image: UIImage, includeMarkup: Bool, markupImage: UIImage?)] = []) {
        let end = rangeStart + photos.count
        let prefix = groupName ?? project.name
        drawText("\(prefix) · Photos \(rangeStart + 1)–\(end) of \(total)",
                 at: CGPoint(x: margin, y: margin),
                 font: .boldSystemFont(ofSize: 11), color: .black)

        let contentW = pageRect.width - 2 * margin
        let headerH: CGFloat = 24
        // Matches the web/server grid for every shared 1–12 preset.
        let (cols, rows) = Self.gridDimensions(perPage: perPage)
        let cellW = contentW / CGFloat(cols)
        let cellH = (pageRect.height - 2 * margin - headerH) / CGFloat(rows)
        let pad: CGFloat = 4

        // Build #6.4.1: both were previously rebuilt / re-read from
        // UserDefaults on every contact-sheet page.
        let dateFmt = Self.cellDateFormatter
        let threshold = tagConfidenceThreshold
        let annotations = options.annotations

        // Pre-compute "Same location as #N" labels for each non-primary
        // photo in a group, scoped to photos that actually live in this
        // contact-sheet block — anchor sequence numbers reference photos
        // the reviewer can find in the same chapter of the PDF.
        let sameLocationLabels: [UUID: String] = sameLocationLookup(in: allItemsInBlock)

        for (i, item) in photos.enumerated() {
            let col = i % cols; let row = i / cols
            let cx = margin + CGFloat(col) * cellW
            let cy = margin + headerH + CGFloat(row) * cellH

            let innerW = cellW - 2 * pad
            // Measure the caption area required by whatever annotations
            // the engineer enabled. The photo image shrinks to give the
            // caption room — that's how we honour "tags must not be
            // obstructed" without forcing a one-size-fits-all layout.
            // A minimum photo height keeps the image readable even on a
            // densely-annotated 6-up page; anything past that floor falls
            // through to the same graceful truncation drawWrapped uses
            // when text exceeds its rect.
            let minPhotoH = max(40, cellH * 0.30)
            let measuredCaptionH = measureCellCaption(
                item: item,
                innerW: innerW,
                options: annotations,
                threshold: threshold,
                sameLocationLabel: sameLocationLabels[item.photo.id]
            )
            let maxCaptionH = cellH - 2 * pad - minPhotoH
            let captionH = max(0, min(measuredCaptionH, maxCaptionH))
            let innerH = cellH - 2 * pad - captionH

            // Photo image.
            let aspect = item.image.size.width / item.image.size.height
            let cellAspect = innerW / max(innerH, 1)
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
            if item.includeMarkup, let markupImage = item.markupImage {
                // Use the verified preloaded overlay, never a second disk read
                // that could silently lose annotation after a map await.
                markupImage.draw(in: CGRect(x: ox, y: oy, width: dW, height: dH))
            }

            drawCellCaption(
                item: item,
                cellX: cx,
                captionTopY: cy + cellH - captionH,
                captionMaxH: captionH,
                cellW: cellW,
                pad: pad,
                options: annotations,
                threshold: threshold,
                dateFmt: dateFmt,
                sameLocationLabel: sameLocationLabels[item.photo.id]
            )
        }
    }

    /// Build a `{photoID: "Same location as #N"}` lookup for every
    /// photo in `items` that belongs to a multi-member group and isn't
    /// itself the primary. The lookup uses the primary's sequence
    /// number — the reviewer can flip back to it in the same block.
    /// Falls back to the smallest sequence number in the group when
    /// no explicit primary is marked.
    private func sameLocationLookup(
        in items: [(photo: Photo, image: UIImage, includeMarkup: Bool, markupImage: UIImage?)]
    ) -> [UUID: String] {
        var result: [UUID: String] = [:]
        var byGroup: [UUID: [Photo]] = [:]
        for item in items {
            guard let gid = item.photo.groupID else { continue }
            byGroup[gid, default: []].append(item.photo)
        }
        for (_, members) in byGroup {
            guard members.count >= 2 else { continue }
            let primary = members.first(where: { $0.isPrimary })
                ?? members.min(by: { $0.sequenceNumber < $1.sequenceNumber })!
            for m in members where m.id != primary.id {
                result[m.id] = "Same location as #\(primary.sequenceNumber)"
            }
        }
        return result
    }

    // MARK: - Contact-sheet cell helpers

    /// Measure the vertical space the cell's caption block will need
    /// given the engineer's enabled annotations. Mirrors the per-field
    /// drawing order in `drawCellCaption` so a measure + draw pair
    /// never disagree.
    private func measureCellCaption(item: (photo: Photo, image: UIImage, includeMarkup: Bool, markupImage: UIImage?),
                                      innerW: CGFloat,
                                      options: PDFExportOptions.AnnotationOptions,
                                      threshold: Double,
                                      sameLocationLabel: String? = nil) -> CGFloat {
        // The seq + date line is always drawn (it identifies the photo).
        // Skip when literally nothing else is enabled? — no, the seq
        // number is what links a contact-sheet entry back to the
        // metadata table / floor plan bubble. Always keep it.
        var h: CGFloat = 12
        if sameLocationLabel != nil { h += 11 }

        if options.includeTags {
            h += measureTagBlock(item.photo.tags,
                                   threshold: threshold,
                                   maxW: innerW)
        }
        if options.includeMeasurement,
           pdfExportNonEmpty(item.photo.aiAnalysis?.measurementVisible) != nil {
            h += 11
        }
        if options.includeCaption,
           let cap = resolvedCaption(item.photo) {
            h += measureWrapped(cap, maxW: innerW, font: .systemFont(ofSize: 8)) + 3
        }
        if options.includeObservation,
           let obs = resolvedObservation(item.photo) {
            h += measureWrapped(obs, maxW: innerW, font: .systemFont(ofSize: 7.5)) + 3
        }
        if options.includeReviewerFlag,
           let flag = pdfExportNonEmpty(item.photo.aiAnalysis?.reviewerFlag) {
            h += measureWrapped("⚠ " + flag,
                                  maxW: innerW,
                                  font: .systemFont(ofSize: 7)) + 3
        }
        return h
    }

    private func drawCellCaption(item: (photo: Photo, image: UIImage, includeMarkup: Bool, markupImage: UIImage?),
                                   cellX: CGFloat,
                                   captionTopY: CGFloat,
                                   captionMaxH: CGFloat,
                                   cellW: CGFloat,
                                   pad: CGFloat,
                                   options: PDFExportOptions.AnnotationOptions,
                                   threshold: Double,
                                   dateFmt: DateFormatter,
                                   sameLocationLabel: String? = nil) {
        let x = cellX + pad
        let maxW = cellW - 2 * pad
        let captionEndY = captionTopY + captionMaxH
        var y = captionTopY + 2

        // Sequence + (optionally) date row. Always drawn — it's the
        // photo's identifier.
        let seqLabel = item.includeMarkup
            ? "#\(item.photo.sequenceNumber) (marked)"
            : "#\(item.photo.sequenceNumber)"
        drawText(seqLabel,
                 at: CGPoint(x: x, y: y),
                 font: .boldSystemFont(ofSize: 9),
                 color: .black)
        // Marked cells live next to their clean partner which already
        // shows the date — skip it on the marked one so the wider
        // "(marked)" label has room and the row stays uncluttered.
        if !item.includeMarkup {
            drawText(dateFmt.string(from: item.photo.timestamp),
                     at: CGPoint(x: x + 30, y: y + 1),
                     font: .systemFont(ofSize: 7.5),
                     color: UIColor(white: 0.35, alpha: 1))
        }
        y += 12

        // Co-location pointer: flags non-primary group members back to
        // the group's lead photo so reviewers can see the shared spot
        // without flipping through the plan.
        if let same = sameLocationLabel, y < captionEndY {
            drawText(same,
                     at: CGPoint(x: x, y: y),
                     font: .italicSystemFont(ofSize: 7.5),
                     color: UIColor(white: 0.3, alpha: 1))
            y += 11
        }

        // Tags are first after the identifier because the user
        // requirement explicitly named them as "must not be
        // obstructed." Everything else competes for the remaining
        // vertical budget in order of declaration below.
        if options.includeTags && y < captionEndY {
            y = drawTagBlock(item.photo.tags,
                              threshold: threshold,
                              x: x, y: y,
                              maxW: maxW,
                              maxY: captionEndY)
        }
        if options.includeMeasurement && y < captionEndY,
           let m = pdfExportNonEmpty(item.photo.aiAnalysis?.measurementVisible) {
            drawText("Measurement: \(m)",
                     at: CGPoint(x: x, y: y),
                     font: .systemFont(ofSize: 7.5),
                     color: .black)
            y += 11
        }
        if options.includeCaption && y < captionEndY,
           let cap = resolvedCaption(item.photo) {
            y = drawWrapped(cap,
                              x: x, y: y, maxW: maxW,
                              font: .systemFont(ofSize: 8),
                              color: .black,
                              lineH: 10)
        }
        if options.includeObservation && y < captionEndY,
           let obs = resolvedObservation(item.photo) {
            y = drawWrapped(obs,
                              x: x, y: y, maxW: maxW,
                              font: .systemFont(ofSize: 7.5),
                              color: UIColor(white: 0.25, alpha: 1),
                              lineH: 9)
        }
        if options.includeReviewerFlag && y < captionEndY,
           let flag = pdfExportNonEmpty(item.photo.aiAnalysis?.reviewerFlag) {
            y = drawWrapped("⚠ " + flag,
                              x: x, y: y, maxW: maxW,
                              font: .systemFont(ofSize: 7),
                              color: UIColor(red: 0.85, green: 0.30, blue: 0.20, alpha: 1),
                              lineH: 9)
        }
    }

    /// Measure the height a primary→secondary tag hierarchy will take
    /// when rendered at `maxW`. Returns 0 when no visible tags exist
    /// so the caller can subtract that line from the layout.
    private func measureTagBlock(_ tags: [Tag],
                                   threshold: Double,
                                   maxW: CGFloat) -> CGFloat {
        let visible = tags.filter { $0.confidence >= threshold }
        let groups = groupTagsByParent(visible)
        if groups.isEmpty { return 0 }
        let primaryFont = UIFont.boldSystemFont(ofSize: 7.5)
        let secondaryFont = UIFont.systemFont(ofSize: 7)
        let indent: CGFloat = 8
        var h: CGFloat = 0
        for group in groups {
            h += measureWrapped(group.primaryLabel,
                                  maxW: maxW,
                                  font: primaryFont) + 1
            if !group.secondaries.isEmpty {
                let joined = group.secondaries
                    .map { $0.label }
                    .joined(separator: ", ")
                h += measureWrapped(joined,
                                      maxW: max(maxW - indent, 20),
                                      font: secondaryFont) + 1
            }
        }
        return h + 2
    }

    /// Draw the tag hierarchy and return the new cursor Y.
    /// Primaries render bold and full-width; secondaries render
    /// regular-weight indented one notch under their primary. Wraps
    /// across multiple lines per group when names exceed `maxW`.
    @discardableResult
    private func drawTagBlock(_ tags: [Tag],
                                threshold: Double,
                                x: CGFloat, y: CGFloat,
                                maxW: CGFloat, maxY: CGFloat) -> CGFloat {
        let visible = tags.filter { $0.confidence >= threshold }
        let groups = groupTagsByParent(visible)
        if groups.isEmpty { return y }

        let primaryFont = UIFont.boldSystemFont(ofSize: 7.5)
        let secondaryFont = UIFont.systemFont(ofSize: 7)
        let primaryColor = UIColor(red: 0.30, green: 0.16, blue: 0.45, alpha: 1)
        let secondaryColor = UIColor(red: 0.42, green: 0.20, blue: 0.55, alpha: 1)
        let indent: CGFloat = 8

        var cursorY = y
        for group in groups {
            if cursorY >= maxY { break }
            cursorY = drawWrapped(group.primaryLabel,
                                    x: x, y: cursorY,
                                    maxW: maxW,
                                    font: primaryFont,
                                    color: primaryColor,
                                    lineH: 9) - 1
            if !group.secondaries.isEmpty && cursorY < maxY {
                let joined = group.secondaries
                    .map { $0.label }
                    .joined(separator: ", ")
                cursorY = drawWrapped(joined,
                                        x: x + indent,
                                        y: cursorY,
                                        maxW: max(maxW - indent, 20),
                                        font: secondaryFont,
                                        color: secondaryColor,
                                        lineH: 8) - 1
            }
        }
        return cursorY + 2
    }

    /// Bucket a flat tag array into a primary → secondaries hierarchy
    /// while preserving the engineer-visible order: primaries appear
    /// in their stored order, and secondaries cluster under their
    /// `parentTag` regardless of where they sat in the flat array.
    /// Secondaries whose `parentTag` doesn't match any explicit
    /// primary get a synthetic primary heading (engineer can still
    /// see them rather than the renderer silently dropping them).
    private func groupTagsByParent(_ tags: [Tag]) -> [TagGroup] {
        var primariesInOrder: [String] = []
        var seenPrimaries: Set<String> = []
        var secondariesByParent: [String: [Tag]] = [:]

        for tag in tags where tag.parentTag == nil {
            if seenPrimaries.insert(tag.label).inserted {
                primariesInOrder.append(tag.label)
            }
        }
        for tag in tags where tag.parentTag != nil {
            guard let parent = tag.parentTag else { continue }
            secondariesByParent[parent, default: []].append(tag)
            if seenPrimaries.insert(parent).inserted {
                primariesInOrder.append(parent)
            }
        }
        return primariesInOrder.map { label in
            TagGroup(primaryLabel: label,
                       secondaries: secondariesByParent[label] ?? [])
        }
    }

    /// Engineer's typed caption wins over the AI draft; missing /
    /// whitespace-only values fall through to the AI version, then
    /// to nil so the caller can skip the row entirely.
    private func resolvedCaption(_ photo: Photo) -> String? {
        pdfExportNonEmpty(photo.userCaption) ?? pdfExportNonEmpty(photo.aiAnalysis?.captionDraft)
    }

    /// Same fallback chain as `resolvedCaption` for the summary
    /// observation field.
    private func resolvedObservation(_ photo: Photo) -> String? {
        pdfExportNonEmpty(photo.userObservation) ?? pdfExportNonEmpty(photo.aiAnalysis?.summaryObservation)
    }

    /// Pre-measurement equivalent of `drawWrapped`. Same NSString /
    /// NSAttributedString boundingRect call so the height returned
    /// here matches the height `drawWrapped` actually consumes (apart
    /// from the +2 tail padding `drawWrapped` adds before returning).
    private func measureWrapped(_ text: String,
                                  maxW: CGFloat,
                                  font: UIFont) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: style
        ]
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: maxW, height: 200),
            options: .usesLineFragmentOrigin,
            attributes: attrs,
            context: nil
        )
        return ceil(bounds.height) + 2
    }

    private struct TagGroup {
        let primaryLabel: String
        let secondaries: [Tag]
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

    // (Build #6.4.1: `bubbleScale` moved to a per-export stored
    // property at the top of the struct — it was re-read from
    // UserDefaults on every `drawBubbles` call.)

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

        // Scope bubbles to photos placed on THIS plan only. Without the
        // floorPlanID filter, multi-floor exports would project every
        // photo's planPixelX/Y (which is plan-specific) onto every
        // plan image, dragging photos from other floors onto the wrong
        // page.
        var groups: [String: [Photo]] = [:]
        for p in project.photos
            where p.planPixelX != nil && p.floorPlanID == plan.id {
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
        // Band-aware effective radius — when the bubble carries a group
        // band, the band's stroke eats the outer slice of the fill, so
        // text sized to the full radius would clip on the band's inner
        // edge. Matches the SwiftUI math in PlanViewerView /
        // PhotoGroupPickerSheet. 3pt floor matches the on-screen path
        // so PDF and screen agree on tiny-bubble rendering.
        let bandWidth = groupSize > 1 ? max(2, radius * 0.18) : 0
        let effR = max(1, radius - bandWidth)
        var fontSize = max(3, floor(effR * 1.1))
        // SF Pro Text (non-rounded, bold) holds shape at small sizes
        // better than the rounded design — matches the SwiftUI bubble
        // renderers in PlanViewerView et al.
        var attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: UIColor.white
        ]
        let maxW = effR * 1.75
        var measured = numStr.size(withAttributes: attrs)
        if measured.width > maxW {
            // Match SwiftUI's minimumScaleFactor(0.6); also round so
            // the shrunken size stays integer.
            let factor = max(0.6, maxW / measured.width)
            fontSize = max(3, floor(fontSize * factor))
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

    /// Largest edge (in pixels) a photo should occupy so it renders at
    /// ~200 PPI in the user-picked contact-sheet density. Page is Letter
    /// with 0.5 in margins → 7.5 × 10 in content area. Cell sizes:
    ///   2-up → 7.5 × 4.83 in  → 1500 px
    ///   4-up → 3.75 × 4.83 in → 1000 px
    ///   6-up → 3.75 × 3.22 in →  750 px
    private func contactSheetMaxPixel(perPage: Int) -> CGFloat {
        switch perPage {
        case 1:  return 2000
        case 2:  return 1500
        case 3:  return 1500
        case 4:  return 1000
        default: return 750
        }
    }

    static func gridDimensions(perPage: Int) -> (Int, Int) {
        let count = min(12, max(1, perPage))
        let columns = count <= 3 ? 1 : count <= 6 ? 2 : 3
        return (columns, (count + columns - 1) / columns)
    }

    /// Re-encode `image` through JPEG so the bytes embedded by
    /// `UIGraphicsPDFRenderer` are DCT-compressed instead of a raw bitmap.
    /// Returns the original image only if encoding fails (which would
    /// require the image to be unrepresentable as JPEG — unlikely for the
    /// downsampled CGImages we feed it).
    private func jpegEncoded(_ image: UIImage, quality: CGFloat) -> UIImage {
        guard let data = image.jpegData(compressionQuality: quality),
              let reloaded = UIImage(data: data) else {
            return image
        }
        return reloaded
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

        let timeFmt = Self.metadataTimeFormatter

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

/// Local helper that returns nil for a missing-or-whitespace-only
/// optional String. `Photo.swift` carries an identical `nonEmpty`
/// extension but marks it `private`, so a free function lives here to
/// keep the PDF service from depending on visibility tweaks elsewhere.
private func pdfExportNonEmpty(_ s: String?) -> String? {
    let trimmed = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
