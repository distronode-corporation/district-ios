import DistrictData
import DistrictModel
import Foundation
import Observation

/// The overview register's five rows, each read independently.
///
/// ⛔ FIVE SEPARATE STATES RATHER THAN ONE, AND THAT IS THE WHOLE SHAPE OF THIS MODEL.
/// The web renders each row's own failure in red and leaves the others standing, because
/// the reads are genuinely independent: a calendar outage says nothing about whether the
/// event types loaded. One combined state would blank a screen that is four-fifths
/// correct, which on a register whose job is "is my booking desk set up" is the answer
/// most likely to send somebody looking for a problem that is not there.
///
/// ⛔ AND THE READS RUN CONCURRENTLY, ONCE PER SCREEN VISIT. They are five GETs against
/// one route; issuing them in series would make the slowest one the screen's latency, and
/// re-issuing them on every redraw is what `State(initialValue:)` in the view's `init`
/// exists to prevent. ⚠️ Reads are unlimited on this surface (only writes spend the
/// workspace's 120-per-hour budget, see ``SchedulingAdminOp/isWrite``) but "unlimited" is
/// not a licence to poll: nothing here loops.
///
/// ⚠️ THE TIMEZONE IS READ AND IS NOT THE DEVICE'S. Every stamp on this screen is
/// rendered in the timezone on the operator's SCHEDULER profile (`me.get`), because that
/// is the zone the customer was told. A booking read on a phone in another country must
/// still say the hour the customer expects. ⛔ A failed `me.get` does NOT fail the screen:
/// it falls back to UTC and the header says which zone it is using, which is the honest
/// degradation — the alternative is five correct rows hidden behind one optional field.
@MainActor
@Observable
final class SchedulingOverviewModel {
    private(set) var eventTypes: SchedulingSectionState<[SchedulingEventType]> = .loading
    private(set) var calendar: SchedulingSectionState<SchedulingCalendarStatus> = .loading
    private(set) var rules: SchedulingSectionState<[SchedulingAvailabilityRule]> = .loading
    private(set) var bookings: SchedulingSectionState<[SchedulingBooking]> = .loading

    /// ⚠️ NOT A `SchedulingSectionState`, BECAUSE ITS FAILURE IS NOT A ROW. The profile
    /// read only supplies a timezone; when it fails the screen still renders, in UTC.
    private(set) var timezone = "UTC"
    private(set) var timezoneResolved = false

    /// The tenancy's public host, for the booking links.
    ///
    /// ⛔ IT COMES FROM THE STATUS ROUTE AND IS NEVER REBUILT FROM ANYTHING ELSE. The
    /// route derives the booking key server-side and sends it only for a ready tenancy; a
    /// client that assembled its own would publish a link for a page that is not there.
    /// See the ⛔ in ``SchedulingHubView``'s live detail.
    private(set) var publicHost: String?

    /// ⛔ SENDS `scope: "all"` ONLY WHEN THE OPERATOR MAY MANAGE, AND THE SERVER IGNORES
    /// IT OTHERWISE. Asking for every host's bookings as a non-admin is silently narrowed
    /// to your own, so the register must not caption the result as the whole tenancy's.
    /// The web makes the same call from the same value.
    private(set) var canManage = false

    private let repository: SchedulingAdminRepository
    private let scheduling: SchedulingRepository
    private let workspaceId: String

    /// ⛔ THE DESIGNATED INITIALISER TAKES THE REPOSITORIES AND THE CONTAINER ONE
    /// DELEGATES TO IT, WHICH IS THE ONLY TEST SEAM ON THIS SURFACE. ``AppContainer``
    /// builds its own ``URLSessionHTTPTransport`` in `init`, so a test cannot hand it a
    /// fake; taking the collaborators directly lets `DistrictAITests` drive a real
    /// repository over a stub transport, which exercises the envelope walk rather than
    /// skipping it. ⚠️ Production still constructs through the container, so both
    /// collaborators remain the one shared ``ApiClient``.
    init(
        repository: SchedulingAdminRepository,
        scheduling: SchedulingRepository,
        workspaceId: String
    ) {
        self.repository = repository
        self.scheduling = scheduling
        self.workspaceId = workspaceId
    }

