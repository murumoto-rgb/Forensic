import type { Photo } from "@forensic/shared";
import { PhotoThumbnail } from "./PhotoThumbnail";

/**
 * Responsive grid of photo thumbnails. Two columns on phone, more
 * as the viewport widens. Each cell is square (object-cover crops
 * to fit). Clicking a thumbnail invokes `onSelect(index)` so the
 * parent can open the lightbox at that position.
 */
interface Props {
  projectId: string;
  photos: Photo[];
  onSelect: (index: number) => void;
}

export function PhotoGrid({ projectId, photos, onSelect }: Props) {
  if (photos.length === 0) {
    return (
      <div className="rounded border border-dashed border-neutral-800 p-10 text-center text-sm text-neutral-500">
        No photos in this project yet. Capture some on iOS and they will
        appear here within a few seconds.
      </div>
    );
  }

  return (
    <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6">
      {photos.map((photo, idx) => (
        <PhotoThumbnail
          key={photo.id}
          projectId={projectId}
          photoId={photo.id}
          alt={photo.userCaption ?? `Photo ${photo.sequenceNumber}`}
          onClick={() => onSelect(idx)}
        />
      ))}
    </div>
  );
}
