# SuperSamuel

SuperSamuel is a small native macOS dictation app:

- Press `Option+Space` to start and stop recording.
- Record locally as compact 16 kHz mono AAC audio.
- Optionally stream a 24 kHz PCM sidecar directly to OpenAI's Realtime API,
  using `gpt-live-transcribe` and showing the transcript in the recording overlay.
- Keep the local recording and configurable OpenRouter transcription path,
  defaulting to `openai/gpt-transcribe`, as the durable fallback.
- Paste the result back into the app that was active while dictating.
- Optionally attach a screenshot as context. Visible text is extracted locally
  and added to the transcription instructions.

Realtime transcription uses a direct authenticated WebSocket connection. A local
PCM speech-pause detector commits a turn after 500 ms of low-energy audio following
speech. Stop explicitly commits remaining audio and waits for all committed turns.
The deployed `gpt-live-transcribe` API rejects server-side turn detection, so the
session uses `turn_detection: null`; the 500 ms threshold stays in the capture path.

The recording overlay keeps the complete live transcript in a scrollable area,
shows about five lines at its default size, and can be resized by dragging its
bottom-right resize grip. Settings includes the persistent GPT Live Transcribe
delay presets **Minimal**, **Low**, **Medium**, **High**, and **X-high** (default).
Model delay and the 500 ms speech-pause threshold are separate controls; presets
are not converted into estimated milliseconds. Dictionary, cleanup instructions,
and delay changes apply to the next recording. Screenshot updates retain that
recording's configuration. Recognition has no editing prompt. The personal
dictionary is sent separately as live keywords, and optional screenshot context
is limited to the first 1,024 Unicode scalars. Full screenshot context remains
available for saved-audio fallback. The saved-audio model field accepts STT
models; editing happens in the optional cleanup step below.

## Optional text cleanup

In Settings, enable **Text cleanup → Clean up transcript after Stop** to have an
OpenRouter chat model edit the completed transcript. The default cleanup model
is `google/gemini-3.8-flash`; the model field is editable. This adds one text-only
request after transcription, with a **Cleaning up transcript...** status.
Gemini 3.8 Flash text cleanup prefers `google-ai-studio/priority`, with fallback
enabled. Priority has a higher token rate; reported token throughput does not
include request startup latency. Other models retain throughput-based routing.

**Editing instructions** is the app's single editable cleanup prompt. Its default
preserves the speaker's wording and details while removing clear speech
disfluencies, with examples covering versions, corrections, emphasis, and
alternative ideas. **Restore Default** restores that same prompt. The full prompt
is sent as the system message, with only the raw transcript in the user message;
no additional editing instructions are prepended or appended. Both live
transcription and saved-audio fallback feed this step, without audio or screenshots.

On the first launch after this update, the old saved transcription and cleanup
prompts are replaced with the new default. Subsequent edits persist across
relaunches. Model, dictionary, and cleanup-enabled preferences are preserved.

The recording snapshots its cleanup settings at Start. History stores those settings,
the original `draft-transcript.txt`, and the cleaned final transcript with all audio.
If cleanup fails or is cancelled, the draft remains available. Retrying that cleanup
reuses the draft; changing cleanup settings only invalidates the edited result.
Turning cleanup off delivers transcription directly. Cleanup is off by default.

On macOS 26 and newer, the compact notification-style recording overlay and
settings window use untinted native **clear Liquid Glass** across their full
surface, with clear-glass controls. A subtle moving chromatic backdrop gives
the untinted glass light to refract even above nearly black applications.
SuperSamuel does not add a custom blur layer. Older macOS versions use a
non-blurred, translucent fallback because native Liquid Glass is unavailable
there.

## Requirements

- macOS 13 or newer
- Xcode Command Line Tools
- An OpenRouter API key with available credits
- Optionally, an OpenAI API key with Realtime API access for live transcription

Install the command-line tools if needed:

```bash
xcode-select --install
```

## Build and install

