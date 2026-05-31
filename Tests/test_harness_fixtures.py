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
        run_summary = {
            "perfSummary": {
                "measurement": {
                    "cpuPercent": {
                        "avg": 12.5,
                        "p95": 28.0,
                        "max": 32.0,
                    },
                },
            },
        }

        self.assertEqual(sequential_reference.cpu_avg(run_summary), 12.5)
        self.assertEqual(
            sequential_reference.cpu_stats(run_summary),
            {
                "avg": 12.5,
                "p95": 28.0,
                "max": 32.0,
            },
        )
        self.assertEqual(sequential_reference.cpu_stats({"perfSummary": {}}), {})

    def test_sequential_reference_fails_cpu_spike_regression(self) -> None:
        reference = {
            "perfSummary": {
                "measurement": {
                    "cpuPercent": {
                        "avg": 20.0,
                        "p95": 40.0,
                        "max": 45.0,
                    },
                },
            },
        }
        candidate = {
            "perfSummary": {
                "measurement": {
                    "cpuPercent": {
                        "avg": 10.0,
                        "p95": 30.0,
                        "max": 46.0,
                    },
                },
            },
        }

        avg_ratio, ratios, failures = sequential_reference.compare_cpu_stats(
            sequential_reference.cpu_stats(reference),
            sequential_reference.cpu_stats(candidate),
            max_avg_ratio=1.0,
        )

        self.assertEqual(avg_ratio, 0.5)
        self.assertEqual(ratios["p95"], 0.75)
        self.assertGreater(ratios["max"], 1.0)
        self.assertEqual(failures, ["candidate CPU max 46.000 > reference 45.000"])

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

    def test_motion_compare_ignores_unusable_zero_settle_baseline(self) -> None:
        baseline = sequential_reference.motion.MotionMetrics(
            sample_count=20,
            active_target_settle_time_max=0,
            active_target_settle_skipped_count=3,
        )
        candidate = sequential_reference.motion.MotionMetrics(
            sample_count=40,
            active_target_settle_time_max=0.25,
        )

        self.assertEqual(sequential_reference.motion.compare_metrics(candidate, baseline), [])

    def test_sequential_reference_compares_wave_cadence_and_order(self) -> None:
        baseline = sequential_reference.motion.WaveTimelineMetrics(
            sample_count=20,
            scheduled_count=10,
            fired_count=10,
            target_radius_max=14,
            lead_in_rows_max=3,
            cadence_p95=0.08,
        )
        candidate = sequential_reference.motion.WaveTimelineMetrics(
            sample_count=20,
            scheduled_count=10,
            fired_count=10,
            target_radius_max=14,
            lead_in_rows_max=3,
            cadence_p95=0.08,
        )

        self.assertEqual(sequential_reference.compare_wave_metrics(candidate, baseline), [])

        candidate.order_violation_count = 1
        self.assertIn(
            "candidate wave order violations worse than reference",
            sequential_reference.compare_wave_metrics(candidate, baseline),
        )


if __name__ == "__main__":
    unittest.main()
