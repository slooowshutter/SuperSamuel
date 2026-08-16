#!/usr/bin/env python3
"""Benchmark OpenRouter transcription models against saved SuperSamuel audio."""

from __future__ import annotations

import argparse
import base64
import hashlib
import html
import json
import math
import os
import random
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable, Iterable, Mapping, Sequence
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import pandas as pd
import requests
from tqdm import tqdm

OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"
TRANSCRIPTION_URL = f"{OPENROUTER_BASE_URL}/audio/transcriptions"
CHAT_URL = f"{OPENROUTER_BASE_URL}/chat/completions"
GENERATION_URL = f"{OPENROUTER_BASE_URL}/generation"

GEMINI_MODEL = "google/gemini-3.7-flash"
TRANSCRIPTION_MODELS = (
    "openai/gpt-transcribe",
    "openai/whisper-large-v3",
    "mistralai/voxtral-mini-transcribe",
)
CANDIDATE_MODELS = (GEMINI_MODEL, *TRANSCRIPTION_MODELS)
JUDGE_MODEL = "meta/muse-spark-1.2"

MODEL_LABELS = {
    GEMINI_MODEL: "Gemini 3.7 Flash",
    "openai/gpt-transcribe": "GPT Transcribe",
    "openai/whisper-large-v3": "Whisper Large V3",
    "mistralai/voxtral-mini-transcribe": "Voxtral Mini Transcribe",
}

CRITERION_WEIGHTS = {
    "verbatim_word_accuracy": 0.25,
    "proper_nouns_and_technical_identifiers": 0.20,
    "numbers_versions_dates_urls_paths_and_units": 0.15,
    "completeness_and_quiet_speech_preservation": 0.15,
    "meaning_negation_uncertainty_and_corrections": 0.15,
    "hallucination_and_background_speech_avoidance": 0.10,
}
UNWEIGHTED_CRITERIA = (
    "punctuation",
    "capitalization",
    "segmentation",
    "readability",
)
METRIC_LABELS = {
    "total_accuracy_score": "Weighted accuracy",
    "verbatim_word_accuracy": "Verbatim word accuracy",
    "proper_nouns_and_technical_identifiers": "Proper nouns & technical identifiers",
    "numbers_versions_dates_urls_paths_and_units": "Numbers, versions, dates, URLs, paths & units",
    "completeness_and_quiet_speech_preservation": "Completeness & quiet speech",
    "meaning_negation_uncertainty_and_corrections": "Meaning, negation, uncertainty & corrections",
    "hallucination_and_background_speech_avoidance": "Hallucination & background-speech avoidance",
    "punctuation": "Punctuation",
    "capitalization": "Capitalization",
    "segmentation": "Segmentation",
    "readability": "Readability",
    "latency_seconds": "Latency (seconds)",
    "realtime_factor": "Realtime factor",
    "cost_usd": "Cost (USD)",
}
SCORE_FIELDS = (*CRITERION_WEIGHTS.keys(), *UNWEIGHTED_CRITERIA)
DESCRIBE_FIELDS = (
    "count",
    "mean",
    "std",
    "min",
    "25%",
    "50%",
    "75%",
    "90%",
    "95%",
    "max",
)

DEFAULT_HISTORY_DIRECTORY = Path(
    "/Users/marclamy/Library/Application Support/SuperSamuel/Transcript History"
)
DEFAULT_OUTPUT_DIRECTORY = (
    Path(__file__).resolve().parents[1] / ".context" / "recording-benchmark"
)


@dataclass(frozen=True)
class Recording:
    recording_id: str
    duration_seconds: float
    audio_path: Path
    audio_format: str
    selection_group: str = ""


@dataclass(frozen=True)
class APICall:
    payload: dict[str, Any]
    headers: Mapping[str, str]
    attempts: int


@dataclass(frozen=True)
class CandidateResult:
    requested_model: str
    success: bool
    transcript: str = ""
    error: str = ""
    latency_seconds: float | None = None
    resolved_model: str = ""
    provider: str = ""
    generation_id: str = ""
    usage: Mapping[str, Any] | None = None


@dataclass(frozen=True)
class JudgeScore:
    scores: Mapping[str, float]
    proper_noun_error: bool
    number_error: bool
    critical_errors: tuple[str, ...]

    @property
    def weighted_accuracy(self) -> float:
        return calculate_weighted_score(self.scores)


@dataclass(frozen=True)
class ParsedJudge:
    confidence: float
    candidates: Mapping[str, JudgeScore]


@dataclass(frozen=True)
class JudgeResult:
    success: bool
    scores_by_model: Mapping[str, JudgeScore]
    confidence: float | None = None
    error: str = ""
    latency_seconds: float | None = None
    resolved_model: str = ""
    provider: str = ""
    generation_id: str = ""
    usage: Mapping[str, Any] | None = None


@dataclass(frozen=True)
class BenchmarkOutput:
    run_directory: Path
    results_path: Path
    stats_path: Path
    report_path: Path
    results: pd.DataFrame
    stats: pd.DataFrame


@dataclass(frozen=True)
class RecordingResult:
    index: int
    recording: Recording
    audio_sha256: str
    candidates: Sequence[CandidateResult]
    judge: JudgeResult


class BenchmarkError(RuntimeError):
    """A benchmark configuration or response error."""


class APIRequestError(BenchmarkError):
    """An isolated API request failure."""


class FatalAPIError(APIRequestError):
    """An authentication or billing failure that must stop the run."""


def scan_recordings(history_directory: Path) -> list[Recording]:
    """Read valid, single-chunk recordings from Transcript History."""
    recordings: list[Recording] = []
    if not history_directory.is_dir():
        raise BenchmarkError(f"Transcript History does not exist: {history_directory}")

    for metadata_path in sorted(history_directory.glob("*/metadata.json")):
        try:
            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
            audio_entries = metadata["audio"]
            if not isinstance(audio_entries, list) or len(audio_entries) != 1:
                continue

            audio = audio_entries[0]
            if not isinstance(audio, dict):
                continue
            duration = float(audio["durationSeconds"])
            if not math.isfinite(duration) or duration <= 0:
                continue

            filename = audio["filename"]
            if (
                not isinstance(filename, str)
                or not filename
                or Path(filename).name != filename
            ):
                continue
            audio_path = metadata_path.parent / filename
            if not audio_path.is_file():
                continue

            recording_id = str(metadata.get("id") or metadata_path.parent.name)
            audio_format = str(
                audio.get("format") or audio_path.suffix.lstrip(".")
            ).lower()
            if not audio_format:
                continue
            recordings.append(
                Recording(
                    recording_id=recording_id,
                    duration_seconds=duration,
                    audio_path=audio_path,
                    audio_format=audio_format,
                )
            )
        except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError):
            continue

    return recordings


def select_recordings(
    recordings: Sequence[Recording],
    group_size: int = 50,
    minimum_short_duration: float = 20.0,
) -> list[Recording]:
    """Select the shortest eligible and longest recordings as disjoint groups."""
    if group_size <= 0:
        raise ValueError("group_size must be positive")

    shortest_pool = sorted(
        (
            item
            for item in recordings
            if item.duration_seconds >= minimum_short_duration
        ),
        key=lambda item: (item.duration_seconds, item.recording_id),
    )
    longest_pool = sorted(
        recordings,
        key=lambda item: (-item.duration_seconds, item.recording_id),
    )
    if len(shortest_pool) < group_size or len(longest_pool) < group_size:
        raise BenchmarkError(
            f"Need at least {group_size} valid recordings and {group_size} recordings "
            f"lasting at least {minimum_short_duration:g} seconds"
        )

    shortest = shortest_pool[:group_size]
    longest = longest_pool[:group_size]
    overlap = {item.recording_id for item in shortest} & {
        item.recording_id for item in longest
    }
    if overlap:
        raise BenchmarkError(
            f"The corpus does not contain {group_size * 2} disjoint shortest/longest recordings"
        )

    selected = [
        Recording(
            recording_id=item.recording_id,
            duration_seconds=item.duration_seconds,
            audio_path=item.audio_path,
            audio_format=item.audio_format,
            selection_group="shortest",
        )
        for item in shortest
    ]
    selected.extend(
        Recording(
            recording_id=item.recording_id,
            duration_seconds=item.duration_seconds,
            audio_path=item.audio_path,
            audio_format=item.audio_format,
            selection_group="longest",
        )
        for item in longest
    )
    return sorted(selected, key=lambda item: (item.duration_seconds, item.recording_id))