From the repository root:

```bash
./rebuild-app.sh
```

The script builds, signs, installs, and opens `~/Applications/SuperSamuel.app`.
It bundles `app/Resources/AppIcon.icns` so macOS search and Finder show the
SuperSamuel portrait used in Conductor's sidebar. The original 128×128 PNG is
kept beside it; the ICNS includes standard and Retina sizes with crisp pixel-art
scaling.
It uses an optimized release build by default. For a faster local rebuild:

```bash
BUILD_CONFIGURATION=debug ./rebuild-app.sh
```

For a development-only build:

```bash
cd app
swift build
```

## Configure transcription

1. Open the `SS` menu-bar item.
2. Choose **Settings…**
3. Enter your OpenRouter API key. It is stored in the macOS Keychain.
4. Enter an OpenAI API key and leave **Use GPT Live Transcribe** enabled to
   show live transcription. This key is stored in a separate Keychain entry.
5. Select the live transcription delay. Optionally change the saved-audio model
   from `openai/gpt-transcribe`; it is independent of the live model.
6. Enable **Text cleanup** and edit **Editing instructions** to customize cleanup.
7. Add names and phrases to **Personal dictionary**, one per line. Entries are
   trimmed and deduplicated. Invalid characters show an error and leave the last
   valid dictionary saved.

To avoid Keychain authorization prompts after local app updates, choose
**Settings → API key storage → Use local key storage**. This copies both saved
keys into `~/Library/Application Support/SuperSamuel/Credentials/` and keeps
using those files after updates. macOS may ask for Keychain access once per key
during the copy. The switch only takes effect after both keys have been read
and saved successfully; the original Keychain entries remain as backups.

Local files are **unencrypted**. The directory has owner-only permissions
(`0700`) and each key file is readable and writable only by your account
(`0600`), including during replacement. Other apps running as your macOS user
can still read them. Keychain remains the default until you explicitly select
local storage. Editing or clearing a local key does not alter the old Keychain
backup, and the app never silently falls back to that backup.

