/* ============================================================
   MyADHD/UI/MeetingCalendarsList.swift — which calendars are read

   Under the meetings switch, once a read has worked: every calendar on
   the Google account that could be read, one switch each. The defaults
   are `GoogleEvents.reads` — what is ticked in Google Calendar is on,
   holidays and other subscribed calendars are off — and a switch only
   records something when it differs from that, so a calendar added in
   Google later still arrives with the right default.

   Kept on this phone (`MeetingCalendars`), like the meetings switch
   above it. Nothing here touches Google: turning a calendar off here
   does not untick it there.
   ============================================================ */

import SwiftUI

struct MeetingCalendarsList: View {

    @Environment(\.theme) private var theme

    let meetings: MeetingReader

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Copy.Meetings.calendarsTitle)
                    .font(Font.baloo(14, .bold))
                    .foregroundStyle(theme.ink)
                Text(Copy.Meetings.calendarsNote)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, 4)

            ForEach(meetings.options) { option in
                Toggle(isOn: Binding(get: { meetings.reads(option) },
                                     set: { meetings.setReads(option, $0) })) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(option.title)
                            .font(Font.baloo(14.5, .semibold))
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        /* Ink's "Birthday · 337 events": the number is
                           why you would turn one off. Left out until a
                           read has counted it. */
                        if let n = meetings.count(option) {
                            Text(n == 0 ? Copy.Meetings.nothingComingUp : Copy.Meetings.comingUp(n))
                                .font(Font.baloo(12, .semibold))
                                .foregroundStyle(theme.faint)
                        }
                    }
                }
                .tint(theme.accent)
                .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.line).frame(height: 1.5)
        }
    }
}
