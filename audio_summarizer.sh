#!/bin/bash
# audio_summarizer.sh — transcribe + map-reduce summarize
# Usage: ./audio_summarizer.sh --profile <meeting|workshop|tv|movie> <audio-file> [context-file ...]

print_usage() {
  echo "Usage: $0 [--profile <meeting|workshop|tv|movie>] <audio-file> [context-file ...]"
  echo ""
  echo "Examples:"
  echo "  $0 --profile workshop workshop.wav slides.pdf"
  echo "  $0 -p tv episode.wav"
}

SUMMARY_PROFILE="meeting"
INPUT=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -p|--profile)
      if [ -z "${2:-}" ]; then
        echo "error: missing value for $1"
        print_usage
        exit 1
      fi
      SUMMARY_PROFILE="$2"
      shift 2
      ;;
    --profile=*)
      SUMMARY_PROFILE="${1#*=}"
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "error: unknown option: $1"
      print_usage
      exit 1
      ;;
    *)
      INPUT="$1"
      shift
      break
      ;;
  esac
done

if [ -z "$INPUT" ] && [ "$#" -gt 0 ]; then
  INPUT="$1"
  shift
fi

CONTEXT_FILES=("$@")

cache_key_for_file() {
  local file_path="$1"
  local fingerprint
  fingerprint="${file_path}|$(stat -f '%m|%z' "$file_path")"
  printf '%s' "$fingerprint" | shasum -a 256 | awk '{print $1}'
}

get_or_create_transcoded_audio() {
  local src="$1"
  local cache_dir="$HOME/.cache/local_audio_summarizer/transcoded"
  local key
  local output
  local tmp_output

  key="$(cache_key_for_file "$src")"
  output="$cache_dir/${key}.wav"
  tmp_output="$output.tmp.wav"

  mkdir -p "$cache_dir"

  if [ -f "$output" ]; then
    echo "$output"
    return 0
  fi

  command -v ffmpeg >/dev/null 2>&1 || {
    echo "error: ffmpeg not found; install ffmpeg to enable transcoding" >&2
    return 1
  }

  ffmpeg -hide_banner -loglevel error -y \
    -i "$src" \
    -ac 1 -ar 16000 -c:a pcm_s16le \
    "$tmp_output" || return 1

  mv "$tmp_output" "$output"
  echo "$output"
}

transcript_cache_key() {
  local prepared_audio="$1"
  local whisper_model_rel="models/ggml-large-v3-turbo.bin"
  local vad_model_rel="models/ggml-silero-v6.2.0.bin"
  local whisper_args_sig="-bs 5 -et 2.8 -mc 64 -nth 0.6 -l en -sow --vad"
  local audio_fingerprint
  local whisper_model_fingerprint="missing"
  local vad_model_fingerprint="missing"
  local fingerprint

  audio_fingerprint="$(stat -f '%m|%z' "$prepared_audio")"
  if [ -f "$WHISPER_DIR/$whisper_model_rel" ]; then
    whisper_model_fingerprint="$(stat -f '%m|%z' "$WHISPER_DIR/$whisper_model_rel")"
  fi
  if [ -f "$WHISPER_DIR/$vad_model_rel" ]; then
    vad_model_fingerprint="$(stat -f '%m|%z' "$WHISPER_DIR/$vad_model_rel")"
  fi

  fingerprint="${prepared_audio}|${audio_fingerprint}|${whisper_model_rel}|${whisper_model_fingerprint}|${vad_model_rel}|${vad_model_fingerprint}|${whisper_args_sig}"
  printf '%s' "$fingerprint" | shasum -a 256 | awk '{print $1}'
}

run_summary_prompt() {
  local prompt="$1"
  ollama run --nowordwrap "$SUMMARY_MODEL" "$prompt"
}

