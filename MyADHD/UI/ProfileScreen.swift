/* ============================================================
   MyADHD/UI/ProfileScreen.swift — a name and a face, on this device

   `paintProfile` / `buildAvatarPicker` / `avatarFace` (app.js:3875-3942),
   `showProfileScreen` (app.js:4092-4095), the name input's handler
   (app.js:5569-5573), `#screen-profile` (app.html:855-887),
   inventory §1.14.

   **Deliberately small.** A name to be greeted by and a face to
   recognise the tab by. What ends an account lives beside the account,
   on the settings screen, and not here.

   **It is not part of an account.** The profile rides in the same
   `myadhd.v1` record as the tasks, but `cloud.js` never sends it: a
   name and a face are per device, which is what the hint at the bottom
   says out loud and what `paintLocalNote` repeats one screen up.

   **The faces are drawings, and iOS's own** — sixteen of them in
   `Assets.xcassets/Avatars`, where the web still has twelve emoji. See
   `Avatars` for why the two never meet.

   **An unknown face is drawn as the default and never written back.**
   That is `avatarFace` (app.js:3906) and it is the whole reason this
   screen draws through `Avatars.face(_:)` rather than off the stored
   string. Since the faces became drawings, "unknown" is every emoji an
   earlier build saved: shown as the first face, left as it is on disk. A store outlives the list that filled it: somebody who picked
   a face from a longer list on another build still has that choice
   saved, and correcting it here — which would be the tidier-looking fix
   — would overwrite a decision they made, on the say-so of a device that
   merely happens to be running an older list. What is on screen changes;
   what is saved does not. So the picker's selected ring follows the
   DRAWN face, and a tap writes whatever was tapped.

   **Every keystroke saves.** `profile.name = value.trim().slice(0, 24)`
   then `save()` then `paintProfile()`, on `input` (app.js:5570-5572).
   Two consequences that look like bugs and are the web's:

   - the trim happens before the write, so a trailing space cannot be
     typed — `paintProfile` writes the trimmed name back into the box
     whenever it differs, and the caret goes to the end with it. That is
     reproduced here rather than smoothed over, because the alternative
     is a field whose contents disagree with what was saved.
   - `save()` and not `persistOnly()`: the profile does not sync, but
     `save()` is what app.js calls, and it is a debounce poke and a hash
     per task, not a network round trip.
   ============================================================ */

import SwiftUI

struct ProfileScreen: View {

    @Environment(\.theme) private var theme

    let store: AppStore
    let themeStore: ThemeStore

    /// `#btn-profile-back` — back to settings.
    var onClose: () -> Void

    /// What is in the box. Seeded from the store on appear and pushed
    /// back to it on every change; `paintProfile`'s
    /// `if (el.nameInput.value !== name)` is the line that pulls it back.
    @State private var typed = ""
    @FocusState private var nameFocused: Bool

    /// `avatarFace(state.profile.avatar)` — what is drawn, which is not
    /// necessarily what is stored.
    private var face: String { Avatars.face(store.doc.profile.avatar) }

