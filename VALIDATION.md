# Implementation verification

Verified on September 4, 2026. The native Swift architecture and durable AAC
recording path are retained.

## Deployed API compatibility

The authenticated OpenAI WebSocket rejected `gpt-live-transcribe` with
`server_vad` and `silence_duration_ms: 500` for every requested delay, reporting
that turn detection is unsupported for this model. It accepted all five delays
with `turn_detection: null`. An invalid delay was rejected and the response
enumerated exactly `minimal`, `low`, `medium`, `high`, and `xhigh`.

SuperSamuel therefore detects a 500 ms pause locally in PCM energy windows and
explicitly commits. All captured samples are streamed. This detector uses energy
and hysteresis; it is not equivalent to OpenAI's server speech classifier and
still needs noisy/quiet microphone evaluation. Stop commits remaining audio and
waits for all turns. A nonempty residual shorter than the API's 100 ms minimum is
padded with silence so its real samples are retained.

The deployed API also confirmed a 1,024-character prompt limit. Oversized live
instructions or screenshot context now keep live preview running with a short
general prompt and the dictionary. The saved audio is finalized with the full
original instructions after Stop, and this mode is shown in the overlay.
Invalid keyword characters are rejected locally. Official
documentation does not specify a numeric keyword count or length limit; no
unverified limit or silent truncation is imposed.

The [Realtime transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription)
documents the live model, keywords, and delay presets. The shared
[generated API reference](https://developers.openai.com/api/reference/resources/realtime/subresources/client_secrets/methods/create)
has conflicting model/VAD wording, so the deployed probes determined the
configuration used here.

## Measured synthetic smoke test

The actual Swift service streamed a locally generated Samantha speech sample at
real-time pace, followed by silence: “Please send the SuperSamuel update to Marc.
We use OpenRouter for saved recordings.” Total audio length was 5.537 seconds.
All five presets returned the exact script. A separate silence-only request
returned no speech.

| Delay | First nonempty text | Stop to final transcript |
| --- | ---: | ---: |
| Minimal | 0.276 s | 0.791 s |
| Low | 0.636 s | 0.695 s |
| Medium | 1.115 s | 0.639 s |
| High | 1.457 s | 0.645 s |
| X-high | 2.141 s | 0.746 s |

Each number is one observation. First-text latency excludes connection setup.
No paste was performed, so Stop-to-final is not Stop-to-paste latency. These
results do not establish quality across human speech or fixed preset durations.
No private recordings were uploaded for this test.

The real API test is opt-in. Generate a nonprivate 24 kHz mono WAV with the script
above, then run:

```bash
SUPERSAMUEL_LIVE_TEST_AUDIO=/absolute/path/to/generated.wav \
  swift test --package-path app \
  --filter RealtimeTranscriptionServiceTests/testLiveAPIWithGeneratedSpeechWhenExplicitlyEnabled
```

It requires `OPENAI_API_KEY` explicitly and makes paid API requests. The test
runner does not read the app's Keychain entry or ask for credential access.
It is skipped in the ordinary test suite. Set
`SUPERSAMUEL_LIVE_TEST_LONG_CONTEXT=1` to exercise oversized instructions.

## Automated and UI checks

Initial checks: 64 Swift tests passed, with the paid API test skipped during the
ordinary suite and passed separately; all 11 Python benchmark tests passed.
The release build and `git diff --check` completed without errors or warnings.

Regression coverage includes delay persistence, dictionary validation, complete
session updates, asynchronous turn completion/failure, Stop buffer handling,
capture discontinuities, audio preservation, fresh retries, verified silence,
nonblocking recovery, clipboard ownership, archive cancellation, and background
history caching. The Python benchmark suite also passes, and the native release
build succeeds.

An isolated native settings preview verified all five picker options, persistence
after relaunch, scrolling, dictionary trimming/deduplication, visible invalid-line
errors, and retention of the last valid dictionary. It used separate preferences
and credentials; the installed app was not replaced during that preview.

On September 5, the full release was installed and relaunched from
`~/Applications/SuperSamuel.app` as version **1.3.5**, with the portrait icon.
The installed executable contains the delay picker and personal dictionary,
and its code signature was verified. Existing preferences and recordings were
preserved.

## Long-instructions regression (September 5)

Version 1.3.5 incorrectly disabled live transcription when existing instructions
exceeded the live API's 1,024-character limit. The affected preferences contained
1,031 characters. A new failing service test reproduced the reported warning
before the fix. Version 1.3.6 keeps the live stream active and retains the full
instructions for saved-audio finalization. Oversized screenshot updates also
keep streaming; removing the screenshot does not make an earlier preview final.
Processor coverage verifies that neither a live preview nor a cached live draft
or final bypasses the full-instruction saved-audio request after a manifest reload.

Microphone, Accessibility, and Screen Recording permission request paths were
unchanged. The installed 1.3.5 app and the prior 1.3.4 backup had the same code
signing designated requirement. No permission database or credentials were reset.
The earlier transient permission prompt could not be identified from the supplied
screenshot, which shows the context-length warning only.

A new live API run for the long-context fix was skipped because credential access
was denied with user interaction disabled. The first query-only attempt stalled
in legacy Keychain authorization and was stopped; the subsequent process-level
prohibition returned immediately. The test now requires an explicit environment
credential so it cannot cause app-Keychain authorization prompts. No private
audio was uploaded. The regression is covered with the fake WebSocket and saved
transcription transport; the earlier synthetic API measurements above predate
this fix.

The final regression suite passed 66 tests with the paid API test skipped. The
release build and `git diff --check` passed. Version **1.3.6** was installed and
relaunched from `~/Applications/SuperSamuel.app`; its executable UUID matches the
release build (`5F1CFA1E-0BE3-34BB-89A9-6427E300E9CD`) and its code signature verifies.
The full instruction checksum, both pending recordings, and the app icon were
verified after installation.

## Remaining hardware and quality checks

- Physically switch or unplug a microphone during speech and silence.
- Test quiet/noisy speech, different microphones and accents, and long recordings.
- Compare representative human recordings across all five presets.
- Measure actual Stop-to-paste latency and verify paste into target applications.

Simulated capture regressions and synthetic API measurements do not replace
these checks.