def apply_limit(recordings: Sequence[Recording], limit: int | None) -> list[Recording]:
    """Evenly sample selected durations, including both endpoints when possible."""
    ordered = sorted(
        recordings, key=lambda item: (item.duration_seconds, item.recording_id)
    )
    if limit is None or limit >= len(ordered):
        return ordered
    if limit <= 0:
        raise ValueError("limit must be positive")
    if limit == 1:
        return [ordered[len(ordered) // 2]]

    last_index = len(ordered) - 1
    indices = [int((index * last_index / (limit - 1)) + 0.5) for index in range(limit)]
    return [ordered[index] for index in indices]


def encode_audio(audio_path: Path) -> tuple[str, str]:
    audio_data = audio_path.read_bytes()
    return base64.b64encode(audio_data).decode("ascii"), hashlib.sha256(
        audio_data
    ).hexdigest()


def prepare_judge_audio(audio_path: Path, audio_format: str) -> tuple[str, str]:
    """Return WAV audio for Muse without changing the archived source recording."""
    if audio_format.lower() == "wav":
        return base64.b64encode(audio_path.read_bytes()).decode("ascii"), "wav"

    with tempfile.TemporaryDirectory(prefix="supersamuel-judge-") as directory:
        wav_path = Path(directory) / "judge.wav"
        try:
            conversion = subprocess.run(
                [
                    "afconvert",
                    str(audio_path),
                    "-o",
                    str(wav_path),
                    "-f",
                    "WAVE",
                    "-d",
                    "LEI16@16000",
                    "-c",
                    "1",
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=300,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired) as error:
            raise BenchmarkError(
                f"Could not prepare WAV audio for Muse: {error}"
            ) from error
        if conversion.returncode != 0:
            message = conversion.stderr.strip() or "afconvert failed"
            raise BenchmarkError(
                f"Could not prepare WAV audio for Muse: {message[:500]}"
            )
        try:
            wav_data = wav_path.read_bytes()
        except OSError as error:
            raise BenchmarkError(f"Could not read Muse WAV audio: {error}") from error
        if len(wav_data) < 12 or wav_data[:4] != b"RIFF" or wav_data[8:12] != b"WAVE":
            raise BenchmarkError("afconvert did not produce a valid WAV file for Muse")
        return base64.b64encode(wav_data).decode("ascii"), "wav"


def build_transcription_request(
    model: str, audio_base64: str, audio_format: str
) -> dict[str, Any]:
    return {
        "model": model,
        "input_audio": {"data": audio_base64, "format": audio_format},
        "temperature": 0,
    }


def build_gemini_request(audio_base64: str, audio_format: str) -> dict[str, Any]:
    return {
        "model": GEMINI_MODEL,
        "messages": [
            {
                "role": "system",
                "content": (
                    "You are a transcription engine. Produce a verbatim transcript of the "
                    "provided recording. Preserve false starts, repetitions, filler words, "
                    "corrections, uncertainty, names, numbers, URLs, paths, versions, and quiet "
                    "speech. Ignore unrelated background speech. Do not summarize, rewrite, "
                    "answer, explain, or add text. Return only the transcript."
                ),
            },
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": "Transcribe this recording verbatim. Return only the transcript.",
                    },
                    {
                        "type": "input_audio",
                        "input_audio": {"data": audio_base64, "format": audio_format},
                    },
                ],
            },
        ],
        "reasoning": {"effort": "low", "exclude": True},
        "temperature": 0,
        "usage": {"include": True},
    }


def anonymize_candidates(
    candidates: Sequence[CandidateResult], rng: random.Random
) -> dict[str, CandidateResult]:
    shuffled = list(candidates)
    rng.shuffle(shuffled)
    return {
        f"Candidate {chr(ord('A') + index)}": candidate
        for index, candidate in enumerate(shuffled)
    }


def _judge_schema(candidate_ids: Sequence[str]) -> dict[str, Any]:
    score_properties = {
        field: {"type": "number", "minimum": 0, "maximum": 100}
        for field in SCORE_FIELDS
    }
    candidate_properties: dict[str, Any] = {
        "candidate_id": {"type": "string", "enum": list(candidate_ids)},
        **score_properties,
        "proper_noun_error": {"type": "boolean"},
        "number_error": {"type": "boolean"},
        "critical_errors": {
            "type": "array",
            "items": {"type": "string"},
            "maxItems": 20,
        },
    }
    return {
        "type": "object",
        "properties": {
            "judge_confidence": {"type": "number", "minimum": 0, "maximum": 100},
            "candidates": {
                "type": "array",
                "minItems": len(candidate_ids),
                "maxItems": len(candidate_ids),
                "items": {
                    "type": "object",
                    "properties": candidate_properties,
                    "required": list(candidate_properties),
                    "additionalProperties": False,
                },
            },
        },
        "required": ["judge_confidence", "candidates"],
        "additionalProperties": False,
    }


def build_judge_request(
    audio_base64: str,
    audio_format: str,
    anonymous_candidates: Mapping[str, CandidateResult],
) -> dict[str, Any]:
    candidate_text = "\n\n".join(
        f"{candidate_id}:\n{candidate.transcript}"
        for candidate_id, candidate in anonymous_candidates.items()
    )
    prompt = f"""
Listen closely to the original recording, then score each anonymous transcript independently.
Candidate labels are randomized and reveal nothing about the source model.

Use integer-like scores from 0 to 100. The six weighted accuracy criteria are:
- verbatim_word_accuracy (25%): exact spoken wording, including fillers, false starts, and repetitions.
- proper_nouns_and_technical_identifiers (20%): people, products, commands, symbols, filenames, and code identifiers.
- numbers_versions_dates_urls_paths_and_units (15%): every concrete structured value and its formatting.
- completeness_and_quiet_speech_preservation (15%): no dropped phrases, including quiet speech.
- meaning_negation_uncertainty_and_corrections (15%): preserve intent, negation, hedging, and the speaker's correction sequence.
- hallucination_and_background_speech_avoidance (10%): no invented words or unrelated background speech.

Also score punctuation, capitalization, segmentation, and readability from 0 to 100. These four
scores are diagnostic only and do not affect weighted accuracy. Set proper_noun_error or
number_error when at least one such error is present. List only meaningfully consequential errors
under critical_errors; use an empty list when there are none. Judge confidence describes how
clearly the audio supports the comparison. Do not reward polished paraphrasing over verbatimness.

Anonymous transcripts:
{candidate_text}
""".strip()
    candidate_ids = list(anonymous_candidates)
    return {
        "model": JUDGE_MODEL,
        "provider": {"require_parameters": True},
        "messages": [
            {
                "role": "system",
                "content": (
                    "You are a meticulous blind transcription evaluator. Treat the audio as the "
                    "only source of truth and follow the response schema exactly."
                ),
            },
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {
                        "type": "input_audio",
                        "input_audio": {"data": audio_base64, "format": audio_format},
                    },
                ],
            },
        ],
        "reasoning": {"effort": "high", "exclude": True},
        "temperature": 0,
        "usage": {"include": True},
        "response_format": {
            "type": "json_schema",
            "json_schema": {
                "name": "transcription_benchmark_scores",
                "strict": True,
                "schema": _judge_schema(candidate_ids),
            },
        },
    }


def calculate_weighted_score(scores: Mapping[str, float]) -> float:
    try:
        return sum(
            float(scores[field]) * weight for field, weight in CRITERION_WEIGHTS.items()
        )
    except (KeyError, TypeError, ValueError) as error:
        raise BenchmarkError(f"Cannot calculate weighted score: {error}") from error


