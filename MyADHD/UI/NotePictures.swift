/* ============================================================
   MyADHD/UI/NotePictures.swift — at most three, and small

   `addNoteFiles` / `shrinkImage` / `paintNoteFiles` (app.js:4820-4896),
   `NOTE_FILE_MAX` / `NOTE_FILE_EDGE` / `NOTE_FILE_Q` (4275-4277).

   **Every picture is re-encoded before it is kept, and the numbers are
   not decoration.** Longest side 1024, JPEG at 0.72, stored as a
   `data:image/jpeg;base64,…` string inside the note. On the web that is
   because the whole store lives in `localStorage` and `localStorage` is
   about five megabytes for everything the app owns — one photo straight
   off a camera would spend the lot. Natively the store is a file and the
   ceiling is different, but the three numbers stay: the store is one JSON
   document that is read whole, re-encoded whole and written whole on
   every keystroke, and the widget snapshot is built off the same bytes.
   A 4 MB picture in it is 4 MB re-encoded per letter typed.

   **The scale never goes up.** `min(1, 1024 / longest)` — a small picture
   is kept at its own size rather than blown up to the cap, and a picture
   that is already under it is still re-encoded, so a 30 KB PNG can come
   back a different size in either direction. That is what the web does
   too.

   **Two toasts, and they are not the same toast.** Picking anything at
   all with no room left says so before touching the file; picking more
   than there was room for takes what fits, keeps it, and says so
   afterwards. The third — the quota one — is unreachable in practice
   (`persistOnly` swallows the failure it would come from) and is kept
   anyway, because the alternative is a note that silently cannot be
   written.
   ============================================================ */

import Foundation

#if canImport(UIKit)
import SwiftUI
import UIKit
import PhotosUI
#endif

// MARK: - the arithmetic, which needs no pixels

enum NotePictures {

    static let edge = 1024        // NOTE_FILE_EDGE, app.js:4276
    static let quality = 0.72     // NOTE_FILE_Q, app.js:4277

    /// `Math.min(1, EDGE / Math.max(w, h))`, then
    /// `Math.max(1, Math.round(side * scale))`.
    ///
    /// Written as arithmetic on its own so it can be checked without an
    /// image: `Math.round` is half-up and away from zero for positives,
    /// which is `.toNearestOrAwayFromZero` and not Swift's `rounded()`
    /// default for `.5` on even numbers.
    static func fitted(width: Int, height: Int) -> (width: Int, height: Int) {
        let longest = Double(max(width, height))
        guard longest > 0 else { return (1, 1) }
        let scale = min(1, Double(edge) / longest)
        let w = max(1, Int((Double(width) * scale).rounded(.toNearestOrAwayFromZero)))
        let h = max(1, Int((Double(height) * scale).rounded(.toNearestOrAwayFromZero)))
        return (w, h)
    }

    /// `canvas.toDataURL('image/jpeg', 0.72)`'s prefix. The store drops
    /// any file whose `src` does not start `data:image/` on load
    /// (`normalizeNote`), so this is load-bearing and not cosmetic.
    static let jpegPrefix = "data:image/jpeg;base64,"

    static func dataURL(_ jpeg: Data) -> String {
        jpegPrefix + jpeg.base64EncodedString()
    }
}

#if canImport(UIKit)

// MARK: - turning what was picked into what is kept

extension NotePictures {

    /// One picked image, decoded, scaled and re-encoded. `nil` for
    /// anything that is not an image this device can draw — which the web
    /// skips quietly too (`img.onerror` → the file is passed over).
    static func shrink(_ data: Data) -> String? {
        guard let image = UIImage(data: data) else { return nil }
        let pixels = CGSize(width: image.size.width * image.scale,
                            height: image.size.height * image.scale)
        let size = fitted(width: Int(pixels.width.rounded()),
                          height: Int(pixels.height.rounded()))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true          // JPEG has no alpha; a transparent PNG goes black on the web too
        let target = CGSize(width: size.width, height: size.height)
        let drawn = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }

        guard let jpeg = drawn.jpegData(compressionQuality: quality) else { return nil }
        return dataURL(jpeg)
    }
}

// MARK: - the picker

/// `#note-file-input` — `accept="image/*" multiple`, with the count rule
/// applied afterwards rather than by the picker, because "you picked more
/// than there was room for" is a thing the web says out loud and a picker
/// capped at `room` could never say.
private struct NotePicturePicker: ViewModifier {

    @Binding var isPresented: Bool
    let note: NoteItem
    let store: AppStore
    let toasts: ToastCenter

    @State private var picked: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $isPresented,
                          selection: $picked,
                          maxSelectionCount: NoteItem.fileMax,
                          matching: .images)
            .onChange(of: picked) { _, items in
                guard !items.isEmpty else { return }
                picked = []
                Task { await take(items) }
            }
    }

    @MainActor
    private func take(_ items: [PhotosPickerItem]) async {
        guard let current = store.doc.note(id: note.id) else { return }

        let room = NoteItem.fileMax - current.files.count
        if room <= 0 {
            toasts.show(Copy.Note.Pictures.full(NoteItem.fileMax))
            return
        }

        var kept: [NoteFile] = []
        for item in items.prefix(room) {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            guard let src = NotePictures.shrink(data) else { continue }
            kept.append(NoteFile(id: Normalize.newFileID(), src: src))
        }

        if !kept.isEmpty {
            store.editNote(note.id) { $0.files.append(contentsOf: kept) }
        }
        if items.count > room {
            toasts.show(Copy.Note.Pictures.full(NoteItem.fileMax))
        }
    }
}

extension View {
    func notePictures(isPresented: Binding<Bool>,
                      note: NoteItem,
                      store: AppStore,
                      toasts: ToastCenter) -> some View
    {
        modifier(NotePicturePicker(isPresented: isPresented, note: note,
                                   store: store, toasts: toasts))
    }
}

// MARK: - the thumbnails

/// `.note-files` — 84pt squares, radius 12, each with a 20pt × in the
/// corner. No lightbox and no reorder: a picture in a note is a thing you
/// stuck there, not a gallery.
struct NotePictureStrip: View {

    let note: NoteItem
    let store: AppStore

    var body: some View {
        WrapRow(spacing: 8, lineSpacing: 8) {
            ForEach(note.files, id: \.id) { file in
                thumb(file)
            }
        }
    }

    @ViewBuilder
    private func thumb(_ file: NoteFile) -> some View {
        ZStack(alignment: .topTrailing) {
            if let image = Self.decode(file.src) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(hex: 0x101018, opacity: 0.08))
                    .frame(width: 84, height: 84)
            }

            Button {
                store.editNote(note.id) { $0.files.removeAll { $0.id == file.id } }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(hex: 0xFFFFFF))
                    .frame(width: 20, height: 20)
                    .background(Color(hex: 0x101018, opacity: 0.62), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Copy.Note.Pictures.removeAria)
            .padding(4)
        }
        .frame(width: 84, height: 84)
    }

    /// `data:image/…;base64,…` back to pixels. Anything else was already
    /// dropped by `normalizeNote` on the way in, so a failure here is a
    /// picture this build cannot draw rather than a picture that is not
    /// there.
    static func decode(_ src: String) -> UIImage? {
        guard let comma = src.firstIndex(of: ","), src.hasPrefix("data:image/") else { return nil }
        let payload = String(src[src.index(after: comma)...])
        guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
        else { return nil }
        return UIImage(data: data)
    }
}

#endif
