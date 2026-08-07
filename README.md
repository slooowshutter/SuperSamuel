# SuperSamuel

SuperSamuel is a small native macOS dictation app:

- Press `Option+Space` to start and stop recording.
- Record locally as compact 16 kHz mono AAC audio.
- With **Enhance** off, transcribe through OpenRouter with
  `openai/whisper-large-v3`.
- With **Enhance** on, send the audio directly to a configurable audio model,
  defaulting to `openai/gpt-audio-mini`.
- Paste the result back into the app that was active while dictating.
- Optionally attach a screenshot as context. Visible text is extracted locally;
  Gemini audio models can also receive the image itself.

There is no realtime websocket, token broker, or streaming transcript path.

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

## Configure OpenRouter

1. Open the `SS` menu-bar item.
2. Choose **Settings…**
3. Enter your OpenRouter API key. It is stored in the macOS Keychain.
4. Choose a suggested enhancement model or enter another OpenRouter chat model
   that accepts audio input.

Examples:

```text
openai/gpt-audio-mini
google/gemini-3.5-flash
mistralai/voxtral-small-24b-2507
```

The transcription model is fixed to:

```text
openai/whisper-large-v3
```

Enhancement is a single audio-model request: SuperSamuel does not run Whisper
first. Requests ask OpenRouter to route to the provider with the highest
advertised throughput.

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
record durable M4A audio
  ├─ Enhance off → OpenRouter Whisper Large V3
  └─ Enhance on  → selected OpenRouter audio model
                    + optional screenshot-derived context
  → clipboard
  → optional Command+V paste
```

The recording file and any attached screenshot are temporary and are removed
only after the final transcript has been saved successfully.

The waveform is calculated from `AVAudioRecorder` metering while the durable AAC
file is written. The recorder is recreated for every session so microphone
hardware changes after sleep or lock do not reuse a stale audio route.

## Recording recovery

Audio is stored under:

```text
~/Library/Application Support/SuperSamuel/Recordings/
```

Each recording has its own folder containing:

- The durable M4A recording (legacy recovered sessions may contain several parts)
- A JSON manifest
- Cached raw and cleaned transcript parts
- The final transcript while processing completes
- Optional screenshot context

If transcription, enhancement, cancellation, or app shutdown interrupts processing,
the recording remains in this folder. On the next launch, SuperSamuel presents
the oldest unsent recording and offers:

- **Send Recording**
- **Keep for Later**
- **Move to Trash**

The menu-bar **Unsent Recordings** submenu also supports sending, revealing the
folder in Finder, or moving it to Trash after confirmation. The recording
manifest includes the selected input device and the enhancement model chosen
for that recording. New recordings remain blocked while unsent recordings
exist.

If processing fails, completed parts remain cached and the original audio stays
available for retry.

Successfully processed text is stored under:

```text
~/Library/Application Support/SuperSamuel/Transcript History/
```

The **Transcript History** submenu shows recent transcript previews. Selecting
one copies its full text. History remains until explicitly cleared.

## Upload limits

SuperSamuel sends audio through OpenRouter's base64 JSON request paths. Durable
recordings remain compact 32 kbps M4A files (roughly 14 MB/hour). Whisper and
Gemini receive M4A directly. GPT Audio Mini and the tested Voxtral chat model
receive a temporary 16 kHz mono PCM WAV because their routed providers rejected
M4A; the WAV is removed immediately after the request. Successful results are
cached so a retry does not repeat completed work.

Official references:

- [OpenRouter speech-to-text](https://openrouter.ai/docs/guides/overview/multimodal/stt)
- [OpenRouter transcription API usage](https://openrouter.ai/docs/guides/overview/multimodal/stt#api-usage)
- [OpenRouter audio input](https://openrouter.ai/docs/guides/overview/multimodal/audio)

## Manual verification

- Start and stop recording with `Option+Space`.
- Confirm the waveform and timer update while recording.
- Cancel during transcription and confirm nothing is pasted.
- Confirm the cancelled recording appears under **Unsent Recordings**.
- Relaunch with an unsent recording and test Send, Keep, Reveal, and Delete.
- Test enhancement with GPT Audio Mini, Gemini, and a custom audio model ID.
- Test enhancement enabled and disabled.
- Test automatic paste in Notes, a browser textarea, and a code editor.
- Test clipboard restoration.
- Test screenshot context with GPT Audio Mini OCR text and Gemini image input.
- Quit during recording and confirm the saved recording appears after relaunch.
- Confirm completed transcripts appear in **Transcript History**.