def parse_judge_response(content: str, expected_ids: Iterable[str]) -> ParsedJudge:
    try:
        payload = json.loads(content)
    except json.JSONDecodeError as error:
        raise BenchmarkError(f"Judge returned invalid JSON: {error}") from error
    if not isinstance(payload, dict):
        raise BenchmarkError("Judge response must be an object")

    confidence = _score_number(payload.get("judge_confidence"), "judge_confidence")
    candidate_payloads = payload.get("candidates")
    if not isinstance(candidate_payloads, list):
        raise BenchmarkError("Judge response candidates must be an array")

    expected = set(expected_ids)
    parsed: dict[str, JudgeScore] = {}
    for item in candidate_payloads:
        if not isinstance(item, dict):
            raise BenchmarkError("Each judge candidate must be an object")
        candidate_id = item.get("candidate_id")
        if not isinstance(candidate_id, str) or candidate_id not in expected:
            raise BenchmarkError(f"Unexpected judge candidate: {candidate_id!r}")
        if candidate_id in parsed:
            raise BenchmarkError(f"Duplicate judge candidate: {candidate_id}")

        scores = {
            field: _score_number(item.get(field), field) for field in SCORE_FIELDS
        }
        proper_noun_error = item.get("proper_noun_error")
        number_error = item.get("number_error")
        critical_errors = item.get("critical_errors")
        if not isinstance(proper_noun_error, bool) or not isinstance(
            number_error, bool
        ):
            raise BenchmarkError("Judge error flags must be booleans")
        if not isinstance(critical_errors, list) or not all(
            isinstance(value, str) for value in critical_errors
        ):
            raise BenchmarkError("Judge critical_errors must be an array of strings")
        parsed[candidate_id] = JudgeScore(
            scores=scores,
            proper_noun_error=proper_noun_error,
            number_error=number_error,
            critical_errors=tuple(critical_errors),
        )

    if set(parsed) != expected:
        missing = ", ".join(sorted(expected - set(parsed)))
        raise BenchmarkError(f"Judge response is missing candidates: {missing}")
    return ParsedJudge(confidence=confidence, candidates=parsed)


def _score_number(value: Any, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise BenchmarkError(f"Judge field {field} must be numeric")
    number = float(value)
    if not math.isfinite(number) or number < 0 or number > 100:
        raise BenchmarkError(f"Judge field {field} must be between 0 and 100")
    return number


class OpenRouterClient:
    def __init__(
        self,
        api_key: str,
        post: Callable[..., Any] = requests.post,
        get: Callable[..., Any] = requests.get,
        sleep: Callable[[float], None] = time.sleep,
        timeout: tuple[float, float] = (30.0, 900.0),
    ) -> None:
        self._post = post
        self._get = get
        self._sleep = sleep
        self._timeout = timeout
        self._headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "X-OpenRouter-Title": "SuperSamuel Recording Benchmark",
        }

    def post_json(self, url: str, payload: Mapping[str, Any]) -> APICall:
        started = time.monotonic()
        for attempt in (1, 2):
            try:
                response = self._post(
                    url,
                    headers=self._headers,
                    json=payload,
                    timeout=self._timeout,
                )
            except (requests.Timeout, requests.ConnectionError) as error:
                if attempt == 1:
                    self._sleep(1.0)
                    continue
                raise APIRequestError(
                    f"Request failed after one retry: {error}"
                ) from error

            status = int(response.status_code)
            if status in (401, 402):
                raise FatalAPIError(
                    f"OpenRouter authentication/billing failure ({status}): "
                    f"{_response_error(response)}"
                )
            if status == 429 or status == 408 or 500 <= status <= 599:
                if attempt == 1:
                    retry_after = response.headers.get("Retry-After", "1")
                    try:
                        delay = min(max(float(retry_after), 0.0), 30.0)
                    except ValueError:
                        delay = 1.0
                    self._sleep(delay)
                    continue
                raise APIRequestError(
                    f"OpenRouter request failed after one retry ({status}): "
                    f"{_response_error(response)}"
                )
            if status < 200 or status >= 300:
                raise APIRequestError(
                    f"OpenRouter request failed ({status}): {_response_error(response)}"
                )

            try:
                response_payload = response.json()
            except (ValueError, json.JSONDecodeError) as error:
                raise APIRequestError(
                    "OpenRouter returned a non-JSON response"
                ) from error
            if not isinstance(response_payload, dict):
                raise APIRequestError("OpenRouter returned a non-object response")
            return APICall(response_payload, response.headers, attempt)

        elapsed = time.monotonic() - started
        raise APIRequestError(f"OpenRouter request failed after {elapsed:.1f}s")

    def get_generation_metadata(self, generation_id: str) -> Mapping[str, Any]:
        """Fetch provider/model metadata omitted from transcription responses."""
        for attempt in (1, 2):
            try:
                response = self._get(
                    GENERATION_URL,
                    headers=self._headers,
                    params={"id": generation_id},
                    timeout=(self._timeout[0], min(self._timeout[1], 60.0)),
                )
            except (requests.Timeout, requests.ConnectionError) as error:
                if attempt == 1:
                    self._sleep(1.0)
                    continue
                raise APIRequestError(
                    f"Generation metadata failed after one retry: {error}"
                ) from error

            status = int(response.status_code)
            if status in (401, 402):
                raise FatalAPIError(
                    f"OpenRouter authentication/billing failure ({status}): "
                    f"{_response_error(response)}"
                )
            if status in (404, 408, 429) or 500 <= status <= 599:
                if attempt == 1:
                    # Generation records can briefly return 404 after a successful STT call.
                    self._sleep(5.0 if status == 404 else 1.0)
                    continue
                raise APIRequestError(
                    f"Generation metadata failed after one retry ({status}): "
                    f"{_response_error(response)}"
                )
            if status < 200 or status >= 300:
                raise APIRequestError(
                    f"Generation metadata failed ({status}): {_response_error(response)}"
                )

            try:
                payload = response.json()
            except (ValueError, json.JSONDecodeError) as error:
                raise APIRequestError(
                    "OpenRouter returned non-JSON generation metadata"
                ) from error
            data = payload.get("data") if isinstance(payload, dict) else None
            if not isinstance(data, dict):
                raise APIRequestError("OpenRouter returned invalid generation metadata")
            return data

        raise APIRequestError("Generation metadata failed")


def _response_error(response: Any) -> str:
    try:
        payload = response.json()
        error = payload.get("error") if isinstance(payload, dict) else None
        if isinstance(error, dict):
            message = error.get("message")
            if isinstance(message, str) and message:
                detail = _nested_provider_error(error)
                return f"{message} ({detail})"[:500] if detail else message[:500]
        if isinstance(error, str) and error:
            return error[:500]
    except (ValueError, json.JSONDecodeError):
        pass
    text = getattr(response, "text", "")
    return str(text).strip()[:500] or "unknown error"


def _nested_provider_error(error: Mapping[str, Any]) -> str:
    metadata = error.get("metadata")
    if not isinstance(metadata, dict):
        return ""
    provider = metadata.get("provider_name")
    raw = metadata.get("raw")
    raw_message = ""
    if isinstance(raw, str):
        try:
            raw_payload = json.loads(raw)
            nested = raw_payload.get("error") if isinstance(raw_payload, dict) else None
            if isinstance(nested, dict) and isinstance(nested.get("message"), str):
                raw_message = nested["message"]
        except json.JSONDecodeError:
            raw_message = raw.strip()
    parts = [value for value in (_string_value(provider), raw_message) if value.strip()]
    return ": ".join(parts)


