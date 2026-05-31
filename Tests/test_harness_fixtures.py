from __future__ import annotations

import argparse
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import lyrics_visual_harness as visual  # noqa: E402
import luxb_sequential_reference as sequential_reference  # noqa: E402
import perf_harness as perf  # noqa: E402


class HarnessFixtureTests(unittest.TestCase):
    def test_line_breakup_truth_is_locked_line_workload(self) -> None:
        fixture = visual.FIXTURES["line-breakup-truth"]

        self.assertEqual(fixture["title"], "分手真相")
        self.assertEqual(fixture["artist"], "Alvin Kwok")
        self.assertEqual(fixture["album"], "Steel Box Collection: Alvin Kwok")
        self.assertEqual(fixture["genre"], "Cantopop/HK-Pop")
        self.assertEqual(fixture["duration"], 250)
        self.assertEqual(fixture["expect_lyrics"], "line")
        self.assertFalse(fixture["expect_translation"])
        self.assertEqual(fixture["expect_selected_source"], "NetEase")
        self.assertEqual(fixture["expect_lyrics_line_count"], 42)
        self.assertEqual(
            fixture["expect_first_real_line_sha256"],
            "c3925990fd25b5c0a4891ef23968b2acd3d7db1e4d71fbb9cfdfeefdd2231ae9",
        )

    def test_winter_trip_metadata_matches_owner_fixture(self) -> None:
        fixture = visual.FIXTURES["line-winter-trip"]

        self.assertEqual(fixture["album"], "冬天一個遊 - Single")
        self.assertEqual(fixture["genre"], "R&B/Soul")

    def test_perf_harness_resolves_breakup_truth_fixture(self) -> None:
        parser = argparse.ArgumentParser()
        args = SimpleNamespace(
            page="lyrics",
            fixture="line-breakup-truth",
            play_title=None,
            play_artist=None,
            play_duration=None,
            expect_lyrics="fixture",
            expect_translation=None,
            duration=16.0,
            warmup=8.0,
            interval=0.5,
            seek_position=None,
            interaction="scroll-tap-jump",
            interaction_interval=3.0,
            label="perf",
            output_dir=str(ROOT / "tmp" / "perf"),
            require_music_playing=True,
            skip_playback_control=False,
            dry_run=True,
        )

        resolved = perf.resolve_args(parser, args)

        self.assertEqual(resolved.play_title, "分手真相")
        self.assertEqual(resolved.play_artist, "Alvin Kwok")
        self.assertEqual(resolved.play_album, "Steel Box Collection: Alvin Kwok")
        self.assertEqual(resolved.play_duration, 250.0)
        self.assertEqual(resolved.expect_lyrics, "line")
        self.assertFalse(resolved.expect_translation)
        self.assertEqual(resolved.expect_selected_source, "NetEase")
        self.assertEqual(resolved.expect_lyrics_line_count, 42)
        self.assertEqual(
            resolved.expect_first_real_line_sha256,
            "c3925990fd25b5c0a4891ef23968b2acd3d7db1e4d71fbb9cfdfeefdd2231ae9",
        )

    def test_perf_harness_requires_album_when_fixture_has_album(self) -> None:
        request = SimpleNamespace(
            play_title="分手真相",
            play_artist="Alvin Kwok",
            play_album="Steel Box Collection: Alvin Kwok",
        )

        self.assertTrue(perf.track_matches_request(
            {
                "title": "分手真相",
                "artist": "Alvin Kwok",
                "album": "Steel Box Collection: Alvin Kwok",
            },
            request,
        ))
        self.assertFalse(perf.track_matches_request(
            {
                "title": "分手真相",
                "artist": "Alvin Kwok",
                "album": "Different Collection",
            },
            request,
        ))

    def test_sequential_reference_extracts_cpu_average(self) -> None:
        self.assertEqual(
            sequential_reference.cpu_avg({
                "perfSummary": {
                    "measurement": {
                        "cpuPercent": {
                            "avg": 12.5,
                        },
                    },
                },
            }),
            12.5,
        )
        self.assertIsNone(sequential_reference.cpu_avg({"perfSummary": {}}))

    def test_sequential_reference_rejects_zero_error_motion_reference(self) -> None:
        signal = sequential_reference.motion_reference_comparability(
            sequential_reference.motion.MotionMetrics(
                sample_count=10,
                target_error_y_max=0,
                inter_line_delta_error_y_max=0,
                active_target_settle_time_max=0,
            )
        )

        self.assertFalse(signal["comparable"])
        self.assertIn("target-layout", signal["reason"])


if __name__ == "__main__":
    unittest.main()