extract_context_text() {
  local context_text_file="$1"
  local audio_dir="$2"
  shift
  shift
  local context_file
  local resolved_context_file

  : > "$context_text_file"

  if [ "$#" -eq 0 ]; then
    return 0
  fi

  for context_file in "$@"; do
    if [ -f "$context_file" ]; then
      resolved_context_file="$context_file"
    elif [ -f "$audio_dir/$context_file" ]; then
      resolved_context_file="$audio_dir/$context_file"
    else
      echo "error: context file not found: $context_file"
      echo "       looked in: current directory and $audio_dir"
      return 1
    fi

    case "$resolved_context_file" in
      *.pdf|*.PDF)
        command -v pdftotext >/dev/null 2>&1 || {
          echo "error: pdftotext not found; install poppler to extract PDF context"
          echo "       Example: brew install poppler"
          return 1
        }
        echo "    Context:    PDF $resolved_context_file"
        pdftotext -layout "$resolved_context_file" - | tr '\n' ' ' | sed 's/  */ /g' >> "$context_text_file"
        echo "" >> "$context_text_file"
        ;;
      *)
        echo "    Context:    text $resolved_context_file"
        tr '\n' ' ' < "$resolved_context_file" | sed 's/  */ /g' >> "$context_text_file"
        echo "" >> "$context_text_file"
        ;;
    esac
  done
}

ensure_summary_model_available() {
  command -v ollama >/dev/null 2>&1 || {
    echo "error: ollama not found; install ollama first"
    return 1
  }

  if ollama show "$SUMMARY_MODEL" >/dev/null 2>&1; then
    return 0
  fi

  echo "error: summary model not found in Ollama: $SUMMARY_MODEL"
  echo "       Build it first with ollama create."

  case "$SUMMARY_PROFILE" in
    meeting|workshop|tv|movie)
      local script_dir
      local profile_file
      script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      profile_file="$script_dir/profiles/Modelfile.$SUMMARY_PROFILE"
      if [ -f "$profile_file" ]; then
        echo "       Example: ollama create $SUMMARY_MODEL -f $profile_file"
      fi
      ;;
  esac

  return 1
}

# ── Validate input ──
if [ -z "$INPUT" ]; then
  print_usage
  exit 1
fi

# Resolve to absolute path — handles relative paths, ~, spaces, unicode, etc.
INPUT_ABS=$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")

if [ ! -f "$INPUT_ABS" ]; then
  echo "error: input file not found: $INPUT"
  exit 1
fi

echo "=== Preparing audio ==="
INPUT_FOR_WHISPER="$(get_or_create_transcoded_audio "$INPUT_ABS")" || {
  echo "error: failed to prepare input audio for transcription"
  exit 1
}
echo "    Source:     $INPUT_ABS"
echo "    Transcoded: $INPUT_FOR_WHISPER"
echo ""

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
METADATA_FILE="${JOB_DIR}/run_metadata.txt"
CHUNK_DIR="${JOB_DIR}/chunks"
CHUNK_SUMMARIES="${JOB_DIR}/chunk_summaries.txt"
WOUTPUT="${JOB_DIR}/transcript"  # whisper-cli -of base path
if [ -z "${SUMMARY_MODEL:-}" ]; then
  case "$SUMMARY_PROFILE" in
    meeting) SUMMARY_MODEL="audio-summarizer-meeting" ;;
    workshop) SUMMARY_MODEL="audio-summarizer-workshop" ;;
    tv) SUMMARY_MODEL="audio-summarizer-tv" ;;
    movie) SUMMARY_MODEL="audio-summarizer-movie" ;;
    *)
      echo "error: invalid SUMMARY_PROFILE '$SUMMARY_PROFILE'"
      echo "       valid profiles: meeting, workshop, tv, movie"
      exit 1
      ;;
  esac
else
  SUMMARY_MODEL="$SUMMARY_MODEL"
fi
TRANSCRIPT_CACHE_DIR="$HOME/.cache/local_audio_summarizer/transcripts"
CONTEXT_TEXT_FILE="$JOB_DIR/context.txt"

