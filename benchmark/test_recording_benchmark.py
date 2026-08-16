import base64
import json
import random
import subprocess
import tempfile
import threading
import time
import unittest
import wave
from pathlib import Path

import pandas as pd
import recording_benchmark as benchmark


def write_recording(
    root: Path,
    recording_id: str,
    duration: float,
    *,
    chunks: int = 1,
    malformed: bool = False,
) -> Path:
    directory = root / recording_id
    directory.mkdir()
    metadata_path = directory / "metadata.json"
    if malformed:
        metadata_path.write_text("not json", encoding="utf-8")
        return metadata_path

    audio = []
    for index in range(chunks):
        filename = f"chunk-{index + 1:04d}.m4a"
        (directory / filename).write_bytes(f"audio-{recording_id}-{index}".encode())
        audio.append(
            {
                "filename": filename,
                "durationSeconds": duration,
                "format": "m4a",
            }
        )
    metadata_path.write_text(
        json.dumps({"id": recording_id, "audio": audio}), encoding="utf-8"
    )
    return metadata_path


def write_valid_m4a(path: Path) -> None:
    wav_path = path.with_suffix(".source.wav")
    with wave.open(str(wav_path), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(16_000)
        wav_file.writeframes(b"\x00\x00" * 1_600)
    subprocess.run(
        [
            "afconvert",
            str(wav_path),
            "-o",
            str(path),
            "-f",
            "m4af",
            "-d",
            "aac",
            "-b",
            "32000",
        ],
        check=True,
        capture_output=True,
    )


def candidate(
    model: str, transcript: str = "sample transcript"
) -> benchmark.CandidateResult:
    return benchmark.CandidateResult(
        requested_model=model,
        success=True,
        transcript=transcript,
        latency_seconds=1.0,
        resolved_model=model,
        provider="mock-provider",
        usage={
            "input_tokens": 10,
            "output_tokens": 5,
            "total_tokens": 15,
            "cost": 0.01,
        },
    )


def score_payload(candidate_id: str, score: float = 90) -> dict:
    return {
        "candidate_id": candidate_id,
        **{field: score for field in benchmark.SCORE_FIELDS},
        "proper_noun_error": False,
        "number_error": False,
        "critical_errors": [],
    }


class FakeResponse:
    def __init__(self, status_code: int, payload: dict, headers: dict | None = None):
        self.status_code = status_code
        self._payload = payload
        self.headers = headers or {}
        self.text = json.dumps(payload)

    def json(self):
        return self._payload


class FakeBenchmarkClient:
    def post_json(self, url: str, payload: dict) -> benchmark.APICall:
        model = payload["model"]
        usage = {
            "input_tokens": 10,
            "output_tokens": 5,
            "total_tokens": 15,
            "cost": 0.01,
        }
        if model == benchmark.JUDGE_MODEL:
            judge_audio = payload["messages"][1]["content"][1]["input_audio"]
            if judge_audio["format"] != "wav":
                raise benchmark.APIRequestError("unsupported file type: m4a")
            candidate_ids = payload["response_format"]["json_schema"]["schema"][
                "properties"
            ]["candidates"]["items"]["properties"]["candidate_id"]["enum"]
            content = json.dumps(
                {
                    "judge_confidence": 95,
                    "candidates": [
                        score_payload(candidate_id, 90 - index)
                        for index, candidate_id in enumerate(candidate_ids)
                    ],
                }
            )
            response = {
                "model": model,
                "provider": "mock-judge",
                "usage": {**usage, "cost": 0.04},
                "choices": [{"message": {"content": content}}],
            }
        elif model == benchmark.GEMINI_MODEL:
            response = {
                "model": model,
                "provider": "mock-gemini",
                "usage": usage,
                "choices": [{"message": {"content": "gemini transcript"}}],
            }
        else:
            response = {
                "model": model,
                "provider": "mock-stt",
                "usage": usage,
                "text": f"{model} transcript",
            }
        return benchmark.APICall(response, {}, 1)


class SlowFakeBenchmarkClient(FakeBenchmarkClient):
    def __init__(self):
        self.active_calls = 0
        self.maximum_active_calls = 0
        self.lock = threading.Lock()

    def post_json(self, url: str, payload: dict) -> benchmark.APICall:
        with self.lock:
            self.active_calls += 1
            self.maximum_active_calls = max(
                self.maximum_active_calls, self.active_calls
            )
        try:
            time.sleep(0.02)
            return super().post_json(url, payload)
        finally:
            with self.lock:
                self.active_calls -= 1


class ReverseRng:
    def shuffle(self, values):
        values.reverse()


class SelectionTests(unittest.TestCase):
    def test_dynamic_selection_boundary_and_invalid_sessions(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for recording_id, duration in (
                ("under", 19.999),
                ("boundary", 20.0),
                ("short-two", 21.0),
                ("middle", 30.0),
                ("long-two", 40.0),
                ("longest", 50.0),
            ):
                write_recording(root, recording_id, duration)
            write_recording(root, "multi", 100.0, chunks=2)
            write_recording(root, "malformed", 100.0, malformed=True)

            selected = benchmark.select_recordings(
                benchmark.scan_recordings(root), group_size=2
            )
            self.assertEqual(
                [(item.recording_id, item.selection_group) for item in selected],
                [
                    ("boundary", "shortest"),
                    ("short-two", "shortest"),
                    ("long-two", "longest"),
                    ("longest", "longest"),
                ],
            )

            metadata = root / "middle" / "metadata.json"
            payload = json.loads(metadata.read_text(encoding="utf-8"))
            payload["audio"][0]["durationSeconds"] = 60
            metadata.write_text(json.dumps(payload), encoding="utf-8")
            rescanned = benchmark.select_recordings(
                benchmark.scan_recordings(root), group_size=2
            )
            self.assertEqual(rescanned[-1].recording_id, "middle")

    def test_limit_spans_shortest_middle_and_longest(self):
        recordings = [
            benchmark.Recording(str(value), value, Path("audio.m4a"), "m4a")
            for value in range(1, 10)
        ]
        self.assertEqual(
            [item.duration_seconds for item in benchmark.apply_limit(recordings, 3)],
            [1, 5, 9],
        )
        self.assertEqual(benchmark.apply_limit(recordings, 1)[0].duration_seconds, 5)


class RequestTests(unittest.TestCase):
    def test_prepare_judge_audio_converts_m4a_to_wav(self):
        with tempfile.TemporaryDirectory() as temporary:
            audio_path = Path(temporary) / "recording.m4a"
            write_valid_m4a(audio_path)
            encoded, audio_format = benchmark.prepare_judge_audio(audio_path, "m4a")
            wav_data = base64.b64decode(encoded)
            self.assertEqual(audio_format, "wav")
            self.assertEqual(wav_data[:4], b"RIFF")
            self.assertEqual(wav_data[8:12], b"WAVE")

    def test_candidate_request_construction(self):
        transcription = benchmark.build_transcription_request(
            "openai/gpt-transcribe", "AUDIO", "m4a"
        )
        self.assertEqual(
            transcription["input_audio"], {"data": "AUDIO", "format": "m4a"}
        )
        self.assertEqual(transcription["temperature"], 0)

        gemini = benchmark.build_gemini_request("AUDIO", "m4a")
        self.assertEqual(gemini["model"], benchmark.GEMINI_MODEL)
        self.assertEqual(gemini["reasoning"]["effort"], "low")
        self.assertIn("verbatim", json.dumps(gemini).lower())
        self.assertEqual(
            gemini["messages"][1]["content"][1]["input_audio"]["format"], "m4a"
        )

    def test_anonymous_order_and_judge_request(self):
        candidates = [
            candidate(model, f"text {index}")
            for index, model in enumerate(benchmark.CANDIDATE_MODELS)
        ]
        anonymous = benchmark.anonymize_candidates(candidates, ReverseRng())
        self.assertEqual(
            anonymous["Candidate A"].requested_model,
            benchmark.CANDIDATE_MODELS[-1],
        )

        request = benchmark.build_judge_request("AUDIO", "m4a", anonymous)
        request_text = json.dumps(request)
        self.assertEqual(request["reasoning"]["effort"], "high")
        self.assertTrue(request["response_format"]["json_schema"]["strict"])
        self.assertEqual(
            request["messages"][1]["content"][1]["input_audio"]["format"], "m4a"
        )
        for model in benchmark.CANDIDATE_MODELS:
            self.assertNotIn(model, request_text)

    def test_retry_once_and_fatal_authentication(self):
        responses = iter(
            [
                FakeResponse(429, {"error": {"message": "slow down"}}),
                FakeResponse(200, {"text": "ok"}),
            ]
        )
        delays = []
        client = benchmark.OpenRouterClient(
            "secret", post=lambda *args, **kwargs: next(responses), sleep=delays.append
        )
        result = client.post_json("https://example.test", {})
        self.assertEqual(result.attempts, 2)
        self.assertEqual(delays, [1.0])

        fatal_client = benchmark.OpenRouterClient(
            "secret",
            post=lambda *args, **kwargs: FakeResponse(
                401, {"error": {"message": "invalid key"}}
            ),
            sleep=lambda _: None,
        )
        with self.assertRaises(benchmark.FatalAPIError):
            fatal_client.post_json("https://example.test", {})

        provider_error_client = benchmark.OpenRouterClient(
            "secret",
            post=lambda *args, **kwargs: FakeResponse(
                400,
                {
                    "error": {
                        "message": "Provider returned error",
                        "metadata": {
                            "provider_name": "Meta",
                            "raw": json.dumps(
                                {"error": {"message": "unsupported file type: m4a"}}
                            ),
                        },
                    }
                },
            ),
        )
        with self.assertRaisesRegex(benchmark.APIRequestError, "unsupported file type"):
            provider_error_client.post_json("https://example.test", {})

    def test_generation_metadata_fills_stt_provider(self):
        client = benchmark.OpenRouterClient(
            "secret",
            post=lambda *args, **kwargs: FakeResponse(
                200,
                {"text": "hello", "usage": {"cost": 0.1}},
                {"X-Generation-Id": "gen-test"},
            ),
            get=lambda *args, **kwargs: FakeResponse(
                200,
                {
                    "data": {
                        "model": "openai/whisper-large-v3",
                        "provider_name": "Groq",
                    }
                },
            ),
        )
        result = benchmark.run_candidate(
            client, "openai/whisper-large-v3", "AUDIO", "m4a"
        )
        result = benchmark.enrich_candidate_metadata(client, [result])[0]
        self.assertTrue(result.success)
        self.assertEqual(result.provider, "Groq")
        self.assertEqual(result.generation_id, "gen-test")

    def test_generation_metadata_retries_eventual_404_once(self):
        responses = iter(
            [
                FakeResponse(404, {"error": {"message": "not ready"}}),
                FakeResponse(200, {"data": {"provider_name": "DeepInfra"}}),
            ]
        )
        delays = []
        client = benchmark.OpenRouterClient(
            "secret",
            get=lambda *args, **kwargs: next(responses),
            sleep=delays.append,
        )
        metadata = client.get_generation_metadata("gen-test")
        self.assertEqual(metadata["provider_name"], "DeepInfra")
        self.assertEqual(delays, [5.0])


class JudgeAndStatisticsTests(unittest.TestCase):
    def test_judge_parsing_and_weighted_score(self):
        fields = {
            "verbatim_word_accuracy": 100,
            "proper_nouns_and_technical_identifiers": 90,
            "numbers_versions_dates_urls_paths_and_units": 80,
            "completeness_and_quiet_speech_preservation": 70,
            "meaning_negation_uncertainty_and_corrections": 60,
            "hallucination_and_background_speech_avoidance": 50,
            "punctuation": 40,
            "capitalization": 30,
            "segmentation": 20,
            "readability": 10,
        }
        payload = {
            "judge_confidence": 88,
            "candidates": [
                {
                    "candidate_id": "Candidate A",
                    **fields,
                    "proper_noun_error": True,
                    "number_error": False,
                    "critical_errors": ["lost negation"],
                }
            ],
        }
        parsed = benchmark.parse_judge_response(json.dumps(payload), ["Candidate A"])
        self.assertEqual(parsed.confidence, 88)
        self.assertAlmostEqual(
            parsed.candidates["Candidate A"].weighted_accuracy,
            79.5,
        )
        self.assertEqual(
            parsed.candidates["Candidate A"].critical_errors,
            ("lost negation",),
        )

    def test_mocked_complete_pipeline_and_aggregation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            recordings = []
            for index, duration in enumerate((20.0, 21.0, 50.0, 60.0)):
                metadata_path = write_recording(root, f"recording-{index}", duration)
                recordings.append(
                    benchmark.Recording(
                        recording_id=f"recording-{index}",
                        duration_seconds=duration,
                        audio_path=metadata_path.parent / "chunk-0001.m4a",
                        audio_format="m4a",
                        selection_group="shortest" if index < 2 else "longest",
                    )
                )

            output = benchmark.BenchmarkRunner(
                FakeBenchmarkClient(),
                rng=random.Random(7),
                judge_audio_preparer=lambda _path, _format: ("WAV_AUDIO", "wav"),
            ).run(recordings, root / "output", print_output=False)

            self.assertEqual(len(output.results), 16)
            self.assertTrue(output.results["success"].all())
            self.assertTrue(output.results["judge_success"].all())
            self.assertEqual(
                set(output.results["winner_status"]), {"tie", "not_winner"}
            )
            self.assertAlmostEqual(output.results["cost_usd"].sum(), 0.32)
            self.assertTrue(output.results_path.is_file())
            self.assertTrue(output.stats_path.is_file())
            self.assertTrue(output.report_path.is_file())
            self.assertEqual(
                {path.name for path in output.run_directory.iterdir()},
                {"results.csv", "stats.csv", "report.html"},
            )
            report = output.report_path.read_text(encoding="utf-8")
            self.assertIn("Overall ranking", report)
            self.assertIn("Full described statistics", report)
            self.assertIn("How to read this", report)
            self.assertIn("GPT Transcribe", report)

            stats = pd.read_csv(output.stats_path)
            self.assertIn("95%", stats.columns)
            self.assertEqual(
                set(stats["selection_group"]), {"all", "shortest", "longest"}
            )
            self.assertEqual(
                len(stats[stats["table"] == "ranking"]),
                len(benchmark.CANDIDATE_MODELS),
            )

    def test_recording_workers_run_concurrently(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            recordings = []
            for index in range(2):
                metadata_path = write_recording(root, f"parallel-{index}", 20 + index)
                recordings.append(
                    benchmark.Recording(
                        recording_id=f"parallel-{index}",
                        duration_seconds=20 + index,
                        audio_path=metadata_path.parent / "chunk-0001.m4a",
                        audio_format="m4a",
                        selection_group="shortest",
                    )
                )
            client = SlowFakeBenchmarkClient()
            output = benchmark.BenchmarkRunner(
                client,
                rng=random.Random(7),
                judge_audio_preparer=lambda _path, _format: ("WAV_AUDIO", "wav"),
            ).run(
                recordings,
                root / "parallel-output",
                print_output=False,
                workers=2,
            )
            self.assertGreater(
                client.maximum_active_calls, len(benchmark.CANDIDATE_MODELS)
            )
            self.assertEqual(
                output.results["recording_id"].drop_duplicates().tolist(),
                ["parallel-0", "parallel-1"],
            )


if __name__ == "__main__":
    unittest.main()
