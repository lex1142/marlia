import AVFoundation
import Foundation
import ImageIO

/// Reads what batch rename's `[Date]`, `[Time]`, `[Track]`, `[Artist]`, `[Title]` and
/// `[Album]` tokens need (see FileMetadata in BatchRenamePlan.swift).
///
/// - Photos (anything ImageIO opens, HEIC and RAW included): EXIF DateTimeOriginal,
///   falling back to TIFF DateTime.
/// - Audio and video (anything AVFoundation opens): the creation date, the track number
///   (iTunes `trkn` or ID3 `TRCK` "3/12"), artist, title and album.
/// The file's modification date is always filled in as the fallback for [Date]/[Time].
enum FileMetadataReader {

    static func read(_ url: URL, modified: Date?) async -> FileMetadata {
        var metadata = FileMetadata(fallbackDate: modified)
        let target = url.resolvingSymlinksInPath()   // ImageIO/AVFoundation don't follow a final symlink reliably
        if let photoDate = exifDate(target) {
            metadata.captureDate = photoDate
            return metadata
        }
        let asset = AVURLAsset(url: target)
        guard let playable = try? await asset.load(.isReadable), playable else { return metadata }
        if let created = try? await asset.load(.creationDate),
           let date = try? await created.load(.dateValue) {
            metadata.captureDate = date
        }
        let items = (try? await asset.load(.metadata)) ?? []
        for item in items {
            guard let identifier = item.identifier else { continue }
            switch identifier {
            case .iTunesMetadataTrackNumber:
                // 8 bytes: 0, 0, track (UInt16 big-endian), total (UInt16), 0, 0.
                if let data = try? await item.load(.dataValue), data.count >= 4 {
                    let track = Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3])
                    if track > 0 { metadata.track = track }
                } else if let number = try? await item.load(.numberValue) {
                    metadata.track = number.intValue
                }
            case .id3MetadataTrackNumber:
                if let text = try? await item.load(.stringValue),
                   let track = Int(text.split(separator: "/").first ?? "") {
                    metadata.track = track
                }
            default:
                break
            }
        }
        let common = (try? await asset.load(.commonMetadata)) ?? []
        func string(_ key: AVMetadataKey) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: common, withKey: key, keySpace: .common).first else { return nil }
            return try? await item.load(.stringValue)
        }
        metadata.artist = await string(.commonKeyArtist)
        metadata.title = await string(.commonKeyTitle)
        metadata.album = await string(.commonKeyAlbumName)
        return metadata
    }

    /// EXIF dates are local wall-clock time without a zone ("2026:10:03 12:28:04"), so they
    /// are read in the current time zone — the name then shows the time printed on the photo.
    private static func exifDate(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let text = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? exif?[kCGImagePropertyExifDateTimeDigitized] as? String
            ?? tiff?[kCGImagePropertyTIFFDateTime] as? String
        return text.flatMap { exifFormatter.date(from: $0) }
    }

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()
}
