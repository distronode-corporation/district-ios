#!/usr/bin/env python3
"""W4 French QA only: serves the contract fixtures to the simulator in place of the API.

    python3 qa/mock_server.py <contracts/mobile dir> [port]

Every request is answered from a recorded fixture (district-core-swift's contracts/mobile),
chosen by method, path, query and, for the scheduling admin route, the body's `op`. A route
with no fixture gets a 404 with the service's error shape, so the screen shows its own
failure text. Each request is logged as `MOCK <status> <method> <path> -> <fixture>`, which is
how the walk's report says which screens had data.
"""
from __future__ import annotations

import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

FIXTURE_DIRS = [Path(p) for p in sys.argv[1].split(":")]
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8765
D = "/api/district"

# (method, path regex, query predicate or None, fixture)
ROUTES: list[tuple[str, str, object, str]] = [
    ("GET", r"/api/settings", None, "district-settings.json"),
    ("GET", D + r"/workspace/list", None, "district-workspace-list.json"),
    ("GET", D + r"/workspace/usage", lambda q: q.get("history") == ["true"], "district-usage-history.json"),
    ("GET", D + r"/workspace/usage", None, "district-usage.json"),
    ("GET", D + r"/workspace/billing", None, "district-workspace-billing.json"),
    ("GET", D + r"/workspace/availability", None, "district-workspace-availability.json"),
    ("GET", r"/api/billing", None, "district-billing.json"),
    ("GET", D + r"/workspace/config", None, "district-workspace-config.json"),
    ("GET", D + r"/workspace/persona/options", "fr", "district-persona-options-fr.json"),
    ("GET", D + r"/workspace/persona/options", None, "district-persona-options.json"),
    ("GET", D + r"/workspace/persona/voice-studio", None, "district-voice-studio.json"),
    ("GET", D + r"/workspace/knowledge", None, "district-knowledge.json"),
    ("GET", D + r"/workspace/knowledge-mode", None, "district-knowledge-mode.json"),
    ("GET", D + r"/workspace/messaging", None, "district-messaging.json"),
    ("GET", D + r"/workspace/campaign-status", None, "district-campaign-status.json"),
    ("GET", D + r"/workspace/members", None, "district-members.json"),
    ("GET", D + r"/workspace/numbers/search", None, "district-numbers-search.json"),
    ("GET", D + r"/workspace/provider/numbers", None, "district-provider-numbers.json"),
    ("GET", D + r"/workspace/provider/status", None, "district-provider-status.json"),
    ("GET", D + r"/workspace/sip", None, "district-sip-trunks.json"),
    ("GET", D + r"/workspace/verify", None, "district-verify.json"),
    ("GET", D + r"/workspace/lookup", None, "district-number-lookup.json"),
    ("GET", D + r"/overview", None, "district-overview.json"),
    ("GET", D + r"/setup", None, "district-setup.json"),
    ("GET", D + r"/analytics", None, "district-analytics.json"),
    ("GET", D + r"/calls", None, "district-calls.json"),
    ("GET", D + r"/calls/[^/]+/transcript", None, "district-call-transcript.json"),
    ("GET", D + r"/calls/[^/]+", None, "district-call-detail.json"),
    ("GET", D + r"/meetings", None, "district-meetings.json"),
    ("GET", D + r"/meetings/[^/]+", None, "district-meeting-detail.json"),
    ("GET", D + r"/workflows/runs", None, "district-workflow-runs.json"),
    ("GET", D + r"/workflows", None, "district-workflows.json"),
    ("GET", D + r"/contacts/blocked", None, "district-contacts-blocked.json"),
    ("GET", D + r"/contacts/get", None, "district-contact-detail.json"),
    ("GET", D + r"/contacts", None, "district-contacts.json"),
    ("GET", D + r"/conversations", None, "district-conversations.json"),
    ("GET", D + r"/timeline", None, "district-timeline.json"),
    ("GET", D + r"/messages/unread-count", None, "district-messages-unread-count.json"),
    ("GET", D + r"/messages/drafts", lambda q: "threadKey" in q, "district-draft.json"),
    ("GET", D + r"/messages/drafts", None, "district-drafts-list.json"),
    ("GET", D + r"/messages/[^/]+", None, "district-message-thread.json"),
    ("GET", D + r"/scheduling/status", None, "district-scheduling-status-ready.json"),
    ("GET", D + r"/desk/settings", None, "district-desk-settings.json"),
    ("GET", D + r"/desk/tickets", None, "district-desk-tickets.json"),
    ("GET", D + r"/desk/tickets/[^/]+", None, "district-desk-ticket.json"),
    ("GET", D + r"/support/requests", None, "district-support-requests.json"),
    ("GET", D + r"/support/requests/[^/]+", None, "district-support-request.json"),
    ("GET", r"/api/auth/native/devices", None, "district-devices.json"),
    ("POST", D + r"/devices/register", None, "district-device-register.json"),
    ("POST", D + r"/telemetry/token", None, "district-telemetry-token.json"),
    ("POST", D + r"/hq", None, "district-hq-answer.json"),
    ("POST", D + r"/messages/draft", None, "district-ai-draft.json"),
]