The build script uses ad hoc signing. macOS assigns that code a Keychain
partition based on its changing code hash, even with a fixed designated
requirement. Seamless Keychain access across updates requires an appropriate,
consistent Apple signing identity; a fixed bundle identifier or self-signed
certificate alone does not solve this. See
[Apple's Keychain client identification implementation](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/clientid.cpp).

Scrolling over text fields or unfocused editors scrolls the settings page.
Click into a long editor to scroll its text; reaching either end continues
scrolling the page. Short and disabled editors do not trap scrolling.

The default transcription model is:

```text
openai/gpt-transcribe
```

Dictionary entries are sent as live `keywords` and included as vocabulary in the
fallback context. Screenshot text is extracted locally and supplied as recognition
context without a second model request. When cleanup is enabled, the completed
transcript is edited using the single prompt in Settings before delivery.

## Headless dictation benchmark

The isolated benchmark runner compares the same audio through the following
strategies. Its Whisper draft explicitly uses `openai/whisper-large-v3`, independent
of the app's saved-audio default. Reports record requested and resolved models
for each call:


- Whisper only
- Whisper followed by Gemini with transcript text only
- Gemini with audio only
- Whisper followed by Gemini with both the audio and Whisper draft

Audio-model requests default to `google/gemini-3.5-flash` and ask OpenRouter to
route to the provider with the highest advertised throughput. The runner never
pastes text, writes transcript history, or deletes a recording session.

Create a private corpus in the gitignored `.context` directory:

```text
.context/dictation-benchmark/cases/
  normal-dictation.m4a
  normal-dictation.reference.txt
  noisy-product-name.m4a
  noisy-product-name.reference.txt
  noisy-product-name.instruction.txt
```

The reference and per-clip instruction files are optional. Run all four
strategies from the repository root:

```bash
cd app
swift run SuperSamuel benchmark \
  --input ../.context/dictation-benchmark/cases \
  --output ../.context/dictation-benchmark/results
```

Use `--strategies` for a smaller comparison:

```bash
swift run SuperSamuel benchmark \
  --input ../.context/dictation-benchmark/cases \
  --strategies gemini-audio,whisper-gemini-audio
```

Use `--models` to run the audio strategies against several OpenRouter models.
Whisper-only still runs once and its draft is shared by every hybrid strategy:

```bash
swift run SuperSamuel benchmark \
  --input ../.context/dictation-benchmark/cases \
  --strategies whisper-only,gemini-audio,whisper-gemini-audio \
  --models google/gemini-3.5-flash,mistralai/voxtral-small-24b-2507,openai/gpt-audio-mini
```

Use 16 kHz mono PCM WAV for the broadest cross-model compatibility. Supported
input formats still depend on the selected model and its routed provider.

The API key comes from `OPENROUTER_API_KEY` when set, otherwise from the same
credential storage as the app (Keychain or opted-in local files). Every run creates a new directory containing:

- `results.jsonl` with the audio hash, exact instruction, model/provider,
  latency, usage, cost, output, errors, and optional word-error rate
- `report.md` with a side-by-side comparison and observed completion tokens per
  second

Throughput routing optimizes OpenRouter's provider choice, while the recorded
end-to-end latency still includes upload, time-to-first-token, and network time.

## Permissions

SuperSamuel may request:

- **Microphone** — required to record dictation.
- **Accessibility** — required for automatic paste. Without it, the result is
  still copied to the clipboard.
- **Screen Recording** — required only when attaching screenshot context.

## Request flow

```text
record durable M4A audio + best-effort PCM sidecar
  → OpenAI Realtime WebSocket using gpt-live-transcribe
    → live transcript in the recording overlay
    → final transcript
  → if realtime is disabled or unavailable:
    selected OpenRouter transcription model using the durable M4A
  → save the transcript beside the recording
  → clipboard
  → optional Command+V paste
```

After a successful transcription, the recording, transcript artifacts, metadata,
and any attached screenshot are moved together into the permanent transcript
history. They remain there until history is explicitly cleared.

The waveform is calculated from `AVAudioRecorder` metering while the durable AAC
file is written. A separate, best-effort audio engine produces the PCM stream;
it never replaces the saved recording. The recorder and streaming engine are
recreated for every session. During recording, device changes, recorder failures,
and missing PCM samples are monitored separately from silence. The live engine
and converter are rebuilt after route changes. An interrupted live stream forces
saved-audio transcription when stopped. If local capture also stops or changes
microphones, new files preserve the recorded parts and the overlay warns about
missing audio. The saved parts are transcribed in order and delivered as one
transcript. An interruption alone does not block delivery: the overlay and history
note that words during the interruption may be missing, and the archive preserves
every source file and the capture continuity metadata. Failed transcription still
keeps the recording available for retry.

## Recording recovery

Audio is stored under:

```text
~/Library/Application Support/SuperSamuel/Recordings/
```

Each recording has its own folder containing:

- The durable M4A recording (microphone changes or interruptions may create several parts)
- A JSON manifest
- Cached transcript parts (legacy recordings may also contain cleaned parts)
- The saved realtime or fallback draft in `draft-transcript.txt`
- Any incomplete live result in `live-partial-transcript.txt`, kept separately
  from reusable transcription caches
- The final transcript while processing completes
- Optional screenshot context

If transcription, cancellation, or app shutdown interrupts processing,
the recording remains in this folder. On the next launch, SuperSamuel presents
the oldest unsent recording and offers:

- **Send Recording**
- **Keep for Later**
- **Move to Trash**

The menu-bar **Unsent Recordings** submenu also supports sending, revealing the
folder in Finder, or moving it directly to macOS Trash. Individual Trash actions
in the menu, overlay, and recovery dialog do not ask for another confirmation.
**Keep for Later** allows new recordings while older sessions remain in this menu.
The manifest records model, instructions, dictionary, live delay, capture
continuity, and the microphone used for each recorded part.

Explicit **Retry** or **Send Recording** transcribes the saved audio afresh using
current settings, including recordings previously classified as no speech.
Compatible interrupted processing can reuse successful parts. Changing the
model, instructions, dictionary, or screenshot context invalidates derived
transcripts while preserving audio.

Independently verified silent audio returns the app to Ready and remains available
in Unsent Recordings. An empty provider response alone is treated as uncertain:
the audio is kept for recovery, and a partial live fragment is not substituted as
a complete result.

Successfully processed text is stored under:

```text
~/Library/Application Support/SuperSamuel/Transcript History/
```

Every new transcript has its own UUID-named folder containing:

- The original durable M4A recording (or all parts from a recovered legacy session)
- `transcript.txt` and cached transcription/final artifacts (legacy archives
  may also contain cleaned transcript files)
- `metadata.json` with the workflow, transcription model and instructions,
  audio duration and size, input device, screenshot usage, timestamps, app
  version, and macOS version
- The original recording manifest and optional screenshot context

Archiving and history scanning run in the background. Recent history entries are
cached between menu openings. The **Transcript History** submenu shows recent
transcript previews. Each entry
offers **Copy Transcript** and **Reveal Recording and Transcript in Finder**.
Older flat JSON history entries remain readable, while new entries use the
complete folder format. History remains until explicitly cleared; clearing it
also permanently deletes its archived recordings and metadata.

## Upload limits

With realtime enabled, SuperSamuel streams 24 kHz mono PCM to OpenAI while also
writing its compact 32 kbps M4A recording (roughly 14 MB/hour). If realtime is
disabled, cannot connect, or cannot complete, the durable recording is sent
through OpenRouter's base64 JSON transcription path. Successful results are
cached for compatible interrupted processing. An explicit user retry always
requests fresh transcription.

Official references:

- [OpenRouter speech-to-text](https://openrouter.ai/docs/guides/overview/multimodal/stt)
- [OpenRouter transcription API usage](https://openrouter.ai/docs/guides/overview/multimodal/stt#api-usage)
- [OpenAI Realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription)
- [OpenAI Realtime WebSocket](https://developers.openai.com/api/docs/guides/realtime-websocket)

## Verification

Run automated checks:

```bash
swift test --package-path app
swift build --package-path app -c release
uv run --with-requirements benchmark/requirements.txt python -m unittest discover -s benchmark
```

See [verification results](VALIDATION.md) for deployed API compatibility checks,
measured synthetic timings, and remaining hardware checks.

## Manual verification

- Start and stop recording with `Option+Space`.
- Confirm the waveform and timer update while recording.
- With an OpenAI key configured, pause for about 500 ms and confirm the turn is
  committed locally; displayed text also depends on the selected model delay.
- Test all five delay presets and Stop during pending transcription. Measure
  text-display and Stop-to-paste latency; do not infer timing from preset names.
- Disable realtime and confirm the saved-recording path still transcribes.
- Interrupt the network during recording and confirm the saved M4A is used as
  the fallback.
- Cancel during transcription and confirm nothing is pasted.
- Confirm the cancelled recording appears under **Unsent Recordings**.
- Relaunch with an unsent recording and test Send, Keep, Reveal, and Trash.
- Choose Keep for Later and confirm a new recording can start.
- Switch or disconnect the microphone during speech. Check per-part microphone
  metadata, preserved audio, the interruption warning, and saved-audio fallback.
- Record silence, then retry a failed recording after changing its dictionary.
- Confirm transcription instructions affect filler removal and expected terms.
- Test automatic paste in Notes, a browser textarea, and a code editor.
- Test clipboard restoration, including copying something else before the
  delayed restoration runs; the newer copy must survive.
- Test screenshot context with locally extracted OCR text.
- Quit during recording and confirm the saved recording appears after relaunch.
- Confirm completed transcripts appear in **Transcript History**.