{
  echo "Run timestamp: $TIMESTAMP"
  echo "Profile: $SUMMARY_PROFILE"
  echo "Summary model: $SUMMARY_MODEL"
  echo "Input audio: $INPUT_ABS"
  echo "Prepared audio: $INPUT_FOR_WHISPER"
  echo "Output directory: $JOB_DIR"
  echo "Context files:"
  if [ "${#CONTEXT_FILES[@]}" -eq 0 ]; then
    echo "  none"
  else
    for context_file in "${CONTEXT_FILES[@]}"; do
      echo "  - $context_file"
    done
  fi
} > "$METADATA_FILE"

ensure_summary_model_available || exit 1

cd "$WHISPER_DIR" || { echo "error: cannot cd to $WHISPER_DIR"; exit 1; }

if [ ! -x "./build/bin/whisper-cli" ]; then
  echo "error: whisper-cli not found at $WHISPER_DIR/build/bin/whisper-cli"
  echo "       Build whisper.cpp first or set WHISPER_DIR to the correct path."
  exit 1
fi

# ── Step 1: Transcribe ──
echo "=== Transcribing with whisper.cpp ==="
echo "    Input:      $INPUT_FOR_WHISPER"
echo "    Output dir: $JOB_DIR"
echo ""

mkdir -p "$TRANSCRIPT_CACHE_DIR"
TRANSCRIPT_KEY="$(transcript_cache_key "$INPUT_FOR_WHISPER")"
CACHED_TXT="$TRANSCRIPT_CACHE_DIR/${TRANSCRIPT_KEY}.txt"
CACHED_SRT="$TRANSCRIPT_CACHE_DIR/${TRANSCRIPT_KEY}.srt"

if [ -f "$CACHED_TXT" ] && [ -f "$CACHED_SRT" ]; then
  echo "    Cache:      hit ($TRANSCRIPT_KEY)"
  TRANSCRIPT_CACHE_STATUS="hit"
  cp "$CACHED_SRT" "$SRT_FILE"
  tr '\n' ' ' < "$CACHED_TXT" | sed 's/  */ /g' > "$TRANSCRIPT"
else
  echo "    Cache:      miss ($TRANSCRIPT_KEY)"
  TRANSCRIPT_CACHE_STATUS="miss"
  ./build/bin/whisper-cli \
    -m models/ggml-large-v3-turbo.bin \
    -vm models/ggml-silero-v6.2.0.bin \
    --vad \
    -bs 5 -et 2.8 -mc 64 -nth 0.6 \
    -l en -sow \
    -otxt -osrt \
    -f "$INPUT_FOR_WHISPER" \
    -of "$WOUTPUT"

  # Check if whisper-cli produced output
  if [ ! -f "${WOUTPUT}.txt" ] || [ ! -f "${WOUTPUT}.srt" ]; then
    echo ""
    echo "error: transcription failed — no output produced"
    echo "       Check that the input file is a valid audio file."
    exit 1
  fi

  cp "${WOUTPUT}.txt" "$CACHED_TXT"
  cp "${WOUTPUT}.srt" "$CACHED_SRT"

  # Flatten the TXT output (segment-per-line) into continuous text for the LLM
  tr '\n' ' ' < "${WOUTPUT}.txt" | sed 's/  */ /g' > "$TRANSCRIPT"

  # Clean up the raw whisper output files (we have copies in our standard names)
  rm -f "${WOUTPUT}.txt"
fi

WORD_COUNT=$(wc -w < "$TRANSCRIPT")
echo ""
echo "Transcript: $WORD_COUNT words"

{
  echo "Transcript cache: $TRANSCRIPT_CACHE_STATUS"
  echo "Transcript words: $WORD_COUNT"
} >> "$METADATA_FILE"

# Verify we actually got meaningful transcription
if [ "$WORD_COUNT" -eq 0 ]; then
  echo "error: transcription produced no words — check input audio"
  exit 1
fi