def run_candidate(
    client: OpenRouterClient,
    model: str,
    audio_base64: str,
    audio_format: str,
) -> CandidateResult:
    started = time.monotonic()
    try:
        if model == GEMINI_MODEL:
            api_call = client.post_json(
                CHAT_URL, build_gemini_request(audio_base64, audio_format)
            )
            transcript = _chat_text(api_call.payload)
        else:
            api_call = client.post_json(
                TRANSCRIPTION_URL,
                build_transcription_request(model, audio_base64, audio_format),
            )
            transcript = api_call.payload.get("text")
            if not isinstance(transcript, str):
                raise APIRequestError("Transcription response did not contain text")

        transcript = transcript.strip()
        if not transcript:
            raise APIRequestError("Transcription response was empty")
        latency_seconds = time.monotonic() - started
        generation_id = _header_value(api_call.headers, "X-Generation-Id")
        return CandidateResult(
            requested_model=model,
            success=True,
            transcript=transcript,
            latency_seconds=latency_seconds,
            resolved_model=_string_value(api_call.payload.get("model")),
            provider=_provider_value(api_call.payload.get("provider")),
            generation_id=generation_id,
            usage=_usage_value(api_call.payload.get("usage")),
        )
    except FatalAPIError:
        raise
    except (APIRequestError, OSError) as error:
        return CandidateResult(
            requested_model=model,
            success=False,
            error=str(error),
            latency_seconds=time.monotonic() - started,
        )


def run_candidates(
    client: OpenRouterClient, audio_base64: str, audio_format: str
) -> list[CandidateResult]:
    results: dict[str, CandidateResult] = {}
    executor = ThreadPoolExecutor(max_workers=len(CANDIDATE_MODELS))
    futures = {
        executor.submit(run_candidate, client, model, audio_base64, audio_format): model
        for model in CANDIDATE_MODELS
    }
    try:
        for future in as_completed(futures):
            results[futures[future]] = future.result()
    except FatalAPIError:
        for future in futures:
            future.cancel()
        executor.shutdown(wait=False, cancel_futures=True)
        raise
    else:
        executor.shutdown(wait=True)
    return [results[model] for model in CANDIDATE_MODELS]


def enrich_candidate_metadata(
    client: OpenRouterClient, candidates: Sequence[CandidateResult]
) -> list[CandidateResult]:
    """Fill provider/model fields once generation records have had time to settle."""

    def enrich(candidate: CandidateResult) -> CandidateResult:
        if (
            not candidate.success
            or not candidate.generation_id
            or (candidate.resolved_model and candidate.provider)
        ):
            return candidate
        try:
            metadata = client.get_generation_metadata(candidate.generation_id)
        except FatalAPIError:
            raise
        except APIRequestError:
            return candidate
        return replace(
            candidate,
            resolved_model=candidate.resolved_model
            or _string_value(metadata.get("model")),
            provider=candidate.provider or _string_value(metadata.get("provider_name")),
        )

    with ThreadPoolExecutor(max_workers=len(CANDIDATE_MODELS)) as executor:
        return list(executor.map(enrich, candidates))


def run_judge(
    client: OpenRouterClient,
    audio_base64: str,
    audio_format: str,
    candidates: Sequence[CandidateResult],
    rng: random.Random,
) -> JudgeResult:
    successful = [candidate for candidate in candidates if candidate.success]
    if not successful:
        return JudgeResult(
            success=False, scores_by_model={}, error="No successful candidates"
        )

    anonymous = anonymize_candidates(successful, rng)
    request_payload = build_judge_request(audio_base64, audio_format, anonymous)
    started = time.monotonic()
    api_call: APICall | None = None
    try:
        api_call = client.post_json(CHAT_URL, request_payload)
        parsed = parse_judge_response(_chat_text(api_call.payload), anonymous.keys())
        scores_by_model = {
            anonymous[candidate_id].requested_model: score
            for candidate_id, score in parsed.candidates.items()
        }
        return JudgeResult(
            success=True,
            scores_by_model=scores_by_model,
            confidence=parsed.confidence,
            latency_seconds=time.monotonic() - started,
            resolved_model=_string_value(api_call.payload.get("model")),
            provider=_provider_value(api_call.payload.get("provider")),
            generation_id=_header_value(api_call.headers, "X-Generation-Id"),
            usage=_usage_value(api_call.payload.get("usage")),
        )
    except FatalAPIError:
        raise
    except (APIRequestError, BenchmarkError) as error:
        payload = api_call.payload if api_call else {}
        headers = api_call.headers if api_call else {}
        return JudgeResult(
            success=False,
            scores_by_model={},
            error=str(error),
            latency_seconds=time.monotonic() - started,
            resolved_model=_string_value(payload.get("model")),
            provider=_provider_value(payload.get("provider")),
            generation_id=_header_value(headers, "X-Generation-Id"),
            usage=_usage_value(payload.get("usage")),
        )


def _chat_text(payload: Mapping[str, Any]) -> str:
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        raise APIRequestError("Chat response did not contain choices")
    message = choices[0].get("message")
    if not isinstance(message, dict):
        raise APIRequestError("Chat response did not contain a message")
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = [
            part.get("text", "")
            for part in content
            if isinstance(part, dict) and isinstance(part.get("text"), str)
        ]
        if parts:
            return "\n".join(parts)
    raise APIRequestError("Chat response did not contain text")


def _string_value(value: Any) -> str:
    return value if isinstance(value, str) else ""


