/* ============================================================
   MyADHD/UI/MatrixHelp.swift — how the matrix works, in four pages

   BridgeScript.swift:532-609, ported page for page. This exists nowhere
   but the shell: the website has no `?` beside the view toggle, because
   on a wide screen the 2x2 explains itself and on a narrow one the site
   stacks it into a list. Inside the app the four boxes ARE the screen,
   and nothing on it says what dropping a task into one of them means.

   **The sample tasks are made up on purpose.** The point is the shape,
   not the person's own list — a walkthrough drawn from real tasks reads
   as an instruction to move those particular tasks. Eight invented ones
   in fixed quadrants make the same argument and ask for nothing.

   **The fourth page is the Today widget, not a wallpaper.** That is what
   this app actually puts on a home screen, and it is the one thing the
   walkthrough is selling that lives outside the app.

   Page three shows the move it is describing: `Pay the rent` sits in Plan
   while still wearing Do now's ring, so what you see is a task that has
   been moved rather than a task that was always there.
   ============================================================ */

import SwiftUI

struct MatrixHelp: View {

    @Environment(\.theme) private var theme

    var onClose: () -> Void

    @State private var at = 0

    private var palette: QuadrantPalette { QuadrantPalette(dark: theme.dark) }
    private var pages: [Copy.Walkthrough.Page] { Copy.Walkthrough.pages }

    var body: some View {
        VStack(spacing: 0) {
            bar
                .padding(.bottom, 22)

            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            dots
                .padding(.vertical, 18)

            foot
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.ignoresSafeArea())
        .accessibilityLabel(Copy.Walkthrough.title)
    }

    // MARK: the bar

