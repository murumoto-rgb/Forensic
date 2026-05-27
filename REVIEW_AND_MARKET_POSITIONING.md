# SitePhoto — App Review & Market Positioning Analysis

## Part 1: App Review — Functionality & Simplification

### Current State

SitePhoto is a two-platform forensic field documentation system:

- **iOS native app** (SwiftUI, ~90 files): Mature, feature-rich with AI-powered photo tagging via Claude, PDF export, multi-floor-plan support, PencilKit markup, bucket categorization, curated 3-level tag vocabulary, batch AI tagging, photo comparison, voice dictation, EXIF stamping, and more.
- **Web MVP** (single 33KB HTML file): Sensor-demo prototype with camera capture, dead-reckoning, floor plan calibration, and JSON/CSV export. Stores base64 images in localStorage.

### A. Functionality Improvements

#### 1. Web MVP Storage Will Fail in Production

The HTML file stores base64-encoded photos in `localStorage`, which caps at ~5-10MB on most browsers. That's roughly 10-20 JPEG photos before silent data loss. For any customer-facing use:

- Migrate to IndexedDB for photo storage (50MB-unlimited depending on browser)
- Add a Service Worker for offline capability
- Or reposition the web version entirely (see Simplification section)

#### 2. Missing Features for Paid Tiers

| Feature                         | iOS Status       | Web Status | Priority for Paid Product |
| ------------------------------- | ---------------- | ---------- | ------------------------- |
| Cloud sync / team collaboration | Missing          | Missing    | Critical                  |
| Offline-first with sync         | Local only       | localStorage only | Critical           |
| User accounts / auth            | Missing          | Missing    | Critical                  |
| Photo annotation / markup       | PencilKit ✓      | Missing    | High                      |
| PDF export                      | Rich, working ✓  | Missing    | High                      |
| Multi-user / permissions        | Missing          | Missing    | High for team plans       |
| Template library (by industry)  | Missing          | Missing    | High for market expansion |
| Integration APIs                | Missing          | Missing    | Medium for construction   |
| Photo watermarking              | Missing          | Missing    | Low                       |

#### 3. AI Tagging — Your Key Differentiator Needs Expansion

The Claude-powered tagging is genuinely novel. Most competitors have zero AI vision capabilities. However:

- The vocabulary is hardcoded to forensic/foundation work. Serving other industries requires pluggable vocabulary modules.
- The `tagSelection` + `aiExtraVocabulary` per-project system is a good foundation, but needs industry-specific seed libraries.
- At ~$0.005/photo, AI cost is manageable but should be bundled into subscription pricing, not passed through as raw API charges.
- Consider on-device pre-screening (Apple Vision / Core ML) to reduce Claude API calls for obvious categorizations.

#### 4. Data Architecture Concerns

- **Photo.swift has 30+ fields** — several are legacy scaffolding (`aiSeverity`, `aiFollowUp`, `aiDescription`) existing only for backward compat. Migrate and drop in a version bump.
- **3 layers of backward-compat decode logic** across Project, Photo, FloorPlan, and Tag. Consider a one-time migration tool to rewrite all manifests to the latest schema, then strip legacy decode paths.
- **ProjectDetailView has 40+ @State variables** — the view is doing too much. Extract into sub-views or a ViewModel.

### B. Simplification Opportunities

#### 1. ProjectDetailView Decomposition

40+ @State properties, 10+ sheet presentations, 8+ filter dimensions, and multiple batch operations in one view. Split into:

- `PhotoFilterModel` (observable) — owns all filter state
- `BatchTaggingCoordinator` — owns AI batch state and progress
- `ImportExportCoordinator` — owns photo import, file import, export flows
- Sub-views for each filter row, batch operation UI, etc.

#### 2. Tag System Complexity

9 types involved in one feature: `Tag`, `TagSuggestion`, `PrimaryTagEntry`, `SecondaryTagEntry`, `ProjectTagSelection`, `ProjectExtraVocabulary`, `ControlledVocabulary`, `AIRulesTemplate`, `InvestigationContext`. The seed-version migration (now at v4) adds more. This works, but new developers will struggle. Needs an architecture diagram.

#### 3. Web App Should Be Purpose-Built

Don't replicate the iOS app in browser. Best options:

- **Option A: "Field Capture Companion"** — just camera + GPS + notes, syncs to iOS for review/export
- **Option B: "Report Viewer Portal"** — clients/attorneys review exported reports without installing the app (highest ROI for a paid product)
- **Option C: Full PWA** — expensive to build and maintain, competes with your own native app

Recommendation: Option B first, then Option A.

#### 4. Remove Dead-Reckoning from Web MVP

Step-counting dead reckoning is clever engineering but unreliable on most devices. Real users will use GPS or manual placement. The DR code adds complexity without delivering value for a paid product.

---

## Part 2: Market Research & Competitive Landscape

### Key Competitors

| App                | Target Market            | Pricing           | Key Differentiator                |
| ------------------ | ------------------------ | ----------------- | --------------------------------- |
| **CompanyCam**     | Construction (general)   | $24/user/mo       | Unlimited photos, integrations    |
| **Procore**        | General contractors      | $375+/mo (platform) | Full project management suite   |
| **Fieldwire**      | Construction field teams | $39/user/mo       | Task management + plans           |
| **Spectora**       | Home inspectors          | $80-$200/mo       | Report templates, scheduling      |
| **HomeGauge**      | Home inspectors          | $70-$120/mo       | Templates, ISN integration        |
| **EZ Inspect**     | Property management      | $20-50/user/mo    | Move-in/move-out templates        |
| **iAuditor**       | Safety inspections       | $24/user/mo       | Checklists, analytics             |
| **Encircle**       | Insurance/restoration    | Custom             | Moisture mapping, Xactimate      |
| **magicplan**      | Real estate/restoration  | $10-$40/mo        | LiDAR floor plan creation         |

