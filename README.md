# SuperSamuel

SuperSamuel is a small native macOS dictation app:

- Press `Option+Space` to start and stop recording.
- Record locally as compact 16 kHz mono AAC audio.
- Optionally stream a 24 kHz PCM sidecar directly to OpenAI's Realtime API,
  using `gpt-transcribe` and showing the transcript in the recording overlay.
- Keep the local recording and configurable OpenRouter transcription path,
  defaulting to `openai/gpt-transcribe`, as the durable fallback.
- Paste the result back into the app that was active while dictating.
- Optionally attach a screenshot as context. Visible text is extracted locally
  and added to the transcription instructions.

Realtime transcription uses a direct authenticated WebSocket connection. Server
voice activity detection commits a turn after 500 ms of detected silence, so
completed phrases appear while recording. Releasing the hotkey commits any
remaining audio immediately.

The recording overlay keeps the complete live transcript in a scrollable area,
shows about five lines at its default size, and can be resized by dragging its
bottom-right resize grip. `gpt-transcribe` does not support the Realtime API's
`audio.input.transcription.delay` presets; attempting to send one causes the
session update to be rejected, so SuperSamuel leaves that parameter unset.

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
4. Enter an OpenAI API key and leave **Use realtime GPT Transcribe** enabled to
   show live transcription. This key is stored in a separate Keychain entry.
5. Optionally change the fallback model from `openai/gpt-transcribe`. Realtime
   is active only while this model is selected.
6. Edit the transcription instructions to match your dictation style and
   expected terminology.

The default transcription model is:

```text
openai/gpt-transcribe
```

SuperSamuel sends the instructions as GPT Transcribe's free-form `prompt`, both
for the direct Realtime session and for the OpenRouter fallback. GPT Transcribe
can use that context for light cleanup and style guidance, but it remains a
transcription model: the instructions do not alter the audio waveform, and
large semantic rewrites are not guaranteed. Screenshot text is extracted
locally and appended as additional disambiguation context without adding a
second model request. The realtime transcript is used directly; SuperSamuel
does not send it through a separate cleanup model before pasting.

## Headless dictation benchmark

The isolated benchmark runner compares the same audio through:

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
Keychain entry as the app. Every run creates a new directory containing:

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
  → OpenAI Realtime WebSocket using gpt-transcribe
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
recreated for every session so microphone hardware changes after sleep or lock
do not reuse a stale audio route.

## Recording recovery

Audio is stored under:

```text
~/Library/Application Support/SuperSamuel/Recordings/
```

Each recording has its own folder containing:

- The durable M4A recording (legacy recovered sessions may contain several parts)
- A JSON manifest
- Cached transcript parts (legacy recordings may also contain cleaned parts)
- The saved realtime or fallback draft in `draft-transcript.txt`
- The final transcript while processing completes
- Optional screenshot context

If transcription, cancellation, or app shutdown interrupts processing,
the recording remains in this folder. On the next launch, SuperSamuel presents
the oldest unsent recording and offers:

- **Send Recording**
- **Keep for Later**
- **Move to Trash**

The menu-bar **Unsent Recordings** submenu also supports sending, revealing the
folder in Finder, or moving it to Trash after confirmation. The recording
manifest includes the selected input device, transcription model, and
instructions chosen for that recording. New recordings remain blocked while
unsent recordings exist.

If processing fails, completed parts remain cached and the original audio stays
available for retry.

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

The **Transcript History** submenu shows recent transcript previews. Each entry
offers **Copy Transcript** and **Reveal Recording and Transcript in Finder**.
Older flat JSON history entries remain readable, while new entries use the
complete folder format. History remains until explicitly cleared; clearing it
also permanently deletes its archived recordings and metadata.

## Upload limits

With realtime enabled, SuperSamuel streams 24 kHz mono PCM to OpenAI while also
writing its compact 32 kbps M4A recording (roughly 14 MB/hour). If realtime is
disabled, cannot connect, or cannot complete, the durable recording is sent
through OpenRouter's base64 JSON transcription path. Successful results are
cached so a retry does not repeat completed work.

Official references:

- [OpenRouter speech-to-text](https://openrouter.ai/docs/guides/overview/multimodal/stt)
- [OpenRouter transcription API usage](https://openrouter.ai/docs/guides/overview/multimodal/stt#api-usage)
- [OpenAI Realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription)
- [OpenAI Realtime WebSocket](https://developers.openai.com/api/docs/guides/realtime-websocket)

## Manual verification

- Start and stop recording with `Option+Space`.
- Confirm the waveform and timer update while recording.
- With an OpenAI key configured, pause for about 500 ms and confirm completed
  phrases appear in the bottom of the recording overlay.
- Disable realtime and confirm the saved-recording path still transcribes.
- Interrupt the network during recording and confirm the saved M4A is used as
  the fallback.
- Cancel during transcription and confirm nothing is pasted.
- Confirm the cancelled recording appears under **Unsent Recordings**.
- Relaunch with an unsent recording and test Send, Keep, Reveal, and Delete.
- Confirm transcription instructions affect filler removal and expected terms.
- Test automatic paste in Notes, a browser textarea, and a code editor.
- Test clipboard restoration.
- Test screenshot context with locally extracted OCR text.
- Quit during recording and confirm the saved recording appears after relaunch.
- Confirm completed transcripts appear in **Transcript History**.
