import CoreTransferable
import UniformTypeIdentifiers
import Foundation

/// `Transferable` wrapper for a stored photo file. Lets photo rows
/// expose `.draggable(...)` so the engineer can drag a JPG straight out
/// of SitePhoto into Mail / Files / Notes / any drop target on iPad
/// (or via long-press on iPhone with a recent enough iOS).
///
/// Backed by the photo's original on-disk URL — we hand the file
/// reference over rather than re-encoding in memory, so the dragged
/// payload is exactly what's saved.
struct PhotoTransferable: Transferable {
    let url: URL
    let suggestedName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .jpeg) { item in
            SentTransferredFile(item.url, allowAccessingOriginalFile: false)
        }
        .suggestedFileName { $0.suggestedName }
    }
}