ADMIN_OPS = {
    "me.get": "district-scheduling-me.json",
    "eventTypes.list": "district-scheduling-event-types.json",
    "eventTypes.get": "district-scheduling-event-type.json",
    "eventTypes.hosts.get": "district-scheduling-hosts.json",
    "eventTypes.questions.list": "district-scheduling-questions.json",
    "eventTypes.slots": "district-scheduling-slots.json",
    "availability.rules.list": "district-scheduling-rules.json",
    "availability.overrides.list": "district-scheduling-overrides.json",
    "bookings.list": "district-scheduling-bookings.json",
    "bookings.answers": "district-scheduling-booking-answers.json",
    "calendar.status": "district-scheduling-calendar-status.json",
    "calendar.connections.calendars.get": "district-scheduling-calendars.json",
    "zoom.status": "district-scheduling-zoom-status.json",
    "users.list": "district-scheduling-users.json",
    "users.upcomingBookings": "district-scheduling-user-upcoming.json",
    "teams.list": "district-scheduling-teams.json",
    "teams.get": "district-scheduling-team.json",
    "settings.branding.get": "district-scheduling-branding.json",
    "settings.llm.get": "district-scheduling-llm.json",
    "apiKeys.list": "district-scheduling-api-keys.json",
    "oauth.connections.list": "district-scheduling-oauth-connections.json",
    "webhooks.list": "district-scheduling-webhooks.json",
    "webhooks.deliveries": "district-scheduling-webhook-deliveries.json",
}


def rewrite(value, workspace):
    """Every `workspaceId` in a response, set to the one the request named."""
    if isinstance(value, dict):
        return {k: (workspace if k == "workspaceId" and isinstance(v, str) else rewrite(v, workspace))
                for k, v in value.items()}
    if isinstance(value, list):
        return [rewrite(v, workspace) for v in value]
    return value


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args) -> None:  # the MOCK lines below are the log
        return

    def _answer(self, status: int, body: bytes, label: str) -> None:
        print(f"MOCK {status} {self.command} {self.path} -> {label}", flush=True)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _fixture(self, name: str) -> None:
        path = next((d / name for d in FIXTURE_DIRS if (d / name).is_file()), FIXTURE_DIRS[-1] / name)
        if not path.is_file():
            self._missing(f"(fixture {name} absent)")
            return
        data = json.loads(path.read_bytes())
        # Every workspace is the agency's, so every section and control is offered, and
        # every response names the workspace the app asked about (the overview refuses
        # an answer for another one).
        if isinstance(data, dict) and isinstance(data.get("workspaces"), list):
            for workspace in data["workspaces"]:
                workspace["role"] = "agency"
        if isinstance(data, dict) and data.get("role") in ("client", "viewer"):
            data["role"] = "agency"
        if self.workspace:
            data = rewrite(data, self.workspace)
        self._answer(200, json.dumps(data).encode(), name)

    def _missing(self, label: str = "(no fixture)") -> None:
        body = json.dumps({"success": False, "error": "Not found", "code": "NOT_FOUND"}).encode()
        self._answer(404, body, label)

    def _route(self) -> None:
        url = urlparse(self.path)
        query = parse_qs(url.query)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        self.workspace = (query.get("workspaceId") or [""])[0]
        if not self.workspace and raw:
            try:
                body = json.loads(raw)
                self.workspace = body.get("workspaceId", "") if isinstance(body, dict) else ""
            except ValueError:
                pass
        if self.command == "POST" and url.path == D + "/scheduling/admin":
            try:
                op = json.loads(raw or b"{}").get("op", "")
            except ValueError:
                op = ""
            name = ADMIN_OPS.get(op)
            if name:
                self._fixture(name)
            else:
                self._answer(200, b'{"ok":true,"data":null}', f"(op {op}: generic ok)")
            return
        french = (self.headers.get("Accept-Language") or "").lower().startswith("fr")
        for method, pattern, predicate, name in ROUTES:
            if method != self.command or not re.fullmatch(pattern, url.path):
                continue
            if predicate == "fr" and not french:
                continue
            if callable(predicate) and not predicate(query):
                continue
            self._fixture(name)
            return
        if self.command in ("POST", "PATCH", "PUT", "DELETE"):
            self._answer(200, b'{"success":true}', "(write: generic success)")
            return
        self._missing()

    do_GET = do_POST = do_PATCH = do_PUT = do_DELETE = _route


class LoopbackServer(ThreadingHTTPServer):
    """Binds without HTTPServer's getfqdn() lookup, which on macOS asks the network for
    the host's name and raises the system's local-network prompt over the app under test."""

    def server_bind(self) -> None:
        import socketserver
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]


if __name__ == "__main__":
    print(f"MOCK serving {FIXTURE_DIRS} on 127.0.0.1:{PORT}", flush=True)
    LoopbackServer(("127.0.0.1", PORT), Handler).serve_forever()
