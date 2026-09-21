import DistrictData
import DistrictModel
import SwiftUI

/// The booking desk at a glance: five summary rows, and what is coming up.
///
/// ⛔ EVERY ROW STANDS OR FALLS ALONE. A failed read renders that row's sentence in the
/// destructive tone and leaves the other four; see the ⛔ on ``SchedulingOverviewModel``.
/// A screen-level failure state here would blank a register that is four-fifths correct.
///
/// ⚠️ THE EMPTY ROWS STATE THE REMEDY IN WORDS AND DO NOT LINK YET. The web's versions are
/// links ("Create an event type", "Connect a calendar", "Set your hours") into pages that
/// can create the thing; those are writes, so this stage says the sentence and the write
/// stage makes it a destination. A link to a read-only screen that cannot do the thing it
/// names would be worse than the sentence.
struct SchedulingOverviewView: View {
    @State private var model: SchedulingOverviewModel

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        // ⚠️ THE ROLE IS UNUSED HERE AND THE PARAMETER IS KEPT. Every section takes the
        // same arguments so ``SchedulingDestinations`` does not have to remember which
        // ones differ; see the ⚠️ on that type.
        _ = role
        _model = State(initialValue: SchedulingOverviewModel(
            container: container,
            workspaceId: workspaceId
        ))
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        SchedulingSectionScroll(
            title: SchedulingCopy.sectionTitle(.overview),
            identifier: A11yID.Scheduling.overviewRoot,
            onRefresh: { await model.load() },
            content: {
                desk
                comingUp
            }
        )
        .task { await model.load() }
    }

    // MARK: - The desk

    private var desk: some View {
        SchedulingCard(eyebrow: SchedulingCopy.deskEyebrow) {
            Text(SchedulingCopy.timesIn(model.timezone))
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            bookingPageRow
            DistrictRowDivider()
            calendarRow
            DistrictRowDivider()
            hoursRow
            DistrictRowDivider()
            eventTypesRow
            DistrictRowDivider()
            nextBookingRow
        }
    }

    /// ⛔ THE LINK IS SHOWN AS TEXT AND IS NOT TAPPABLE. It addresses the workspace's own
    /// public booking page, which is outside this app; making it a link would be a second
    /// route out of the product beside the hub's one deliberate escape hatch, and a
    /// customer-facing page is not where an operator's tap should land by accident. The
    /// hub already offers Copy and Share for the link that matters.
    private var bookingPageRow: some View {
        deskRow(title: SchedulingCopy.deskBookingPage, state: model.eventTypes) {
            let links = model.bookingLinks
            if links.isEmpty {
                hint(model.publicHost == nil
                    ? SchedulingCopy.deskNoHost
                    : SchedulingCopy.deskNoEventTypes)
            } else {
                VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                    ForEach(links, id: \.slug) { link in
                        Text(link.url)
                            .font(DistrictType.bodySmall)
                            .foregroundStyle(colors.foreground)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var calendarRow: some View {
        deskRow(title: SchedulingCopy.deskCalendar, state: model.calendar) {
            let lines = model.calendarLines
            if lines.isEmpty {
                hint(SchedulingCopy.deskNoCalendar)
            } else {
                VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                    ForEach(lines, id: \.self) { line in
                        value(line)
                    }
                }
            }
        }
    }

    private var hoursRow: some View {
        deskRow(title: SchedulingCopy.deskHours, state: model.rules) {
            if let summary = model.workingHoursSummary {
                value(summary)
            } else {
                hint(SchedulingCopy.deskNoHours)
            }
        }
    }

    private var eventTypesRow: some View {
        deskRow(title: SchedulingCopy.deskEventTypes, state: model.eventTypes) {
            if let summary = model.eventTypesSummary {
                VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                    value(summary)
                    if let names = model.activeEventTypeNames {
                        Text(names)
                            .font(DistrictType.caption)
                            .foregroundStyle(colors.mutedForeground)
                    }
                }
            } else {
                hint(SchedulingCopy.deskNoEventTypes)
            }
        }
    }

    private var nextBookingRow: some View {
        deskRow(title: SchedulingCopy.deskNextBooking, state: model.bookings) {
            if let line = model.nextBookingLine {
                value(line)
            } else {
                hint(SchedulingCopy.deskNoBookings)
            }
        }
    }

    // MARK: - Row furniture

    /// One labelled row that knows the three states its read can be in.
    ///
    /// ⚠️ THE LABEL IS DRAWN IN EVERY STATE, INCLUDING WHILE LOADING AND ON FAILURE. A row
    /// that appeared only once its read landed would make the register's height jump as
    /// five requests finish at different times, and a failed row with no label could not
    /// say WHICH thing failed.
    private func deskRow(
        title: String,
        state: SchedulingSectionState<some Any>,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(title)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            switch state {
            case .loading:
                SkeletonBlock(height: 16)
            case let .failed(failure):
                Text(failure.message)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.destructive)
            case .ready:
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(DistrictType.bodySmall)
            .foregroundStyle(colors.foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(DistrictType.bodySmall)
            .foregroundStyle(colors.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Coming up

    private var comingUp: some View {
        SchedulingCard(eyebrow: SchedulingCopy.comingUpEyebrow) {
            switch model.bookings {
            case .loading:
                LoadingView(message: SchedulingCopy.loadingBookings)
            case let .failed(failure):
                Text(failure.message)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.destructive)
            case .ready:
                comingUpRows
            }
        }
    }

    @ViewBuilder
    private var comingUpRows: some View {
        let rows = model.comingUp
        if rows.isEmpty {
            Text(SchedulingCopy.comingUpEmpty)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
        } else {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    DistrictListRow(
                        title: row.when,
                        subtitle: "\(row.who) · \(row.eventType)",
                        trailing: { DistrictBadge(text: row.status.label, tone: row.status.kind.tone) }
                    )
                    if row.id != rows.last?.id {
                        DistrictRowDivider()
                    }
                }
            }
        }
    }
}