# ── Step 2: Determine strategy ──
CHUNK_SIZE=6000
extract_context_text "$CONTEXT_TEXT_FILE" "$(dirname "$INPUT_ABS")" "${CONTEXT_FILES[@]}" || exit 1

CONTEXT_BLOCK=""
if [ -s "$CONTEXT_TEXT_FILE" ]; then
  CONTEXT_BLOCK=$(cat <<EOF

Relevant context from attached documents:
$(cat "$CONTEXT_TEXT_FILE")

EOF
)
fi

SHORT_PROMPT_HEADER=""
MAP_PROMPT_HEADER=""
REDUCE_PROMPT_HEADER=""

case "$SUMMARY_PROFILE" in
  meeting)
    SHORT_PROMPT_HEADER="Summarize this meeting transcript. Include:
1. Brief overview (2-3 sentences)
2. Key decisions made
3. Action items (with responsible party if mentioned)
4. Important discussion points"

    MAP_PROMPT_HEADER="Summarize this portion of a meeting transcript. Focus on:
- Key decisions
- Action items (with responsible party if mentioned)
- Important discussion points
Be concise."

    REDUCE_PROMPT_HEADER="You are combining summaries from different portions of a long meeting.
Create a unified meeting summary with:
1. Brief overview (2-3 sentences)
2. Key decisions made (consolidated, no duplicates)
3. Action items (with responsible party if mentioned)
4. Important discussion points (organized by topic)"
    ;;
  workshop)
    SHORT_PROMPT_HEADER="Summarize this workshop transcript. Include:
1. Session synopsis (2-4 sentences)
2. Core concepts taught
3. Demonstrations and examples shown
4. Exercises, assignments, or next practice steps
5. Q&A highlights and unresolved questions"

    MAP_PROMPT_HEADER="Summarize this portion of a workshop transcript. Focus on:
- Concepts taught
- Demonstrations/examples
- Exercises/assignments/practice steps
- Q&A highlights and unresolved questions
Be concise and avoid repetition."

    REDUCE_PROMPT_HEADER="You are combining summaries from different portions of a long workshop.
Create a unified workshop summary with:
1. Session synopsis (2-4 sentences)
2. Core concepts taught (deduplicated)
3. Demonstrations and examples shown
4. Exercises, assignments, or next practice steps
5. Q&A highlights and unresolved questions"
    ;;
  tv)
    SHORT_PROMPT_HEADER="Summarize this TV episode transcript. Include:
1. Episode overview (3-5 sentences)
2. Major plot beats in chronological order
3. Character developments and relationship changes
4. Memorable scenes or lines (short quotes only if present)
5. Cliffhangers, open questions, or setup for later episodes"

    MAP_PROMPT_HEADER="Summarize this portion of a TV episode transcript. Focus on:
- Plot beats in order
- Character developments and relationship changes
- Memorable scenes/lines if present
- Open questions or setup for later episodes
Be concise and factual."

    REDUCE_PROMPT_HEADER="You are combining summaries from different portions of a TV episode.
Create a unified episode summary with:
1. Episode overview (3-5 sentences)
2. Major plot beats in chronological order
3. Character developments and relationship changes
4. Memorable scenes or lines
5. Cliffhangers, open questions, or setup for later episodes"
    ;;
  movie)
    SHORT_PROMPT_HEADER="Summarize this movie transcript. Include:
1. Film overview (3-5 sentences)
2. Story arc by act (setup, confrontation, resolution)
3. Main character goals, conflicts, and transformations
4. Key themes and motifs with transcript evidence
5. Ending impact and unresolved threads"

    MAP_PROMPT_HEADER="Summarize this portion of a movie transcript. Focus on:
- Story progression
- Character goals, conflicts, and changes
- Themes/motifs supported by transcript evidence
- Notable setup or payoff elements
Be concise and avoid speculation."

    REDUCE_PROMPT_HEADER="You are combining summaries from different portions of a movie.