def _provider_value(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        for key in ("name", "id", "slug"):
            if isinstance(value.get(key), str):
                return value[key]
    return ""


def _header_value(headers: Mapping[str, str], name: str) -> str:
    expected = name.lower()
    for key, value in headers.items():
        if key.lower() == expected:
            return str(value)
    return ""


def _usage_value(value: Any) -> Mapping[str, Any] | None:
    return value if isinstance(value, dict) else None


def _usage_number(usage: Mapping[str, Any] | None, *keys: str) -> float | None:
    if not usage:
        return None
    for key in keys:
        value = usage.get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return float(value)
    return None


def _usage_text(usage: Mapping[str, Any] | None) -> str:
    if not usage:
        return ""
    flattened: list[str] = []
    for key in sorted(usage):
        value = usage[key]
        if isinstance(value, (str, int, float, bool)) or value is None:
            flattened.append(f"{key}={value}")
    return "; ".join(flattened)


def _winner_statuses(judge: JudgeResult) -> dict[str, str]:
    if not judge.success or not judge.scores_by_model:
        return {}
    best = max(score.weighted_accuracy for score in judge.scores_by_model.values())
    leaders = {
        model
        for model, score in judge.scores_by_model.items()
        if best - score.weighted_accuracy <= 2.0
    }
    leader_status = "tie" if len(leaders) > 1 else "winner"
    return {
        model: leader_status if model in leaders else "not_winner"
        for model in judge.scores_by_model
    }


def build_result_rows(
    run_id: str,
    recording: Recording,
    audio_sha256: str,
    candidates: Sequence[CandidateResult],
    judge: JudgeResult,
) -> list[dict[str, Any]]:
    winner_statuses = _winner_statuses(judge)
    judge_cost = _usage_number(judge.usage, "cost")
    judge_cost_share = (
        judge_cost / len(CANDIDATE_MODELS) if judge_cost is not None else None
    )
    rows: list[dict[str, Any]] = []

    for candidate in candidates:
        score = judge.scores_by_model.get(candidate.requested_model)
        candidate_cost = _usage_number(candidate.usage, "cost")
        known_costs = [
            value for value in (candidate_cost, judge_cost_share) if value is not None
        ]
        row: dict[str, Any] = {
            "run_id": run_id,
            "recording_id": recording.recording_id,
            "duration_seconds": recording.duration_seconds,
            "selection_group": recording.selection_group,
            "audio_sha256": audio_sha256,
            "model": candidate.requested_model,
            "resolved_model": candidate.resolved_model,
            "provider": candidate.provider,
            "generation_id": candidate.generation_id,
            "transcript": candidate.transcript,
            "success": candidate.success,
            "error": candidate.error,
            "latency_seconds": candidate.latency_seconds,
            "realtime_factor": (
                candidate.latency_seconds / recording.duration_seconds
                if candidate.latency_seconds is not None
                else None
            ),
            "usage": _usage_text(candidate.usage),
            "usage_input_tokens": _usage_number(
                candidate.usage, "input_tokens", "prompt_tokens"
            ),
            "usage_output_tokens": _usage_number(
                candidate.usage, "output_tokens", "completion_tokens"
            ),
            "usage_total_tokens": _usage_number(candidate.usage, "total_tokens"),
            "usage_audio_seconds": _usage_number(candidate.usage, "seconds"),
            "candidate_cost_usd": candidate_cost,
            "judge_cost_share_usd": judge_cost_share,
            "cost_usd": sum(known_costs) if known_costs else None,
            "judge_success": judge.success,
            "judge_error": judge.error,
            "judge_model": JUDGE_MODEL,
            "judge_resolved_model": judge.resolved_model,
            "judge_provider": judge.provider,
            "judge_generation_id": judge.generation_id,
            "judge_latency_seconds": judge.latency_seconds,
            "judge_confidence": judge.confidence,
            "total_accuracy_score": score.weighted_accuracy if score else None,
            "proper_noun_error": score.proper_noun_error if score else None,
            "number_error": score.number_error if score else None,
            "critical_errors": " | ".join(score.critical_errors) if score else "",
            "has_critical_error": bool(score.critical_errors) if score else None,
            "winner_status": winner_statuses.get(candidate.requested_model, "unscored"),
        }
        for field in SCORE_FIELDS:
            row[field] = score.scores[field] if score else None
        rows.append(row)
    return rows


def aggregate_results(results: pd.DataFrame) -> pd.DataFrame:
    distribution_metrics = (
        "total_accuracy_score",
        *SCORE_FIELDS,
        "latency_seconds",
        "realtime_factor",
        "cost_usd",
    )
    stat_rows: list[dict[str, Any]] = []

    for selection_group in ("all", "shortest", "longest"):
        group_frame = (
            results
            if selection_group == "all"
            else results[results["selection_group"] == selection_group]
        )
        for model in CANDIDATE_MODELS:
            model_frame = group_frame[group_frame["model"] == model]
            for metric in distribution_metrics:
                values = pd.to_numeric(model_frame[metric], errors="coerce").dropna()
                described = values.describe(percentiles=[0.25, 0.50, 0.75, 0.90, 0.95])
                stat_rows.append(
                    {
                        "table": "distribution",
                        "selection_group": selection_group,
                        "model": model,
                        "metric": metric,
                        "rank": None,
                        "value": None,
                        **{
                            field: described.get(field, math.nan)
                            for field in DESCRIBE_FIELDS
                        },
                    }
                )

            summary = _model_summary(model_frame)
            for metric, value in summary.items():
                stat_rows.append(
                    {
                        "table": "summary",
                        "selection_group": selection_group,
                        "model": model,
                        "metric": metric,
                        "rank": None,
                        "value": value,
                        **{field: None for field in DESCRIBE_FIELDS},
                    }
                )

    ranking = build_ranking(results)
    for row in ranking.to_dict(orient="records"):
        stat_rows.append(
            {
                "table": "ranking",
                "selection_group": "all",
                "model": row["model"],
                "metric": "overall",
                "rank": row["rank"],
                "value": row["mean_weighted_accuracy"],
                **{field: None for field in DESCRIBE_FIELDS},
            }
        )
    return pd.DataFrame(stat_rows)


def _model_summary(model_frame: pd.DataFrame) -> dict[str, float]:
    if model_frame.empty:
        return {
            metric: math.nan
            for metric in (
                "mean_weighted_accuracy",
                "completion_rate_percent",
                "failure_rate_percent",
                "win_rate_percent",
                "tie_rate_percent",
                "proper_noun_error_rate_percent",
                "number_error_rate_percent",
                "critical_error_rate_percent",
                "median_latency_seconds",
                "total_cost_usd",
                "average_cost_usd",
            )
        }

    evaluated = model_frame[model_frame["total_accuracy_score"].notna()]
    return {
        "mean_weighted_accuracy": pd.to_numeric(
            evaluated["total_accuracy_score"], errors="coerce"
        ).mean(),
        "completion_rate_percent": model_frame["success"].astype(bool).mean() * 100,
        "failure_rate_percent": (~model_frame["success"].astype(bool)).mean() * 100,
        "win_rate_percent": (evaluated["winner_status"] == "winner").mean() * 100,
        "tie_rate_percent": (evaluated["winner_status"] == "tie").mean() * 100,
        "proper_noun_error_rate_percent": _boolean_rate(evaluated["proper_noun_error"]),
        "number_error_rate_percent": _boolean_rate(evaluated["number_error"]),
        "critical_error_rate_percent": _boolean_rate(evaluated["has_critical_error"]),
        "median_latency_seconds": pd.to_numeric(
            model_frame.loc[model_frame["success"], "latency_seconds"], errors="coerce"
        ).median(),
        "total_cost_usd": pd.to_numeric(model_frame["cost_usd"], errors="coerce").sum(
            min_count=1
        ),
        "average_cost_usd": pd.to_numeric(
            model_frame["cost_usd"], errors="coerce"
        ).mean(),
    }


def _boolean_rate(series: pd.Series) -> float:
    present = series.dropna()
    return present.astype(bool).mean() * 100 if not present.empty else math.nan


def build_ranking(results: pd.DataFrame) -> pd.DataFrame:
    rows: list[dict[str, Any]] = []
    for model in CANDIDATE_MODELS:
        model_frame = results[results["model"] == model]
        summary = _model_summary(model_frame)
        rows.append({"model": model, **summary})
    ranking = pd.DataFrame(rows).sort_values(
        by=[
            "mean_weighted_accuracy",
            "critical_error_rate_percent",
            "completion_rate_percent",
            "median_latency_seconds",
        ],
        ascending=[False, True, False, True],
        na_position="last",
        kind="stable",
    )
    ranking.insert(0, "rank", range(1, len(ranking) + 1))
    return ranking.reset_index(drop=True)


def _format_number(value: Any, digits: int = 1, suffix: str = "") -> str:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return "—"
    if not math.isfinite(number):
        return "—"
    return f"{number:.{digits}f}{suffix}"


def _format_cost(value: Any) -> str:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return "—"
    return f"${number:.4f}" if math.isfinite(number) else "—"


def _model_label(model: str) -> str:
    return MODEL_LABELS.get(model, model)


def _score_meter(value: Any) -> str:
    try:
        score = float(value)
    except (TypeError, ValueError):
        return '<span class="missing">Not scored</span>'
    if not math.isfinite(score):
        return '<span class="missing">Not scored</span>'
    width = min(max(score, 0), 100)
    return (
        '<div class="score-cell">'
        f"<strong>{score:.1f}</strong>"
        '<div class="meter" role="meter" aria-valuemin="0" aria-valuemax="100" '
        f'aria-valuenow="{score:.1f}"><span style="width:{width:.1f}%"></span></div>'
        "</div>"
    )


def write_html_report(results: pd.DataFrame, output_path: Path) -> None:
    """Write a self-contained, human-readable benchmark report."""
    ranking = build_ranking(results)
    recording_count = int(results["recording_id"].nunique())
    judged_recordings = int(
        results.groupby("recording_id", sort=False)["judge_success"]
        .first()
        .astype(bool)
        .sum()
    )
    candidate_failures = int((~results["success"].astype(bool)).sum())
    total_cost = pd.to_numeric(results["cost_usd"], errors="coerce").sum(min_count=1)
    run_id = str(results["run_id"].iloc[0]) if not results.empty else "unknown"

    ranked_models = ranking["model"].tolist()
    best_model = ranked_models[0] if ranked_models else ""
    fastest_model = min(
        CANDIDATE_MODELS,
        key=lambda model: _model_summary(results[results["model"] == model])[
            "median_latency_seconds"
        ],
    )

    parts = [
        "<!doctype html>",
        '<html lang="en"><head><meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width,initial-scale=1">',
        "<title>SuperSamuel recording benchmark</title>",
        """
<style>
:root { color-scheme: light dark; --bg:#f5f5f2; --surface:#fff; --text:#171714; --muted:#676761; --line:#ddddda; --accent:#2563eb; --accent-soft:#dbeafe; --good:#147d52; --bad:#b42318; --code:#f0f0ec; }
@media (prefers-color-scheme: dark) { :root { --bg:#11110f; --surface:#1b1b18; --text:#f3f3ed; --muted:#aaa9a1; --line:#353530; --accent:#78a9ff; --accent-soft:#182c4f; --good:#62d9a5; --bad:#ff8a80; --code:#252521; } }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--text); font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
main { max-width:1240px; margin:0 auto; padding:40px 24px 80px; }
h1 { margin:0 0 4px; font-size:30px; letter-spacing:-.03em; }
h2 { margin:44px 0 14px; font-size:21px; letter-spacing:-.015em; }
h3 { margin:28px 0 10px; font-size:17px; }
p { margin:5px 0; }
.muted,.missing { color:var(--muted); }
.grid { display:grid; grid-template-columns:repeat(4,minmax(0,1fr)); gap:12px; margin:24px 0; }
.card { background:var(--surface); border:1px solid var(--line); border-radius:12px; padding:16px; }
.card span { display:block; color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:.05em; }
.card strong { display:block; margin-top:4px; font-size:24px; font-weight:600; }
.explain { background:var(--surface); border-left:4px solid var(--accent); padding:14px 18px; margin:20px 0; }
.explain ul { margin:6px 0; padding-left:20px; }
.table-wrap { overflow-x:auto; background:var(--surface); border:1px solid var(--line); border-radius:12px; }
table { width:100%; border-collapse:collapse; font-variant-numeric:tabular-nums; }
th,td { padding:11px 12px; text-align:left; border-bottom:1px solid var(--line); vertical-align:top; }
th { color:var(--muted); font-size:12px; font-weight:600; white-space:nowrap; }
td.num,th.num { text-align:right; }
tr:last-child td { border-bottom:0; }
.rank { font-size:18px; font-weight:600; }
.model { min-width:190px; }
.model strong { display:block; }
.model code { color:var(--muted); font-size:11px; }
.score-cell { min-width:130px; }
.score-cell strong { display:block; }
.meter { height:6px; margin-top:6px; background:var(--accent-soft); border-radius:99px; overflow:hidden; }
.meter span { display:block; height:100%; background:var(--accent); }
.good { color:var(--good); }
.bad { color:var(--bad); }
details { margin:10px 0; background:var(--surface); border:1px solid var(--line); border-radius:10px; }
summary { cursor:pointer; padding:13px 15px; font-weight:600; }
details > .inside { padding:0 15px 15px; }
.transcript { white-space:pre-wrap; max-width:560px; font:13px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace; background:var(--code); padding:10px; border-radius:7px; }
.failure { color:var(--bad); }
.nowrap { white-space:nowrap; }
footer { margin-top:44px; color:var(--muted); font-size:12px; }
@media (max-width:760px) { main { padding:24px 14px 60px; } .grid { grid-template-columns:repeat(2,minmax(0,1fr)); } th,td { padding:9px 10px; } }
</style></head><body><main>
""",
        "<h1>Recording benchmark</h1>",
        f'<p class="muted">Run {html.escape(run_id)} · {recording_count} recordings · {len(results)} model outputs</p>',
        '<div class="grid">',
        f'<div class="card"><span>Best mean accuracy</span><strong>{html.escape(_model_label(best_model))}</strong><p>{_format_number(ranking.iloc[0]["mean_weighted_accuracy"] if not ranking.empty else math.nan)}/100</p></div>',
        f'<div class="card"><span>Fastest median</span><strong>{html.escape(_model_label(fastest_model))}</strong><p>{_format_number(_model_summary(results[results["model"] == fastest_model])["median_latency_seconds"], 2, "s")}</p></div>',
        f'<div class="card"><span>Judge coverage</span><strong>{judged_recordings}/{recording_count}</strong><p>{_format_number((judged_recordings / recording_count * 100) if recording_count else math.nan, 0, "%")} scored</p></div>',
        f'<div class="card"><span>Total API cost</span><strong>{_format_cost(total_cost)}</strong><p>{candidate_failures} candidate failures</p></div>',
        "</div>",
        '<div class="explain"><strong>How to read this</strong><ul>',
        "<li><b>Accuracy</b> is Muse’s weighted 0–100 score. Higher is better.</li>",
        "<li><b>Win</b> means the model led by more than 2 points. Scores within 2 points are ties.</li>",
        "<li><b>Error rates</b> should be low. They count judged transcripts with that problem.</li>",
        "<li><b>Realtime factor</b> below 1 means faster than the recording’s duration. Lower is better.</li>",
        "</ul></div>",
        "<h2>Overall ranking</h2>",
        '<div class="table-wrap"><table><thead><tr><th>Rank</th><th>Model</th><th>Mean accuracy</th><th class="num">Wins</th><th class="num">Ties</th><th class="num">Completion</th><th class="num">Critical errors</th><th class="num">Proper-noun errors</th><th class="num">Number errors</th><th class="num">Median latency</th><th class="num">Median RTF</th><th class="num">Total cost</th></tr></thead><tbody>',
    ]

    for ranking_row in ranking.to_dict(orient="records"):
        model = ranking_row["model"]
        model_frame = results[results["model"] == model]
        summary = _model_summary(model_frame)
        evaluated = model_frame[model_frame["total_accuracy_score"].notna()]
        wins = int((evaluated["winner_status"] == "winner").sum())
        ties = int((evaluated["winner_status"] == "tie").sum())
        median_rtf = pd.to_numeric(
            model_frame["realtime_factor"], errors="coerce"
        ).median()
        parts.extend(
            [
                "<tr>",
                f'<td class="rank">{int(ranking_row["rank"])}</td>',
                f'<td class="model"><strong>{html.escape(_model_label(model))}</strong><code>{html.escape(model)}</code></td>',
                f"<td>{_score_meter(summary['mean_weighted_accuracy'])}</td>",
                f'<td class="num">{wins}</td>',
                f'<td class="num">{ties}</td>',
                f'<td class="num">{_format_number(summary["completion_rate_percent"], 0, "%")}</td>',
                f'<td class="num">{_format_number(summary["critical_error_rate_percent"], 0, "%")}</td>',
                f'<td class="num">{_format_number(summary["proper_noun_error_rate_percent"], 0, "%")}</td>',
                f'<td class="num">{_format_number(summary["number_error_rate_percent"], 0, "%")}</td>',
                f'<td class="num">{_format_number(summary["median_latency_seconds"], 2, "s")}</td>',
                f'<td class="num">{_format_number(median_rtf, 3)}</td>',
                f'<td class="num">{_format_cost(summary["total_cost_usd"])}</td>',
                "</tr>",
            ]
        )
    parts.append("</tbody></table></div>")

    parts.extend(
        [
            "<h2>Accuracy criteria</h2>",
            '<p class="muted">Mean score across successfully judged recordings. The first six criteria form weighted accuracy; the last four are diagnostic.</p>',
            '<div class="table-wrap"><table><thead><tr><th>Model</th>',
        ]
    )
    for field in SCORE_FIELDS:
        parts.append(f'<th class="num">{html.escape(METRIC_LABELS[field])}</th>')
    parts.append("</tr></thead><tbody>")
    for model in ranked_models:
        model_frame = results[results["model"] == model]
        parts.append(
            f'<tr><td class="model"><strong>{html.escape(_model_label(model))}</strong></td>'
        )
        for field in SCORE_FIELDS:
            mean = pd.to_numeric(model_frame[field], errors="coerce").mean()
            parts.append(f'<td class="num">{_format_number(mean)}</td>')
        parts.append("</tr>")
    parts.append("</tbody></table></div>")

    parts.extend(
        [
            "<h2>Shortest versus longest recordings</h2>",
            '<div class="table-wrap"><table><thead><tr><th>Model</th><th class="num">Shortest accuracy</th><th class="num">Longest accuracy</th><th class="num">Difference</th><th class="num">Shortest latency</th><th class="num">Longest latency</th></tr></thead><tbody>',
        ]
    )
    for model in ranked_models:
        shortest = results[
            (results["model"] == model) & (results["selection_group"] == "shortest")
        ]
        longest = results[
            (results["model"] == model) & (results["selection_group"] == "longest")
        ]
        shortest_accuracy = pd.to_numeric(
            shortest["total_accuracy_score"], errors="coerce"
        ).mean()
        longest_accuracy = pd.to_numeric(
            longest["total_accuracy_score"], errors="coerce"
        ).mean()
        difference = longest_accuracy - shortest_accuracy
        parts.extend(
            [
                f'<tr><td class="model"><strong>{html.escape(_model_label(model))}</strong></td>',
                f'<td class="num">{_format_number(shortest_accuracy)}</td>',
                f'<td class="num">{_format_number(longest_accuracy)}</td>',
                f'<td class="num">{_format_number(difference, 1, " pts")}</td>',
                f'<td class="num">{_format_number(pd.to_numeric(shortest["latency_seconds"], errors="coerce").median(), 2, "s")}</td>',
                f'<td class="num">{_format_number(pd.to_numeric(longest["latency_seconds"], errors="coerce").median(), 2, "s")}</td></tr>',
            ]
        )
    parts.append("</tbody></table></div>")

    parts.append("<h2>Full described statistics</h2>")
    parts.append(
        '<p class="muted">Count, mean, standard deviation, minimum, percentiles, and maximum for every requested metric.</p>'
    )
    distribution_metrics = (
        "total_accuracy_score",
        *SCORE_FIELDS,
        "latency_seconds",
        "realtime_factor",
        "cost_usd",
    )
    for model in ranked_models:
        model_frame = results[results["model"] == model]
        parts.append(
            f'<details><summary>{html.escape(_model_label(model))}</summary><div class="inside table-wrap"><table><thead><tr><th>Metric</th>'
        )
        for field in DESCRIBE_FIELDS:
            parts.append(f'<th class="num">{html.escape(field)}</th>')
        parts.append("</tr></thead><tbody>")
        for metric in distribution_metrics:
            values = pd.to_numeric(model_frame[metric], errors="coerce").dropna()
            described = values.describe(percentiles=[0.25, 0.50, 0.75, 0.90, 0.95])
            parts.append(f"<tr><td>{html.escape(METRIC_LABELS[metric])}</td>")
            for field in DESCRIBE_FIELDS:
                digits = (
                    0
                    if field == "count"
                    else (4 if metric in ("realtime_factor", "cost_usd") else 2)
                )
                parts.append(
                    f'<td class="num">{_format_number(described.get(field, math.nan), digits)}</td>'
                )
            parts.append("</tr>")
        parts.append("</tbody></table></div></details>")

    judge_failure_rows = results.loc[
        ~results["judge_success"].astype(bool),
        ["recording_id", "duration_seconds", "judge_error"],
    ].drop_duplicates()
    candidate_failure_rows = results.loc[
        ~results["success"].astype(bool),
        ["recording_id", "model", "error"],
    ]
    parts.append("<h2>Failures</h2>")
    if judge_failure_rows.empty and candidate_failure_rows.empty:
        parts.append('<p class="good">No candidate or judge failures.</p>')
    else:
        parts.append(
            '<div class="table-wrap"><table><thead><tr><th>Recording</th><th>Stage/model</th><th>Error</th></tr></thead><tbody>'
        )
        for row in judge_failure_rows.itertuples():
            parts.append(
                f'<tr><td><code>{html.escape(str(row.recording_id))}</code></td><td>Judge · {_format_number(row.duration_seconds, 1, "s")}</td><td class="failure">{html.escape(str(row.judge_error))}</td></tr>'
            )
        for row in candidate_failure_rows.itertuples():
            parts.append(
                f'<tr><td><code>{html.escape(str(row.recording_id))}</code></td><td>{html.escape(_model_label(str(row.model)))}</td><td class="failure">{html.escape(str(row.error))}</td></tr>'
            )
        parts.append("</tbody></table></div>")

    parts.append("<h2>Recording details and transcripts</h2>")
    ordered_results = results.sort_values(["duration_seconds", "recording_id", "model"])
    for recording_id, recording_frame in ordered_results.groupby(
        "recording_id", sort=False
    ):
        first = recording_frame.iloc[0]
        scored = recording_frame.dropna(subset=["total_accuracy_score"])
        if scored.empty:
            result_label = "Not scored"
        else:
            best = scored.sort_values("total_accuracy_score", ascending=False).iloc[0]
            result_label = f"{_model_label(str(best['model']))} · {float(best['total_accuracy_score']):.1f}/100"
        parts.append(
            f'<details><summary>{html.escape(str(recording_id))} · {_format_number(first["duration_seconds"], 1, "s")} · {html.escape(str(first["selection_group"]))} · {html.escape(result_label)}</summary><div class="inside table-wrap"><table><thead><tr><th>Model</th><th class="num">Accuracy</th><th>Result</th><th class="num">Latency</th><th class="num">Cost</th><th>Critical errors</th><th>Transcript</th></tr></thead><tbody>'
        )
        for row in recording_frame.itertuples():
            transcript = "" if pd.isna(row.transcript) else str(row.transcript)
            errors = "" if pd.isna(row.critical_errors) else str(row.critical_errors)
            request_error = "" if pd.isna(row.error) else str(row.error)
            transcript_html = (
                f'<details><summary>Show transcript</summary><div class="inside transcript">{html.escape(transcript)}</div></details>'
                if transcript
                else f'<span class="failure">{html.escape(request_error or "No transcript")}</span>'
            )
            parts.extend(
                [
                    f'<tr><td class="model"><strong>{html.escape(_model_label(str(row.model)))}</strong></td>',
                    f'<td class="num">{_format_number(row.total_accuracy_score)}</td>',
                    f"<td>{html.escape(str(row.winner_status))}</td>",
                    f'<td class="num">{_format_number(row.latency_seconds, 2, "s")}</td>',
                    f'<td class="num">{_format_cost(row.cost_usd)}</td>',
                    f"<td>{html.escape(errors) if errors else '—'}</td>",
                    f"<td>{transcript_html}</td></tr>",
                ]
            )
        parts.append("</tbody></table></div></details>")

    parts.extend(
        [
            f"<footer>Generated from results.csv · Judge: {html.escape(JUDGE_MODEL)} · Accuracy ties: within 2 points</footer>",
            "</main></body></html>",
        ]
    )
    output_path.write_text("".join(parts), encoding="utf-8")


def print_readable_summary(results: pd.DataFrame) -> None:
    ranking = build_ranking(results)
    columns = [
        "rank",
        "model",
        "mean_weighted_accuracy",
        "completion_rate_percent",
        "critical_error_rate_percent",
        "median_latency_seconds",
        "win_rate_percent",
        "tie_rate_percent",
        "total_cost_usd",
    ]
    display = ranking[columns].copy()
    display["model"] = display["model"].map(_model_label)
    display.columns = [
        "Rank",
        "Model",
        "Accuracy",
        "Completed %",
        "Critical errors %",
        "Median latency (s)",
        "Wins %",
        "Ties %",
        "Cost (USD)",
    ]
    print("\nResult summary")
    print(display.round(2).to_string(index=False))


def print_statistics(results: pd.DataFrame) -> None:
    pd.set_option("display.max_columns", None)
    pd.set_option("display.width", 220)
    pd.set_option("display.max_colwidth", 48)
    print("\nOverall accuracy ranking")
    ranking_columns = [
        "rank",
        "model",
        "mean_weighted_accuracy",
        "critical_error_rate_percent",
        "completion_rate_percent",
        "median_latency_seconds",
    ]
    print(build_ranking(results)[ranking_columns].to_string(index=False))

    print("\nWin, tie, error, failure, and cost statistics")
    summary_rows = []
    for model in CANDIDATE_MODELS:
        summary_rows.append(
            {"model": model, **_model_summary(results[results["model"] == model])}
        )
    print(pd.DataFrame(summary_rows).to_string(index=False))

    distribution_metrics = (
        "total_accuracy_score",
        *SCORE_FIELDS,
        "latency_seconds",
        "realtime_factor",
        "cost_usd",
    )
    for selection_group in ("all", "shortest", "longest"):
        group_frame = (
            results
            if selection_group == "all"
            else results[results["selection_group"] == selection_group]
        )
        print(f"\n{selection_group.title()} distributions")
        distribution_rows: list[dict[str, Any]] = []
        for model in CANDIDATE_MODELS:
            model_frame = group_frame[group_frame["model"] == model]
            for metric in distribution_metrics:
                values = pd.to_numeric(model_frame[metric], errors="coerce").dropna()
                described = values.describe(percentiles=[0.25, 0.50, 0.75, 0.90, 0.95])
                distribution_rows.append(
                    {
                        "model": model,
                        "metric": metric,
                        **{
                            field: described.get(field, math.nan)
                            for field in DESCRIBE_FIELDS
                        },
                    }
                )
        print(pd.DataFrame(distribution_rows).to_string(index=False))

    total_cost = pd.to_numeric(results["cost_usd"], errors="coerce").sum(min_count=1)
    average_cost = pd.to_numeric(results["cost_usd"], errors="coerce").mean()
    print(
        f"\nTotal cost: ${total_cost:.6f}"
        if pd.notna(total_cost)
        else "\nTotal cost: unavailable"
    )
    print(
        f"Average cost per recording/model row: ${average_cost:.6f}"
        if pd.notna(average_cost)
        else "Average cost per recording/model row: unavailable"
    )


class BenchmarkRunner:
    def __init__(
        self,
        client: OpenRouterClient,
        rng: random.Random | None = None,
        judge_audio_preparer: Callable[
            [Path, str], tuple[str, str]
        ] = prepare_judge_audio,
    ) -> None:
        self.client = client
        self.rng = rng or random.SystemRandom()
        self.judge_audio_preparer = judge_audio_preparer

    def run_recording(
        self, index: int, recording: Recording, judge_rng: random.Random
    ) -> RecordingResult:
        audio_base64, audio_sha256 = encode_audio(recording.audio_path)
        candidates = run_candidates(
            self.client,
            audio_base64=audio_base64,
            audio_format=recording.audio_format,
        )
        candidates = enrich_candidate_metadata(self.client, candidates)
        try:
            judge_audio_base64, judge_audio_format = self.judge_audio_preparer(
                recording.audio_path, recording.audio_format
            )
            judge = run_judge(
                self.client,
                audio_base64=judge_audio_base64,
                audio_format=judge_audio_format,
                candidates=candidates,
                rng=judge_rng,
            )
        except FatalAPIError:
            raise
        except BenchmarkError as error:
            judge = JudgeResult(success=False, scores_by_model={}, error=str(error))
        return RecordingResult(index, recording, audio_sha256, candidates, judge)

    def run(
        self,
        recordings: Sequence[Recording],
        output_directory: Path,
        print_output: bool = True,
        workers: int = 4,
        verbose_stats: bool = False,
    ) -> BenchmarkOutput:
        if workers <= 0:
            raise ValueError("workers must be positive")
        run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        rows: list[dict[str, Any]] = []
        if not recordings:
            raise BenchmarkError("No recordings were selected")

        worker_count = min(workers, len(recordings))
        seeds = [self.rng.randrange(0, 2**63) for _ in recordings]
        completed: list[RecordingResult] = []
        judged_count = 0
        executor = ThreadPoolExecutor(max_workers=worker_count)
        futures = {
            executor.submit(
                self.run_recording,
                index,
                recording,
                random.Random(seeds[index]),
            ): recording
            for index, recording in enumerate(recordings)
        }
        progress = tqdm(
            total=len(recordings),
            desc="Benchmarking",
            unit="recording",
            dynamic_ncols=True,
            disable=not print_output,
        )
        try:
            for future in as_completed(futures):
                result = future.result()
                completed.append(result)
                judged_count += int(result.judge.success)
                progress.set_postfix(
                    judged=f"{judged_count}/{len(completed)}",
                    refresh=False,
                )
                progress.update()
        except FatalAPIError:
            for future in futures:
                future.cancel()
            executor.shutdown(wait=False, cancel_futures=True)
            raise
        except BaseException:
            for future in futures:
                future.cancel()
            executor.shutdown(wait=False, cancel_futures=True)
            raise
        else:
            executor.shutdown(wait=True)
        finally:
            progress.close()

        completed.sort(key=lambda result: result.index)
        for result in completed:
            rows.extend(
                build_result_rows(
                    run_id,
                    result.recording,
                    result.audio_sha256,
                    result.candidates,
                    result.judge,
                )
            )

        if print_output:
            judge_failures = [
                result for result in completed if not result.judge.success
            ]
            if judge_failures:
                print("\nJudge failures:")
                for result in judge_failures:
                    print(f"- {result.recording.recording_id}: {result.judge.error}")

        results = pd.DataFrame(rows)
        stats = aggregate_results(results)
        run_directory = output_directory / f"run-{run_id}"
        run_directory.mkdir(parents=True, exist_ok=False)
        results_path = run_directory / "results.csv"
        stats_path = run_directory / "stats.csv"
        report_path = run_directory / "report.html"
        results.to_csv(results_path, index=False)
        stats.to_csv(stats_path, index=False)
        write_html_report(results, report_path)
        if print_output:
            print_readable_summary(results)
            if verbose_stats:
                print_statistics(results)
        return BenchmarkOutput(
            run_directory,
            results_path,
            stats_path,
            report_path,
            results,
            stats,
        )


def load_api_key() -> str:
    environment_key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if environment_key:
        return environment_key
    try:
        result = subprocess.run(
            [
                "security",
                "find-generic-password",
                "-s",
                "com.supersamuel.app",
                "-a",
                "openrouter-api-key",
                "-w",
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (
        FileNotFoundError,
        subprocess.CalledProcessError,
        subprocess.TimeoutExpired,
    ) as error:
        raise BenchmarkError(
            "Set OPENROUTER_API_KEY or save the API key in SuperSamuel Settings"
        ) from error
    api_key = result.stdout.strip()
    if not api_key:
        raise BenchmarkError("The OpenRouter API key is empty")
    return api_key


def positive_integer(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be an integer") from error
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def parse_arguments(arguments: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Compare four transcription models on the 50 shortest eligible and 50 longest "
            "single-chunk recordings in SuperSamuel Transcript History."
        )
    )
    parser.add_argument(
        "--input",
        type=Path,
        default=DEFAULT_HISTORY_DIRECTORY,
        help=f"Transcript History directory (default: {DEFAULT_HISTORY_DIRECTORY})",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT_DIRECTORY,
        help=f"parent directory for the fresh timestamped run (default: {DEFAULT_OUTPUT_DIRECTORY})",
    )
    parser.add_argument(
        "--limit",
        type=positive_integer,
        help="evenly sample N recordings from shortest through longest",
    )
    parser.add_argument(
        "--workers",
        type=positive_integer,
        default=4,
        help="recordings to process concurrently (default: 4)",
    )
    parser.add_argument(
        "--verbose-stats",
        action="store_true",
        help="also print every pandas distribution table in the terminal",
    )
    parser.add_argument(
        "--open-report",
        action="store_true",
        help="open the readable HTML report when the run completes",
    )
    return parser.parse_args(arguments)


def main(arguments: Sequence[str] | None = None) -> int:
    args = parse_arguments(arguments)
    try:
        scanned = scan_recordings(args.input.expanduser().resolve())
        selected = select_recordings(scanned)
        selected = apply_limit(selected, args.limit)
        print(
            f"Scanned {len(scanned)} valid single-chunk recordings; "
            f"running a fresh benchmark on {len(selected)} selected recordings "
            f"with {min(args.workers, len(selected))} workers."
        )
        client = OpenRouterClient(load_api_key())
        output = BenchmarkRunner(client).run(
            selected,
            output_directory=args.output.expanduser().resolve(),
            workers=args.workers,
            verbose_stats=args.verbose_stats,
        )
        print(f"\nReadable report: {output.report_path}")
        print(f"Raw results:     {output.results_path}")
        print(f"Raw statistics:  {output.stats_path}")
        print(f"\nOpen the report:\n  open '{output.report_path}'")
        if args.open_report:
            subprocess.run(["open", str(output.report_path)], check=False)
        return 0
    except FatalAPIError as error:
        print(f"Benchmark stopped: {error}", file=sys.stderr)
        return 2
    except (BenchmarkError, OSError) as error:
        print(f"Benchmark failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