    private var bar: some View {
        ZStack {
            Text(Copy.Walkthrough.title)
                .font(Font.baloo(15, .semibold))
                .foregroundStyle(theme.ink)

            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .frame(width: 40, height: 40)
                        .background(theme.wash, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.Walkthrough.close)
            }
        }
        .frame(height: 40)
    }

    // MARK: one page

    private var page: some View {
        let pg = pages[min(at, pages.count - 1)]
        return VStack(alignment: .leading, spacing: 0) {
            Text(pg.head)
                .font(Font.baloo(Self.headSize, .heavy))
                .kerning(-0.03 * Self.headSize)
                .lineSpacing(Self.headSize * 0.08)
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)

            Text(pg.body)
                .font(Font.baloo(15.5))
                .lineSpacing(15.5 * 0.4)
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 22)

            art
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `clamp(26px, 7.5vw, 32px)`.
    private static var headSize: CGFloat {
        min(32, max(26, UIScreen.main.bounds.width * 0.075))
    }

    @ViewBuilder
    private var art: some View {
        switch at {
        case 0:  flatList
        case 1:  quadGrid(moved: false)
        case 2:  quadGrid(moved: true)
        default: phone
        }
    }

    // MARK: page one — one list, no order

    private var flatList: some View {
        VStack(spacing: 8) {
            ForEach(Copy.Walkthrough.samples, id: \.title) { sample in
                HStack(spacing: 12) {
                    ring(sample.quadrant, size: 18)
                    Text(sample.title)
                        .font(Font.baloo(14, .medium))
                        .foregroundStyle(theme.ink)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(theme.wash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    // MARK: pages two and three — four boxes

    /// `grid(moved)`. With `moved`, the one task walks from Do now into
    /// Plan and keeps its old ring, which is what makes the move legible.
    private func quadGrid(moved: Bool) -> some View {
        let sorted = Self.arrange(moved: moved)
        let keys = Copy.Quadrants.order
        return VStack(spacing: 12) {
            ForEach(Array(stride(from: 0, to: keys.count, by: 2)), id: \.self) { i in
                HStack(spacing: 12) {
                    quadBox(keys[i], rows: sorted[keys[i]] ?? [])
                    quadBox(keys[i + 1], rows: sorted[keys[i + 1]] ?? [])
                }
            }
        }
    }

    private static func arrange(moved: Bool) -> [String: [(title: String, ring: String)]] {
        var by: [String: [(title: String, ring: String)]] = [:]
        for key in Copy.Quadrants.order { by[key] = [] }
        for sample in Copy.Walkthrough.samples {
            if moved && sample.title == Copy.Walkthrough.moved {
                by["plan"]?.append((sample.title, "do"))
                continue
            }
            by[sample.quadrant]?.append((sample.title, sample.quadrant))
        }
        return by
    }

    private func quadBox(_ key: String, rows: [(title: String, ring: String)]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(Copy.Quadrants.label(key))
                .font(Font.baloo(17, .heavy))
                .kerning(-0.02 * 17)
                .foregroundStyle(palette.hue(key))
                .padding(.bottom, 2)

            ForEach(rows, id: \.title) { row in
                HStack(spacing: 9) {
                    ring(row.ring, size: 16)
                    Text(row.title)
                        .font(Font.baloo(13, .medium))
                        .foregroundStyle(theme.ink)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.wash(key))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: page four — on your home screen

    private var phone: some View {
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                Text(Copy.Walkthrough.phoneDate)
                    .font(Font.baloo(13))
                    .foregroundStyle(theme.muted)
                Text(Copy.Walkthrough.phoneTime)
                    .font(Font.baloo(54, .bold))
                    .kerning(-0.04 * 54)
                    .foregroundStyle(theme.ink)
                    .padding(.bottom, 6)
            }

            widget
                .padding(.horizontal, 2)
                .padding(.top, 6)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            LinearGradient(colors: [Color(hex: QuadrantPalette.mix(accentHex,
                                                                   palette.surfaceHex, 0.10)),
                                    theme.surface],
                           startPoint: .top, endPoint: .bottom)
        )
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 38,
                                          bottomLeadingRadius: 0,
                                          bottomTrailingRadius: 0,
                                          topTrailingRadius: 38,
                                          style: .continuous))
        .overlay {
            UnevenRoundedRectangle(topLeadingRadius: 38,
                                   bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 0,
                                   topTrailingRadius: 38,
                                   style: .continuous)
                .strokeBorder(theme.ink, lineWidth: 5)
        }
        .padding(.horizontal, 10)
    }

    private var widget: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Copy.Walkthrough.widgetEyebrow)
                .font(Font.baloo(9.5, .bold))
                .kerning(0.09 * 9.5)
                .foregroundStyle(theme.muted)
                .padding(.bottom, 8)

            ForEach(Copy.Walkthrough.widgetRows, id: \.title) { row in
                HStack(spacing: 9) {
                    if row.done {
                        Circle()
                            .fill(theme.accent)
                            .frame(width: 18, height: 18)
                    } else {
                        Circle()
                            .strokeBorder(theme.lineStrong, lineWidth: 2)
                            .frame(width: 18, height: 18)
                    }
                    Text(row.title)
                        .font(Font.baloo(13.5, .semibold))
                        .foregroundStyle(row.done ? theme.muted : theme.ink)
                        .strikethrough(row.done)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color(hex: 0x101018, opacity: 0.08), radius: 9, y: 4)
    }

    private var accentHex: UInt32 { theme.dark ? 0x8B7DFF : 0x4737FF }

    // MARK: the dots and the way on

    private var dots: some View {
        HStack(spacing: 9) {
            ForEach(pages.indices, id: \.self) { i in
                Circle()
                    .fill(i == at ? theme.ink : theme.lineStrong)
                    .frame(width: 7, height: 7)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private var foot: some View {
        HStack(spacing: 12) {
            /* `visibility:hidden` on page one — it keeps its space, so the
               primary button does not change width between pages. */
            Button { go(at - 1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 52, height: 52)
                    .background(theme.wash, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(at == 0 ? 0 : 1)
            .disabled(at == 0)
            .accessibilityLabel(Copy.Walkthrough.back)
            .accessibilityHidden(at == 0)

            Button {
                if at == pages.count - 1 { onClose() } else { go(at + 1) }
            } label: {
                Text(pages[min(at, pages.count - 1)].cta)
                    .font(Font.baloo(16.5, .bold))
                    .kerning(-0.01 * 16.5)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
                    .background(theme.brandGradient, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func go(_ n: Int) {
        withAnimation(Theme.ease(0.22)) {
            at = max(0, min(pages.count - 1, n))
        }
    }

    // MARK: -

    /// `.wk-ring` — 2pt of the quadrant's own hue and nothing inside it.
    private func ring(_ quadrant: String, size: CGFloat) -> some View {
        Circle()
            .strokeBorder(palette.hue(quadrant), lineWidth: 2)
            .frame(width: size, height: size)
    }
}
