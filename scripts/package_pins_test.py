#!/usr/bin/env python3
"""Tests for package_pins.py that need no network.

    python3 scripts/package_pins_test.py
"""

from __future__ import annotations

import contextlib
import io
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import package_pins  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent

SPEC = """name: Example
options:
  bundleIdPrefix: com.example

packages:
  # A comment between packages.
  DistrictCore:
    url: https://github.com/distronode-corporation/district-core-swift
    exactVersion: 8.6.0
  swift-asn1:
    exactVersion: "1.7.3"
    url: https://github.com/apple/swift-asn1.git
  Quoted:
    url: "https://github.com/example/quoted"
    exactVersion: '2.4.0'
  Ranged:
    url: https://github.com/example/ranged
    from: 1.0.0
  Elsewhere:
    url: https://example.org/elsewhere
    exactVersion: 2.0.0

targets:
  App:
    type: application
    url: https://github.com/example/not-a-package
    exactVersion: 9.9.9
"""


class ParsePinsTests(unittest.TestCase):
    def test_reads_exact_github_pins_under_packages_only_in_any_key_order_and_quoting(self):
        pins = package_pins.parse_pins(SPEC)
        self.assertEqual(
            pins,
            [
                package_pins.Pin("DistrictCore", "distronode-corporation", "district-core-swift", "8.6.0"),
                package_pins.Pin("swift-asn1", "apple", "swift-asn1", "1.7.3"),
                package_pins.Pin("Quoted", "example", "quoted", "2.4.0"),
            ],
        )

    def test_this_repositorys_project_yml_has_pins(self):
        pins = package_pins.parse_pins((ROOT / "project.yml").read_text())
        names = {p.name for p in pins}
        self.assertIn("DistrictCore", names)
        self.assertIn("LiveKit", names)


class VersionTests(unittest.TestCase):
    def test_newer_compares_numerically_and_pads(self):
        self.assertTrue(package_pins.newer("v2.18.0", "2.17.0"))
        self.assertTrue(package_pins.newer("1.10.0", "1.9.9"))
        self.assertTrue(package_pins.newer("150.7871.3", "150.7871.2"))
        self.assertFalse(package_pins.newer("1.2", "1.2.0"))
        self.assertFalse(package_pins.newer("2.17.0", "2.17.0"))
        self.assertFalse(package_pins.newer("2.16.9", "2.17.0"))

    def test_a_release_is_newer_than_a_pre_release_pin_of_its_numbers(self):
        self.assertTrue(package_pins.newer("2.0.0", "2.0.0-beta.1"))
        self.assertTrue(package_pins.newer("2.1.0", "2.0.0-rc.2"))
        self.assertFalse(package_pins.newer("1.9.0", "2.0.0-beta.1"))
        self.assertTrue(package_pins.comparable("2.0.0-beta.1"))
        self.assertFalse(package_pins.comparable("main"))

    def test_a_pre_release_is_never_newer(self):
        self.assertFalse(package_pins.newer("3.0.0-beta.1", "2.17.0"))
        self.assertFalse(package_pins.newer("release-candidate", "2.17.0"))

    def test_highest_skips_pre_releases_and_non_versions(self):
        self.assertEqual(package_pins.highest(["1.2.0", "1.10.0", "2.0.0-rc1", "latest", "v1.9.0"]), "1.10.0")
        self.assertIsNone(package_pins.highest(["nightly", "2.0.0-beta"]))


class LatestReleaseTests(unittest.TestCase):
    pin = package_pins.Pin("X", "o", "r", "1.0.0")

    def test_uses_the_latest_release_when_it_is_a_version(self):
        with mock.patch.object(package_pins, "gh_json", return_value={"tag_name": "v1.4.0"}), \
                mock.patch.object(package_pins, "tag_names") as tags:
            self.assertEqual(package_pins.latest_release(self.pin), "v1.4.0")
            tags.assert_not_called()

    def test_falls_back_to_every_tag_without_a_release(self):
        names = [f"2.0.0-beta.{i}" for i in range(150)] + ["1.2.0", "1.3.0"]
        with mock.patch.object(package_pins, "gh_json", return_value=None), \
                mock.patch.object(package_pins, "tag_names", return_value=names):
            self.assertEqual(package_pins.latest_release(self.pin), "1.3.0")

    def test_falls_back_to_tags_when_the_release_is_not_a_version(self):
        with mock.patch.object(package_pins, "gh_json", return_value={"tag_name": "nightly-2026"}), \
                mock.patch.object(package_pins, "tag_names", return_value=["1.1.0"]):
            self.assertEqual(package_pins.latest_release(self.pin), "1.1.0")

    def test_none_when_nothing_is_readable(self):
        with mock.patch.object(package_pins, "gh_json", return_value=None), \
                mock.patch.object(package_pins, "tag_names", return_value=None):
            self.assertIsNone(package_pins.latest_release(self.pin))

    def test_tag_names_reads_every_page(self):
        done = mock.Mock(returncode=0, stdout="1.0.0\n1.1.0\n2.0.0\n")
        with mock.patch.object(package_pins.subprocess, "run", return_value=done) as run:
            self.assertEqual(package_pins.tag_names(self.pin), ["1.0.0", "1.1.0", "2.0.0"])
            self.assertIn("--paginate", run.call_args.args[0])


class IssueBodyTests(unittest.TestCase):
    def test_lists_each_update_with_its_releases_page(self):
        pin = package_pins.Pin("LiveKit", "livekit", "client-sdk-swift", "2.17.0")
        body = package_pins.issue_body([(pin, "2.18.0")], [])
        self.assertIn("| LiveKit | 2.17.0 | 2.18.0 | https://github.com/livekit/client-sdk-swift/releases |", body)
        self.assertNotIn("could be read", body)

    def test_an_unreadable_pin_keeps_the_issue_open_with_no_updates(self):
        other = package_pins.Pin("Sparkle", "sparkle-project", "Sparkle", "2.10.0")
        body = package_pins.issue_body([], [other])
        self.assertIn("found no `project.yml` pin behind among those it could read", body)
        self.assertIn("No release or version tag could be read, or the pin is not a comparable version, for: Sparkle.", body)

    def test_names_packages_with_nothing_readable(self):
        pin = package_pins.Pin("LiveKit", "livekit", "client-sdk-swift", "2.17.0")
        other = package_pins.Pin("Sparkle", "sparkle-project", "Sparkle", "2.10.0")
        body = package_pins.issue_body([(pin, "2.18.0")], [other])
        self.assertIn("No release or version tag could be read, or the pin is not a comparable version, for: Sparkle.", body)


class MainTests(unittest.TestCase):
    def run_main(self, latest):
        with mock.patch.object(sys, "argv", ["package_pins.py", "--issue"]), \
                mock.patch.object(package_pins, "latest_release", side_effect=latest), \
                mock.patch.object(package_pins, "sync_issue") as sync, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(package_pins.main(), 0)
        return sync.call_args.args[0]

    def test_closes_the_issue_only_when_every_pin_was_read_and_is_current(self):
        pins = package_pins.parse_pins((ROOT / "project.yml").read_text())
        self.assertIsNone(self.run_main(lambda pin: pin.version))
        body = self.run_main(lambda pin: None if pin.name == "LiveKit" else pin.version)
        self.assertIn("No release or version tag could be read, or the pin is not a comparable version, for: LiveKit.", body)
        self.assertGreater(len(pins), 1)


if __name__ == "__main__":
    unittest.main()