### SitePhoto's Genuine Competitive Edges

1. **AI-powered photo analysis** — No competitor offers Claude-level vision analysis that auto-tags, writes captions, flags quality issues, and recommends photo placement in reports.
2. **Calibrated floor plan anchoring** — Most competitors just do GPS pins on a map. Your calibrated floor-plan placement with heading arrows is more precise and valuable for litigation/engineering.
3. **Litigation-ready output** — The PDF export with cover page, contact sheets, metadata tables, and branding is already at the quality level forensic engineers and attorneys expect.

---

## Part 3: Industry-Specific Repackaging Strategy

### Tier 1: "SitePhoto Forensic" — Premium ($49-79/user/mo)

**Target**: Forensic engineers, structural engineers, expert witnesses

**Keep everything you have**, plus add:

- Expert witness report templates (standard cover page formats for depositions)
- Chain-of-custody metadata (who captured, when, tamper-evident hashing)
- Measurement photo auto-detection (already started with `measurementVisible`)
- Photo comparison timeline view (before/during/after for litigation)
- Watermark/Bates numbering for legal proceedings

**Remove/hide**: Generic features that dilute professional positioning. Keep UI austere and technical.

### Tier 2: "SitePhoto Inspect" — Largest Market ($29-49/user/mo)

**Target**: Home inspectors, property condition assessors, move-in/move-out

**Adapt by**:

- Swap tag vocabulary to inspection-specific: Plumbing, Electrical, HVAC, Roofing, Foundation, Exterior, Interior, Appliances
- Add **checklist templates** (room-by-room with required photo counts)
- Add **client portal** (where your web version fits perfectly — email a link, client views report in browser)
- Pre-built PDF templates matching ASHI / InterNACHI standards
- **Deficiency severity ratings** (cosmetic / maintenance / safety / structural)
- **Scheduling** with address auto-fill
- Simplify AI tagging to "auto-categorize" that sorts photos into rooms/systems

**Why**: Inspectors do 200-400 inspections/year, currently pay $80-200/mo. Undercut Spectora/HomeGauge at $29-49 with AI as the differentiator.

### Tier 3: "SitePhoto Construction" — Growth Market ($19-29/user/mo)

**Target**: General contractors, superintendents, project managers

**Adapt by**:

- Replace floor plans with **site plans / progress tracking** (photo overlay showing construction progress over time)
- Add **daily log** generation (auto-create daily report from all photos with AI summaries)
- Add **weather conditions** auto-capture (API integration)
- Add **punch list** generation from AI-tagged deficiency photos
- Add **Procore / Autodesk Build integration** (sync photos to project management)
- Team features: assign photos to subcontractors, approval workflows
- Timelapse from same-location photos over weeks/months

**Why**: CompanyCam has 250K+ users at $24/user/mo. Market is proven and large. Your AI tagging + floor plan anchoring is differentiated.

### Tier 4: "SitePhoto Claims" — Niche, High-Value ($39-59/user/mo)

**Target**: Insurance adjusters, restoration companies, public adjusters

**Adapt by**:

- Add **damage assessment vocabulary** (fire, water, wind, mold, structural)
- Add **Xactimate integration** (dominant insurance estimating tool)
- Add **moisture mapping** overlay on floor plans
- Add **scope of damage** auto-generation from AI analysis
- Add **IICRC S500/S520** compliance checklists (water/mold remediation standards)
- **Before/after comparison** as primary workflow
- Replace forensic vocabulary with claims terminology

**Why**: Insurance restoration is a $210B industry. Encircle charges enterprise pricing. A focused AI-powered alternative at $39-59 is compelling.

---

## Part 4: Go-To-Market Sequence

### Phase 1: Now — Polish Forensic Flagship

- Harden the iOS app for paid distribution
- Add subscription management (RevenueCat or StoreKit 2)
- Build the web report viewer (repurpose the web MVP)
- Price at $79/mo solo, $59/user/mo for teams

### Phase 2: 3-6 Months — Launch Inspect

- Build inspection-specific vocabulary seed
- Add checklist templates and client portal
- Separate App Store listing (or mode within same app)
- Price at $49/mo solo, $39/user/mo for teams

### Phase 3: 6-12 Months — Launch Construction

- Build cloud sync and team management infrastructure
- Add daily log generation and integrations
- Price at $29/mo solo, $19/user/mo for teams

### Phase 4: 12+ Months — Evaluate Claims

- Based on traction in other verticals
- Price at $59/mo solo, $49/user/mo for teams

---

## Part 5: Pricing Architecture

|               | Solo    | Team (3-10)   | Enterprise (10+) |
| ------------- | ------- | ------------- | ----------------- |
| **Forensic**  | $79/mo  | $59/user/mo   | Custom            |
| **Inspect**   | $49/mo  | $39/user/mo   | $29/user/mo       |
| **Construction** | $29/mo | $19/user/mo  | Custom            |
| **Claims**    | $59/mo  | $49/user/mo   | Custom            |

AI tagging included in all tiers (bundled, not metered):

- Solo: 500 photos/mo included
- Team: 2,000 photos/mo included
- Enterprise: 10,000 photos/mo included
- Overage: $0.01/photo

---

## Part 6: Critical Infrastructure Needed

1. **User accounts + subscription management** — RevenueCat or StoreKit 2 for iOS, Stripe for web
2. **Cloud storage** — at minimum for report sharing; full backend for team features
3. **Web report viewer** — the web app's real purpose: "share this report with your client" portal
4. **Template system** — industry-specific checklists, vocabulary seeds, PDF layouts, and branding presets per vertical
5. **API layer** — for integrations (Procore, Xactimate, etc.) and the web portal
