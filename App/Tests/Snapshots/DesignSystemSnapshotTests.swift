@testable import DistrictAI
import SwiftUI
import XCTest

/// The design system's shared pieces in each of their shapes: the empty state with and without
/// its action, the failure view for each action it can offer, the list row's slot combinations at
/// an ordinary and an accessibility text size, the card a list's rows slice up, and the detail
/// column's placeholder.
///
/// ⚠️ THE WORDS ARE THE APP'S OWN COPY, so the French drawing is the French a person reads.
final class DesignSystemSnapshotTests: ScreenSnapshotTestCase {
    // MARK: - Empty and loading

    /// A message with its action, and one without, over a loading skeleton.
    func testEmptyStates() async throws {
        try await assertScreen(devices: [.iPhone]) { _ in
            VStack(spacing: DistrictSpacing.section) {
                EmptyStateView(
                    systemImage: "checkmark.circle",
                    title: SetupCopy.finishedTitle,
                    message: SetupCopy.finishedBody
                ) {
                    Button(SetupCopy.done) {}.buttonStyle(.districtPrimary)
                }
                EmptyStateView(
                    systemImage: "person.badge.key",
                    title: SetupCopy.notOwnerTitle,
                    message: SetupCopy.notOwnerBody
                )
                SkeletonBlock()
                SkeletonBlock(height: 56)
            }
            .padding()
        }
    }

    // MARK: - Failure

    /// Each action a failure can carry: Try again, Sign in, and none; and a retry offered with no
    /// handler, which draws no button rather than one that does nothing.
    func testFailureViews() async throws {
        try await assertScreen(devices: [.iPhone]) { _ in
            ScrollView {
                VStack(spacing: 0) {
                    FailureView(failure: FailureText(message: TwoStepCopy.errorLoad, action: .retry), onRetry: {})
                    FailureView(
                        failure: FailureText(message: SessionCopy.refreshRejected, action: .signIn),
                        onSignIn: {}
                    )
                    FailureView(failure: FailureText(message: CallsCopy.callNotAvailable, action: .none))
                    FailureView(failure: FailureText(message: TwoStepCopy.errorLoad, action: .retry))
                }
            }
        }
    }

    // MARK: - List rows

    /// Title only, with a subtitle, with an avatar, with a trailing badge, and with both slots.
    func testListRows() async throws {
        try await assertScreen(devices: [.iPhone]) { _ in
            Self.rows.padding()
        }
    }

    /// The same rows at an accessibility size: the trailing slot underneath, the lines unlimited.
    func testListRowsAccessibilitySize() async throws {
        try await assertScreen(devices: [.iPhone], locales: [.en]) { _ in
            ScrollView { Self.rows.padding() }
                .environment(\.dynamicTypeSize, .accessibility3)
        }
    }

    /// The rows with their subtitles in full, as the account screen draws them.
    func testListRowsWrappingSubtitle() async throws {
        try await assertScreen(devices: [.iPhone], locales: [.en]) { _ in
            Self.rows.padding().environment(\.districtRowWrapsSubtitle, true)
        }
    }

    private static var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            DistrictListRow(title: AccountCopy.account)
            DistrictRowDivider()
            DistrictListRow(
                title: AvailabilityCopy.rowTitle,
                subtitle: AvailabilityCopy.rowSubtitleOnce("Bravo Client")
            )
            DistrictRowDivider()
            DistrictListRow(title: "Ada Lovelace", subtitle: "+1 416 555 0199", leading: {
                DistrictAvatar(name: "Ada Lovelace")
            })
            DistrictRowDivider()
            DistrictListRow(title: "Grace Hopper", subtitle: "A long subtitle that runs on past the row", trailing: {
                DistrictBadge(text: "3", tone: .district)
            })
            DistrictRowDivider()
            DistrictListRow(
                title: "Alpha Client",
                subtitle: "eu",
                leading: { DistrictAvatar(name: "Alpha Client", tone: .info) },
                trailing: { Image(systemName: "chevron.right") }
            )
        }
    }

    // MARK: - A card sliced across list rows

    /// Three rows of one card in a `List`, the middle one selected.
    func testCardSlices() async throws {
        let names = ["Zulu Agency", "Alpha Client", "Bravo Client"]
        try await assertScreen(devices: [.iPhone], locales: [.en]) { _ in
            List {
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    DistrictListRow(title: name)
                        .modifier(CardSlice(first: index == 0, last: index == names.count - 1, selected: index == 1))
                        .stackedListRow(top: index == 0 ? DistrictSpacing.row : 0)
                }
            }
            .stackedList()
        }
    }

    // MARK: - The detail column

    /// What the iPad's detail column shows before a row is chosen.
    func testDetailPlaceholder() async throws {
        try await assertScreen(devices: [.iPad]) { _ in
            DetailPlaceholder(title: CallsCopy.call, symbol: "phone")
        }
    }
}

/// A confirmation's presentation binding: it reads the value it was built with, and only a close
/// reaches the screen's cancel.
@MainActor
final class DialogAnchorTests: XCTestCase {
    func testItReadsTheValueItWasBuiltWith() {
        XCTAssertTrue(Binding.dialog(true, onDismiss: {}).wrappedValue)
        XCTAssertFalse(Binding.dialog(false, onDismiss: {}).wrappedValue)
    }

    func testAClosingWriteCancelsOnce() {
        var dismissed = 0
        let binding = Binding.dialog(true) { dismissed += 1 }
        binding.wrappedValue = false
        XCTAssertEqual(dismissed, 1)
    }

    /// ⚠️ OPENING IS THE CONTROL'S OWN ACTION: a `true` write does nothing, even repeated.
    func testAnOpeningWriteDoesNothing() {
        var dismissed = 0
        let binding = Binding.dialog(false) { dismissed += 1 }
        binding.wrappedValue = true
        binding.wrappedValue = true
        XCTAssertEqual(dismissed, 0)
        XCTAssertFalse(binding.wrappedValue, "the binding does not hold a write; the screen's state decides")
    }
}