    convenience init(container: AppContainer, workspaceId: String) {
        self.init(
            repository: container.schedulingAdmin,
            scheduling: container.scheduling,
            workspaceId: workspaceId
        )
    }

    /// ⛔ THE STATUS READ RUNS FIRST AND ALONE, AND THE OTHER FIVE WAIT FOR IT. That is
    /// the one place on this screen where serialising is right rather than lazy: two of
    /// the five need values it answers — `publicHost` for the booking links and
    /// `canManage` for the bookings scope — and issuing them concurrently would send the
    /// bookings read with `scope` unset and then have no honest way to correct it without
    /// a second request. ⚠️ It is also cheap and unpaged, so the cost is one round trip
    /// on screen entry.
    ///
    /// ⛔ AND THE SCREEN READS STATUS ITSELF RATHER THAN TAKING IT FROM THE HUB. A
    /// destination restored from a `NavigationPath` after the app was killed has no hub
    /// above it to have loaded anything, which is the same argument the ⛔ at the top of
    /// ``Route`` makes for carrying `workspaceId` in every case: a screen has to be able
    /// to fill itself from its own route.
    ///
    /// ⚠️ A FAILED STATUS READ DOES NOT BLANK THE SCREEN. `publicHost` stays nil (the
    /// booking-page row says so) and `canManage` stays false (the bookings read is
    /// narrowed, which is the safe direction); the other four rows are unaffected because
    /// none of them depends on it.
    func load() async {
        await loadStatus()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadTimezone() }
            group.addTask { await self.loadEventTypes() }
            group.addTask { await self.loadCalendar() }
            group.addTask { await self.loadRules() }
        }
        // ⚠️ AFTER THE GROUP, BECAUSE IT READS `timezone` FOR ITS `from` DATE. Running it
        // inside would race the profile read and ask for "today" in whichever zone had
        // landed first, which near midnight is a different day.
        await loadBookings()
    }

    private func loadStatus() async {
        guard case let .success(status) = await scheduling.status(workspaceId: workspaceId) else {
            return
        }
        publicHost = status.tenant?.publicHost
        canManage = status.canManage
    }

    private func loadTimezone() async {
        do {
            let me = try await repository.me(workspaceId: workspaceId)
            timezone = me.timezone.isEmpty ? "UTC" : me.timezone
        } catch {
            // ⛔ SWALLOWED ON PURPOSE, AND IT IS THE ONLY SWALLOWED READ ON THIS SCREEN.
            // The profile supplies a display zone and nothing else; reporting its failure
            // as a row would invent a sixth row for a fact the operator cannot act on,
            // and hiding the other five behind it would be worse. The header says which
            // zone is in use either way, so a UTC fallback is visible rather than silent.
            timezone = "UTC"
        }
        timezoneResolved = true
    }

    private func loadEventTypes() async {
        do {
            eventTypes = try await .ready(repository.listEventTypes(workspaceId: workspaceId))
        } catch {
            eventTypes = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    private func loadCalendar() async {
        do {
            calendar = try await .ready(repository.calendarStatus(workspaceId: workspaceId))
        } catch {
            calendar = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    /// ⛔ NO `eventTypeId`, WHICH IS WHAT MAKES THIS "your working hours". Passing one
    /// filters to that event type's own rules and EXCLUDES the global ones, so the result
    /// would be a different question's answer. See the ⛔ on
    /// ``SchedulingAdminRepository/availabilityRules(workspaceId:eventTypeId:)``.
    private func loadRules() async {
        do {
            rules = try await .ready(repository.availabilityRules(workspaceId: workspaceId))
        } catch {
            rules = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    /// ⚠️ TEN ROWS, ASCENDING, FROM TODAY. The register is a glance at what is coming;
    /// the full feed is the bookings section, which pages.
    private func loadBookings() async {
        do {
            let page = try await repository.bookings(
                workspaceId: workspaceId,
                when: "upcoming",
                from: SchedulingHoursFormat.todayInZone(timezone),
                limit: 10,
                allHosts: canManage,
                order: "asc"
            )
            bookings = .ready(page.items)
        } catch {
            bookings = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    // MARK: - Derived rows

    /// The bookable pages, as `https://<host>/book/<slug>`.
    ///
    /// ⚠️ EMPTY WHEN THE HOST IS NOT KNOWN, rather than rendering a path with no origin.
    /// A tenancy still provisioning has no public host and the row says so in words.
    var bookingLinks: [(slug: String, url: String)] {
        guard let publicHost, !publicHost.isEmpty, let items = eventTypes.value else { return [] }
        return SchedulingOverviewSummary.bookableEventTypes(items).map { item in
            (item.slug, SchedulingOverviewSummary.bookingUrlFor(publicHost: publicHost, slug: item.slug))
        }
    }

    var workingHoursSummary: String? {
        rules.value.flatMap(SchedulingOverviewSummary.summarizeWorkingHours)
    }

    var eventTypesSummary: String? {
        eventTypes.value.flatMap(SchedulingOverviewSummary.summarizeEventTypes)
    }

    /// ⚠️ THE **ACTIVE** NAMES, WHICH IS `isActive` ALONE AND NOT `bookableEventTypes`.
    /// The two sets differ on a row that is active but not public, and the web's secondary
    /// line uses the same predicate as the count above it — so using the bookable set here
    /// would list fewer names than the number beside them claims.
    var activeEventTypeNames: String? {
        guard let items = eventTypes.value else { return nil }
        let names = items.filter { $0.isActive != false }.map(\.name)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// ⚠️ THE CONNECTED ACCOUNTS AS `Provider, address`. An empty list is a real answer
    /// and the row offers the connect hint instead.
    var calendarLines: [String] {
        guard let status = calendar.value else { return [] }
        return status.connections.map { connection in
            "\(SchedulingCalendarFormat.providerLabel(connection.provider)), \(connection.accountEmail)"
        }
    }

    /// `Today 14:30, Ada, Intro call`, or nil.
    var nextBookingLine: String? {
        guard let booking = bookings.value?.first else { return nil }
        let when = SchedulingOverviewSummary.bookingWhen(startAt: booking.startAt, timezone: timezone)
        let who = SchedulingOverviewSummary.bookingWho(booking)
        let what = SchedulingOverviewSummary.bookingEventTypeName(
            booking,
            eventTypes: eventTypes.value ?? []
        )
        // ⚠️ AN UNPARSEABLE START IS THE WORD `Unknown` RATHER THAN A DROPPED ROW. The
        // booking exists and the other two facts about it are still worth saying.
        return "\(when ?? SchedulingCopy.unknownTime), \(who), \(what)"
    }

    /// One row of the "Coming up" list.
    struct ComingUpRow: Identifiable {
        let id: String
        let when: String
        let who: String
        let eventType: String
        let status: SchedulingStatusLabel
    }

    var comingUp: [ComingUpRow] {
        guard let items = bookings.value else { return [] }
        let types = eventTypes.value ?? []
        return items.map { booking in
            ComingUpRow(
                id: booking.id,
                when: SchedulingOverviewSummary.bookingWhen(startAt: booking.startAt, timezone: timezone)
                    ?? SchedulingCopy.unknownTime,
                who: SchedulingOverviewSummary.bookingWho(booking),
                eventType: SchedulingOverviewSummary.bookingEventTypeName(booking, eventTypes: types),
                status: SchedulingBookingFormat.statusLabel(booking.status)
            )
        }
    }

    // MARK: - Writes

    // ⛔ NOTHING ON THIS SCREEN WRITES, AND THE REGISTER IS UNLIKELY EVER TO. It is a
    // summary of four other sections; the actions it suggests (create an event type,
    // connect a calendar, set your hours) belong on those sections' own screens, where
    // the form and its validation live. A write added HERE would be a second editor over
    // rows whose screen already owns them.
    //
    // ⚠️ What this screen SHOULD gain when those sections do is navigation: the empty
    // rows currently state the remedy in words and the web links them.
}
