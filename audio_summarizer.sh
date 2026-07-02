#!/bin/bash
# audio_summarizer.sh — transcribe + map-reduce summarize
# Usage: ./audio_summarizer.sh input.wav

INPUT="$1"

# ── Validate input ──
if [ -z "$INPUT" ]; then
  echo "Usage: $0 <audio-file>"
  exit 1
fi

# Resolve to absolute path — handles relative paths, ~, spaces, unicode, etc.
INPUT_ABS=$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")

if [ ! -f "$INPUT_ABS" ]; then
  echo "error: input file not found: $INPUT"
  exit 1
fi

# ── Set up paths ──
# Sanitize basename for use in directory names (replace problematic chars)
BASENAME=$(basename "$INPUT")
BASENAME="${BASENAME%.*}"
SAFE_NAME=$(echo "$BASENAME" | sed 's/[\/\\:<>|*?"\x29f8]/_/g' | tr ' ' '_')

# Override via WHISPER_DIR env var if whisper.cpp is elsewhere.
WHISPER_DIR="${WHISPER_DIR:-$HOME/src/whisper.cpp}"
STORAGE_DIR="$HOME/.local/share/meeting-summaries"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
JOB_DIR="${STORAGE_DIR}/${SAFE_NAME}_${TIMESTAMP}"

mkdir -p "$JOB_DIR"

# Fixed, safe filenames within the job dir
TRANSCRIPT="${JOB_DIR}/transcript.clean.txt"
SRT_FILE="${JOB_DIR}/transcript.srt"
SUMMARY_FILE="${JOB_DIR}/summary.txt"
CHUNK_DIR="${JOB_DIR}/chunks"
CHUNK_SUMMARIES="${JOB_DIR}/chunk_summaries.txt"
WOUTPUT="${JOB_DIR}/transcript"  # whisper-cli -of base path
SUMMARY_MODEL="${SUMMARY_MODEL:-audio-summarizer}"

cd "$WHISPER_DIR" || { echo "error: cannot cd to $WHISPER_DIR"; exit 1; }

if [ ! -x "./build/bin/whisper-cli" ]; then
  echo "error: whisper-cli not found at $WHISPER_DIR/build/bin/whisper-cli"
  echo "       Build whisper.cpp first or set WHISPER_DIR to the correct path."
  exit 1
fi

# ── Step 1: Transcribe ──
echo "=== Transcribing with whisper.cpp ==="
echo "    Input:      $INPUT_ABS"
echo "    Output dir: $JOB_DIR"
echo ""

./build/bin/whisper-cli \
  -m models/ggml-large-v3-turbo.bin \
  -vm models/ggml-silero-v6.2.0.bin \
  --vad \
  -bs 5 -et 2.8 -mc 64 -nth 0.6 \
  -l en -sow \
  -otxt -osrt \
  -f "$INPUT_ABS" \
  -of "$WOUTPUT"

# Check if whisper-cli produced output
if [ ! -f "${WOUTPUT}.txt" ] || [ ! -f "${WOUTPUT}.srt" ]; then
  echo ""
  echo "error: transcription failed — no output produced"
  echo "       Check that the input file is a valid audio file."
  exit 1
fi

# Keep the SRT as-is for reference
cp "${WOUTPUT}.srt" "$SRT_FILE"

# Flatten the TXT output (segment-per-line) into continuous text for the LLM
tr '\n' ' ' < "${WOUTPUT}.txt" | sed 's/  */ /g' > "$TRANSCRIPT"

# Clean up the raw whisper output files (we have copies in our standard names)
rm -f "${WOUTPUT}.txt" "${WOUTPUT}.srt"

WORD_COUNT=$(wc -w < "$TRANSCRIPT")
echo ""
echo "Transcript: $WORD_COUNT words"

# Verify we actually got meaningful transcription
if [ "$WORD_COUNT" -eq 0 ]; then
  echo "error: transcription produced no words — check input audio"
  exit 1
fi

# ── Step 2: Determine strategy ──
CHUNK_SIZE=6000

if [ "$WORD_COUNT" -le "$CHUNK_SIZE" ]; then
  # ── Short meeting: single-pass summary ──
  echo "=== Short meeting — direct summarization ==="
  ollama run "$SUMMARY_MODEL" "$(cat <<EOF
Summarize this meeting transcript. Include:
1. Brief overview (2-3 sentences)
2. Key decisions made
3. Action items (with responsible party if mentioned)
4. Important discussion points

Transcript:
$(cat "$TRANSCRIPT")
EOF
)" | tee "$SUMMARY_FILE"
else
  # ── Long meeting: map-reduce ──
  echo "=== Long meeting — map-reduce summarization ==="

  mkdir -p "$CHUNK_DIR"

  python3 -c "
text = open('$TRANSCRIPT').read()
words = text.split()
chunk_size = $CHUNK_SIZE
for i in range(0, len(words), chunk_size):
    chunk = ' '.join(words[i:i+chunk_size])
    with open(f'$CHUNK_DIR/chunk_{i//chunk_size:03d}.txt', 'w') as f:
        f.write(chunk)
print(f'Split into {(len(words) + chunk_size - 1) // chunk_size} chunks')
"

  # MAP: Summarize each chunk
  echo "--- Summarizing chunks ---"
  for chunk in "$CHUNK_DIR"/chunk_*.txt; do
    echo "  Processing $(basename "$chunk")..."
    ollama run "$SUMMARY_MODEL" "$(cat <<EOF
Summarize this portion of a meeting transcript. Focus on:
- Key decisions
- Action items (with responsible party if mentioned)
- Important discussion points
Be concise.

Transcript portion:
$(cat "$chunk")
EOF
)" >> "$CHUNK_SUMMARIES"
    echo "---" >> "$CHUNK_SUMMARIES"
  done

  # REDUCE: Combine chunk summaries into final summary
  echo "--- Combining summaries ---"
  ollama run "$SUMMARY_MODEL" "$(cat <<EOF
You are combining summaries from different portions of a long meeting.
Create a unified meeting summary with:
1. Brief overview (2-3 sentences)
2. Key decisions made (consolidated, no duplicates)
3. Action items (with responsible party if mentioned)
4. Important discussion points (organized by topic)

Chunk summaries:
$(cat "$CHUNK_SUMMARIES")
EOF
)" | tee "$SUMMARY_FILE"

  echo ""
  echo "Chunk summaries saved: $CHUNK_SUMMARIES"
fi

echo ""
echo "=== Output files ==="
echo "  Transcript:  $TRANSCRIPT"
echo "  SRT:         $SRT_FILE"
echo "  Summary:     $SUMMARY_FILE"

