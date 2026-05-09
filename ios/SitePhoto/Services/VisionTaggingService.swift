import Foundation
import Vision
import ImageIO

/// Runs Apple Vision's built-in image classifier (`VNClassifyImageRequest`)
/// and translates the generic ImageNet-style labels into forensic-friendly
/// tag suggestions.
///
/// Vision's label set is the wrong shape for forensic photos — most
/// observations are things like "tabby cat" or "espresso maker." But it does
/// recognise rooms, building components, materials, and fixtures. We keep
/// only the labels that overlap with forensic vocabulary, mapping them onto
/// our preferred display strings as we go.
enum VisionTaggingService {

    /// Run the classifier on an image file and return up to `maxResults`
    /// forensic-relevant tag suggestions. `nil` is returned only when Vision
    /// itself fails (corrupt image, request error). An empty array means the
    /// classifier ran fine but nothing on its label list mapped to a useful
    /// forensic tag — totally normal for photos of, say, a generic wall.
    ///
    /// Thread-safe; runs the request synchronously on whatever thread it's
    /// called from. Callers are expected to dispatch off the main actor.
    static func tag(imageURL: URL,
                    minConfidence: Float = 0.25,
                    maxResults: Int = 5) -> [TagSuggestion]? {
        guard let cgImage = makeCGImage(from: imageURL) else { return nil }
        return tag(cgImage: cgImage,
                    minConfidence: minConfidence,
                    maxResults: maxResults)
    }

    static func tag(cgImage: CGImage,
                    minConfidence: Float = 0.25,
                    maxResults: Int = 5) -> [TagSuggestion]? {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results else { return [] }

        // Walk the observations in confidence order and emit at most one
        // suggestion per mapped label. Vision often emits "room" + "kitchen"
        // for the same photo; that's fine — both are useful tags.
        let sorted = observations
            .filter { $0.confidence >= minConfidence }
            .sorted { $0.confidence > $1.confidence }

        var seen: Set<String> = []
        var out: [TagSuggestion] = []
        for obs in sorted {
            guard let mapped = forensicLabel(for: obs.identifier) else { continue }
            if !seen.insert(mapped.lowercased()).inserted { continue }
            out.append(TagSuggestion(
                label: mapped,
                confidence: Double(obs.confidence),
                source: .vision
            ))
            if out.count >= maxResults { break }
        }
        return out
    }

    private static func makeCGImage(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // MARK: - Vision-label → forensic-label whitelist
    //
    // Anything not on this list is dropped. The mapping isn't comprehensive —
    // it just catches the labels we've seen Vision emit on real site photos
    // that translate cleanly to forensic vocabulary. Easy to extend.

    private static let labelMap: [String: String] = [
        // Rooms
        "kitchen":            "kitchen",
        "bathroom":           "bathroom",
        "bedroom":            "bedroom",
        "living_room":        "living room",
        "living room":        "living room",
        "dining_room":        "dining room",
        "dining room":        "dining room",
        "garage":             "garage",
        "basement":           "basement",
        "attic":              "attic",
        "hallway":            "hallway",
        "stairs":             "stairs",
        "staircase":          "stairs",
        "office":             "office",
        "closet":             "closet",
        "laundry_room":       "laundry room",
        "laundry":            "laundry room",
        "patio":              "patio",
        "deck":               "deck",
        "porch":              "porch",
        "yard":               "yard",
        "exterior":           "exterior",
        "facade":             "exterior",

        // Surfaces / structural elements
        "ceiling":            "ceiling",
        "wall":               "wall",
        "floor":              "floor",
        "roof":               "roof",
        "window":             "window",
        "door":               "door",
        "doorway":            "door",
        "stairway":           "stairs",
        "fireplace":          "fireplace",
        "chimney":            "chimney",
        "foundation":         "foundation",
        "beam":               "framing",
        "rafter":             "framing",
        "joist":              "framing",
        "column":             "framing",

        // Materials
        "drywall":            "drywall",
        "plaster":            "plaster",
        "concrete":           "concrete",
        "brick":              "brick",
        "tile":               "tile",
        "tiles":              "tile",
        "wood":                "wood",
        "wood_floor":         "hardwood floor",
        "hardwood":           "hardwood floor",
        "carpet":             "carpet",
        "vinyl":              "vinyl",
        "linoleum":           "vinyl",
        "stone":              "stone",
        "metal":              "metal",
        "asphalt":            "asphalt",
        "shingle":            "shingle",
        "shingles":           "shingle",
        "siding":             "siding",
        "insulation":         "insulation",

        // Fixtures / building systems
        "toilet":             "plumbing",
        "sink":               "plumbing",
        "bathtub":            "plumbing",
        "shower":             "plumbing",
        "faucet":             "plumbing",
        "pipe":               "plumbing",
        "pipes":              "plumbing",
        "radiator":           "HVAC",
        "vent":               "HVAC",
        "duct":               "HVAC",
        "furnace":            "HVAC",
        "boiler":             "HVAC",
        "water_heater":       "water heater",
        "thermostat":         "HVAC",
        "fuse_box":           "electrical",
        "circuit_breaker":    "electrical",
        "outlet":             "electrical",
        "switch":             "electrical",
        "wire":               "electrical",
        "wires":              "electrical",
        "conduit":            "electrical",
        "light_fixture":      "electrical",
        "ceiling_fan":        "electrical",
        "appliance":          "appliance",
        "refrigerator":       "appliance",
        "stove":              "appliance",
        "oven":               "appliance",
        "dishwasher":         "appliance",
        "washer":             "appliance",
        "dryer":              "appliance",

        // Damage indicators (Vision rarely emits these but keep them in case)
        "crack":              "crack",
        "stain":              "stain",
        "mold":               "mold",
        "rust":               "rust",
        "rot":                "rot",
        "smoke":              "smoke damage",
        "fire":               "fire damage",
        "water":              "water",
        "puddle":             "water",
        "leak":               "leak"
    ]

    private static func forensicLabel(for visionLabel: String) -> String? {
        // Match case-insensitively, also try with underscores swapped for
        // spaces — Vision sometimes uses either form.
        let key = visionLabel.lowercased()
        if let v = labelMap[key] { return v }
        let alt = key.replacingOccurrences(of: "_", with: " ")
        if let v = labelMap[alt] { return v }
        let alt2 = key.replacingOccurrences(of: " ", with: "_")
        if let v = labelMap[alt2] { return v }
        return nil
    }
}