Create a unified film summary with:
1. Film overview (3-5 sentences)
2. Story arc by act (setup, confrontation, resolution)
3. Main character goals, conflicts, and transformations
4. Key themes and motifs with transcript evidence
5. Ending impact and unresolved threads"
    ;;
  *)
    echo "error: unsupported SUMMARY_PROFILE for prompt templates: $SUMMARY_PROFILE"
    exit 1
    ;;
esac

if [ "$WORD_COUNT" -le "$CHUNK_SIZE" ]; then
  # ── Short transcript: single-pass summary ──
  echo "=== Short transcript — direct summarization ==="
  SHORT_PROMPT="$(cat <<EOF
${SHORT_PROMPT_HEADER}

${CONTEXT_BLOCK}
Transcript:
$(cat "$TRANSCRIPT")
EOF
)"

  run_summary_prompt "$SHORT_PROMPT" | tee "$SUMMARY_FILE" || {
    echo "error: summarization failed for model '$SUMMARY_MODEL'"
    exit 1
  }
else
  # ── Long transcript: map-reduce ──
  echo "=== Long transcript — map-reduce summarization ==="

  CHUNK_COUNT=0

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
  : > "$CHUNK_SUMMARIES"
  for chunk in "$CHUNK_DIR"/chunk_*.txt; do
    chunk_name=$(basename "$chunk" .txt)
    echo "  Processing $chunk_name..."
    CHUNK_PROMPT="$(cat <<EOF
${MAP_PROMPT_HEADER}

  ${CONTEXT_BLOCK}
Transcript portion:
$(cat "$chunk")
EOF
)"
    printf '=== %s Summary ===\n' "$chunk_name" >> "$CHUNK_SUMMARIES"
    run_summary_prompt "$CHUNK_PROMPT" >> "$CHUNK_SUMMARIES" || {
      echo "error: summarization failed while processing $chunk_name with model '$SUMMARY_MODEL'"
      exit 1
    }
    echo "---" >> "$CHUNK_SUMMARIES"
  done

  CHUNK_COUNT=$(find "$CHUNK_DIR" -maxdepth 1 -name 'chunk_*.txt' | wc -l | tr -d ' ')

  {
    echo "Summary strategy: long / map-reduce"
    echo "Chunk count: $CHUNK_COUNT"
    echo "Chunk summaries file: $CHUNK_SUMMARIES"
  } >> "$METADATA_FILE"

  # REDUCE: Combine chunk summaries into final summary
  echo "--- Combining summaries ---"
  REDUCE_PROMPT="$(cat <<EOF
${REDUCE_PROMPT_HEADER}

Important synthesis rules:
- The chunk summaries are chronological; use the full sequence from start to finish.
- Do not summarize only the last chunk.
- Build the final answer from repeated themes and decisions across multiple chunks.
- If later chunks revisit earlier topics, merge them rather than replacing earlier context.

${CONTEXT_BLOCK}
Chunk summaries:
$(cat "$CHUNK_SUMMARIES")
EOF
)"

  run_summary_prompt "$REDUCE_PROMPT" | tee "$SUMMARY_FILE" || {
    echo "error: final reduce summarization failed for model '$SUMMARY_MODEL'"
    exit 1
  }

  echo ""
  echo "Chunk summaries saved: $CHUNK_SUMMARIES"
fi

if [ "$WORD_COUNT" -le "$CHUNK_SIZE" ]; then
  {
    echo "Summary strategy: short / single-pass"
    echo "Chunk count: 0"
  } >> "$METADATA_FILE"
fi

{
  echo "Summary file: $SUMMARY_FILE"
  echo "SRT file: $SRT_FILE"
  echo "Transcript file: $TRANSCRIPT"
} >> "$METADATA_FILE"

echo ""
echo "=== Output files ==="
echo "  Transcript:  $TRANSCRIPT"
echo "  SRT:         $SRT_FILE"
echo "  Summary:     $SUMMARY_FILE"
echo "  Metadata:    $METADATA_FILE"

