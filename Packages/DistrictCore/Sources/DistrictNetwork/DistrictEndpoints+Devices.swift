import Foundation

/// The account's signed-in devices, and this installation's push registration.
///
/// ⛔ TWO DIFFERENT PREFIXES FOR THINGS THAT BOTH SAY "devices", AND NEITHER IS
/// INTERCHANGEABLE. SESSION management lives under `/api/auth/native/devices/…`
/// — a PUBLIC prefix in `proxy.ts`, so the default-deny middleware never runs and
/// each route's own `requireAuth` is the entire access control. PUSH registration
/// is a district resource at `/api/district/devices/…`, behind that middleware.
/// `/api/auth/native/devices/register` and `/api/district/devices/revoke` both
/// 404, and each reads as a broken client.
///
/// ⛔ ALL FIVE ARE ACCOUNT-SCOPED, NOT WORKSPACE-SCOPED, and none could be
/// otherwise: a native session belongs to a USER and a device belongs to a PERSON
/// across every workspace they hold. The scope comes from the verified session
/// and there is no parameter that could widen it — an identity arriving as an
/// argument is an identity the caller chose.
public extension DistrictEndpoints {
    /// Every live install on this account, newest first.
    ///
    /// ⚠️ CAN LAG A ROTATION, so a short or empty list is not proof of a
    /// signed-out account. ⚠️ Rate limited at 30/min PER ACCOUNT, which is sized
    /// for a settings screen rather than a poll loop.
    static func devices() -> ApiRequestDescriptor {
        ApiRequestDescriptor(.devices, .get, DistrictPaths.nativeDevices)
    }

    /// Sign out one install.
    ///
    /// ⛔ ANSWERS `revoked: 0` RATHER THAN 404 FOR A DEVICE THAT IS NOT YOURS, on
    /// purpose. A client that reported zero as an error would be exposing the
    /// oracle the server declined to build.
    ///
    /// ⚠️ SIGNING OUT THE CURRENT DEVICE IS A LOCAL EVENT TOO. The server has no
    /// way to tell this process that its credential just died — it will simply 401
    /// on the next request — so whatever calls this drives the local sign-out
    /// itself.
    ///
    /// ⚠️ The server validates `deviceId` at 8...200 characters, mirroring the
    /// token route's window exactly. An id outside it could never have been
    /// stored.
    static func revokeDevice(deviceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .revokeDevice,
            .post,
            DistrictPaths.nativeDevicesRevoke,
            body: .json(.object([("deviceId", .string(deviceId))]))
        )
    }

    /// Sign out every install, INCLUDING THIS ONE.
    ///
    /// ⛔ THE CALLING DEVICE IS NOT SPARED, AND THAT IS THE SERVER'S DECISION: an
    /// "all" that quietly excepted the caller would be a control nobody could
    /// reason about. Treat a successful response as this device's own sign-out.
    ///
    /// ⚠️ NO PARAMETERS EXIST — the route parses nothing — so an EMPTY OBJECT is
    /// sent rather than a body a caller would have to guess at. (On Kotlin the
    /// `{}` was forced by OkHttp rejecting a body-less POST; here it is a
    /// deliberate parity choice, so the two clients put identical bytes on the
    /// wire for the same call.)
    static func revokeAllDevices() -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .revokeAllDevices,
            .post,
            DistrictPaths.nativeRevokeAll,
            body: .json(.object([:]))
        )
    }

    /// Record (or refresh) this installation's push token.
    ///
    /// ⛔ IT TAKES NO `deviceId`, AND COULD NOT. The server recovers the
    /// installation from the bearer it was presented with, because `deviceId` is
    /// the UPSERT KEY on the row: a caller able to name it could point somebody
    /// else's row at their own token and start receiving that person's
    /// notifications.
    ///
    /// ⛔ `platform` IS SENT EXPLICITLY AS `"ios"`. The route's schema defaults it
    /// to `"android"`, so omitting it works and silently mislabels every row this
    /// client writes — and the server's push sender selects the APNs payload from
    /// exactly that column.
    ///
    /// ⚠️ AN IDEMPOTENT UPSERT KEYED ON THE INSTALLATION: re-sending the same
    /// token is free and a NEW one replaces the old. ⚠️ A device re-registered by
    /// a different account MOVES to that account rather than accumulating a second
    /// row — one phone, one token, one owner — which is what stops a signed-out
    /// account's notifications arriving on a handset somebody else now holds.
    ///
    /// ⚠️ Rate limited at 20/min PER ACCOUNT. Nothing here may be called on a
    /// timer.
    ///
    /// ⛔ ONE DESCRIPTOR AND ONE ``EndpointID`` FOR BOTH TOKENS, BECAUSE IT IS
    /// ONE ROUTE AND ONE VERB. The alert token and the PushKit token differ by a
    /// single body key, and splitting them into two ids would put a second row in
    /// `EndpointTable`, a second entry in every classification list and a second
    /// number in the burn-down for a distinction the URL does not make. Compare
    /// the messaging family, which IS five ids on one URL: there the string in
    /// the body picks a destructive branch of the route's own switch, and a
    /// mistyped one falls through to an UPSERT. Here a wrong ``kind`` writes the
    /// wrong COLUMN of one row, which the two callers in ``PushTokenRepository``
    /// pin on the encoded bytes.
    ///
    /// - Parameter kind: which token this is. ⚠️ Defaulted so the alert
    ///   register's bytes are unchanged; see ``PushTokenKind``.
    static func registerPushToken(token: String, kind: PushTokenKind = .alert) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .registerPushToken,
            .post,
            DistrictPaths.devicesRegister,
            body: .json(.object([
                ("token", .string(token)),
                ("platform", .string(PushPlatform.ios)),
                // ⚠️ DROPPED RATHER THAN SENT AS NULL FOR THE ALERT TOKEN.
                // ``JSONValue/object(_:)`` discards a nil pair, and an absent key
                // is what lets the route's own default fire; an explicit null is
                // a value, and zod would not default over it.
                ("kind", .optional(kind.wire)),
            ]))
        )
    }

    /// Stop pushing to this installation.
    ///
    /// ⛔ IT NEEDS A LIVE BEARER, WHICH IS WHY IT RUNS BEFORE THE SIGN-OUT'S
    /// REVOKE AND NOT AFTER. Once the refresh token is revoked there is no
    /// credential left to authenticate this with, and the row would sit registered
    /// until the push service eventually reported the token gone.
    ///
    /// ⛔ NO BODY IS HONOURED — the route parses nothing — so `{}` goes, matching
    /// ``revokeAllDevices()``.
    static func unregisterPushToken() -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .unregisterPushToken,
            .post,
            DistrictPaths.devicesUnregister,
            body: .json(.object([:]))
        )
    }
}
