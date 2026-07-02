# local_audio_summarizer

Local, on-device meeting transcription and summarization for macOS Apple Silicon.

This project is aimed at long meetings (up to about 3 hours) on a machine like:
- MacBook Air M2
- 16 GiB RAM

The current script in [audio_summarizer.sh](audio_summarizer.sh) does this:
1. Transcodes source audio to mono 16 kHz WAV with a local cache to avoid re-transcoding unchanged files.
2. Uses VAD with ggml-silero-v6.2.0 to filter out silence and reduce the amount of audio to transcribe and summarize.
3. Transcribes with whisper.cpp and caches TXT/SRT outputs so failed summarization retries can skip re-transcription.
4. Summarizes with local Ollama model audio-summarizer.
5. Uses single-pass summarization for shorter transcripts.
6. Uses map-reduce summarization for long transcripts.

## Default path used by the script

By default, the script expects whisper.cpp here:

```text
$HOME/src/whisper.cpp
```

You can override this without editing the script:

```bash
WHISPER_DIR=/some/other/path/to/whisper.cpp ./audio_summarizer.sh meeting.wav
```

## 1) Install base tooling on a clean Mac

### Install Xcode Command Line Tools

```bash
xcode-select --install
```

### Install Homebrew (if missing)

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

After installation, follow Homebrew output instructions to add brew to your shell path.

### Install required packages

```bash
brew update
brew install git cmake ffmpeg python pkg-config
brew install --cask ollama
```

## 2) Clone and build whisper.cpp

From any working directory:

```bash
mkdir -p "$HOME/src"
cd "$HOME/src"
git clone https://github.com/ggerganov/whisper.cpp
cd whisper.cpp
cmake -S . -B build
cmake --build build -j
```

Expected binary after build:

```text
$HOME/src/whisper.cpp/build/bin/whisper-cli
```

## 3) Download whisper models required by the script

From inside whisper.cpp:

```bash
cd "$HOME/src/whisper.cpp"
./models/download-ggml-model.sh large-v3-turbo
./models/download-vad-model.sh
```

Verify expected model files exist:

```bash
ls -lh "$HOME/src/whisper.cpp/models/ggml-large-v3-turbo.bin"
ls -lh "$HOME/src/whisper.cpp/models/ggml-silero-v6.2.0.bin"
```

If the VAD download produces a different filename in your whisper.cpp version, update the -vm argument in [audio_summarizer.sh](audio_summarizer.sh) to match.

## 4) Start Ollama and create the summarizer model

Start the Ollama app once (Applications -> Ollama), then in terminal:

```bash
ollama list
```

If this command works, create the model from [Modelfile](Modelfile):

```bash
cd "$HOME/src/local_audio_summarizer"
ollama pull qwen3:8b
ollama create audio-summarizer -f Modelfile
ollama show audio-summarizer
```

## 5) Prepare input audio (recommended format)

Best results come from mono 16 kHz WAV.

The script can take many common audio formats directly and will transcode automatically.
That transcoding is cached by source path + file metadata to avoid re-transcoding the same unchanged source.

Cache location:

```text
$HOME/.cache/local_audio_summarizer/transcoded/
```

Transcript cache location:

```text
$HOME/.cache/local_audio_summarizer/transcripts/
```

Convert source audio:

```bash
ffmpeg -i input.m4a -ac 1 -ar 16000 -c:a pcm_s16le meeting.wav
```

## 6) Run the summarizer

From repo root:

```bash
cd "$HOME/src/local_audio_summarizer"
chmod +x audio_summarizer.sh
./audio_summarizer.sh meeting.wav
```

You can also pass an absolute path:

```bash
./audio_summarizer.sh /full/path/to/meeting.wav
```

The default Ollama model name is audio-summarizer. You can override it per run:

```bash
SUMMARY_MODEL=audio-summarizer ./audio_summarizer.sh meeting.wav
```

## 7) Output location

The script writes outputs under:

```text
$HOME/.local/share/meeting-summaries/<meeting_name>_<timestamp>/
```

Files produced:
- transcript.clean.txt
- transcript.srt
- summary.txt
- chunk_summaries.txt (for long meetings)

## 8) Quick verification checklist

Run these checks before first real meeting:

```bash
command -v ffmpeg
command -v python3
command -v ollama
test -x "$HOME/src/whisper.cpp/build/bin/whisper-cli" && echo "whisper-cli ok"
test -f "$HOME/src/whisper.cpp/models/ggml-large-v3-turbo.bin" && echo "asr model ok"
test -f "$HOME/src/whisper.cpp/models/ggml-silero-v6.2.0.bin" && echo "vad model ok"
ollama show audio-summarizer >/dev/null && echo "ollama model ok"
```

## 9) Troubleshooting

### error: cannot cd to $HOME/src/whisper.cpp
- whisper.cpp is not at the default path.
- Move whisper.cpp to $HOME/src/whisper.cpp or run with WHISPER_DIR set.

### error: transcription failed — no output produced
- Input file is invalid or unsupported.
- Re-encode with ffmpeg to mono 16 kHz WAV and retry.

### model "audio-summarizer" not found
- Create the model with:

```bash
cd "$HOME/src/local_audio_summarizer"
ollama create audio-summarizer -f Modelfile
```

### ollama list fails
- Ollama service is not running.
- Launch the Ollama app once, then retry.

## Current repository files

- [audio_summarizer.sh](audio_summarizer.sh)
- [README.md](README.md)
- [Modelfile](Modelfile)