    private var greeting: String {
        let name = store.doc.profile.name
        return name.isEmpty ? Copy.Settings.greetingPlain : Copy.Settings.greeting(name: name)
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsBar(themeStore: themeStore,
                        backLabel: Copy.Profile.back,
                        backAria: Copy.Profile.backAria,
                        title: Copy.Profile.title,
                        onBack: onClose)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    card
                    hint
                }
                .frame(maxWidth: Theme.measure, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.top, 16)      // .settings-wrap padding-top, fb shape
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, Theme.gutter(UIScreen.main.bounds.width))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.surface.ignoresSafeArea())
        .onAppear { typed = store.doc.profile.name }
    }

    // MARK: - the card

    /// `.profile-card`: the face, the greeting, the name, the picker.
    private var card: some View {
        VStack(spacing: 0) {
            AvatarImage(face: face)
                .frame(width: 78, height: 78)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(theme.lineStrong, lineWidth: 1.5))

            Text(greeting)
                .font(Font.baloo(22, .heavy))
                .kerning(-0.02 * 22)
                .foregroundStyle(theme.ink)
                .padding(.top, 14)

            field(Copy.Profile.nameLabel) { nameBox }
            field(Copy.Profile.pickLabel) { picker }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .padding(.horizontal, 22)
        .padding(.bottom, 24)
        .background(theme.wash)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(theme.line, lineWidth: 1.5)
        )
    }

    /// `.field` — a 12.5px label and whatever it labels, 22px down from
    /// what is above it.
    private func field<Content: View>(_ label: String,
                                      @ViewBuilder _ content: () -> Content) -> some View
    {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 22)
    }

    /// `#profile-name`. `maxlength="24"`, `autocomplete="nickname"`,
    /// spellcheck off — and the cap applied again in `Profile.name`'s
    /// own setter, because a paste beats an attribute.
    private var nameBox: some View {
        TextField(Copy.Profile.namePlaceholder, text: $typed)
            .font(Font.baloo(16))
            .foregroundStyle(theme.ink)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled(true)
            .textContentType(.nickname)
            .submitLabel(.done)
            .focused($nameFocused)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(nameFocused ? theme.accent : theme.lineStrong, lineWidth: 1.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(theme.focus, lineWidth: nameFocused ? 4 : 0)
                    .padding(-2)
            )
            .animation(Theme.ease(0.18), value: nameFocused)
            .onChange(of: typed) { _, next in write(next) }
    }

    /// app.js:5570-5572, in order: trim, cap, save, repaint. The repaint
    /// is what can take a character back out of the box.
    private func write(_ next: String) {
        /* `onAppear` seeds the box from the store, and SwiftUI calls
           `onChange` for that too — which the web's `input` event would
           never fire for. Writing there would `save()` every time the
           screen opened, so the seeding pass is let through untouched. */
        guard next != store.doc.profile.name else { return }
        store.setProfileName(next)
        let saved = store.doc.profile.name
        if typed != saved { typed = saved }
    }

    /// `#avatar-picker`. Sixteen buttons, one group, and the ring on
    /// whichever one matches the face being drawn.
    private var picker: some View {
        AvatarPicker(face: face) { store.setProfileAvatar($0) }
    }

    /// The hint under the card, which is the whole promise of this
    /// screen in two sentences.
    private var hint: some View {
        Text(Copy.Profile.hint)
            .font(.system(size: 13))
            .lineSpacing(13 * 0.5)
            .foregroundStyle(theme.faint)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 18)
    }
}

// MARK: - the sixteen faces

/// `buildAvatarPicker` (app.js:3930-3942), with drawn faces in place of the
/// web's emoji. Each tile is labelled `Use <face> as your face` with the
/// face's name, and carries the selected trait on the one that is on.
///
/// **Four across, not a wrapping row.** The faces came off a four-by-four
/// sheet, and sixteen 44pt tiles wrap five, five, five and one on a phone
/// — a lone face on the last line. Four columns share the width, so the
/// tiles grow with the screen and a drawing gets room to be read.
///
/// `face` is the DRAWN face, never the stored one — see the note at the
/// top of this file. Somebody carrying an emoji from an earlier build sees
/// the first face ringed, and the moment they pick one, that pick is what
/// gets written.
struct AvatarPicker: View {

    @Environment(\.theme) private var theme

    let face: String
    var onPick: (String) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Avatars.faces, id: \.self) { option in
                let on = option == face
                Button { onPick(option) } label: {
                    AvatarImage(face: option)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(on ? theme.accent : theme.lineStrong,
                                              lineWidth: on ? 2.5 : 1.5)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(theme.focus, lineWidth: on ? 3 : 0)
                                .padding(-3)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.Profile.useFace(Avatars.name(option)))
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Profile.pickAria)
    }
}
