#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  test-model.sh  —  Test cloud model API exactly as dkn-proxy-node would
#
#  Usage:
#    bash scripts/test-model.sh [model_name] [nodes_dir]
#
#  Examples:
#    bash scripts/test-model.sh Nemotron-3-Super-120B-A12B
#    bash scripts/test-model.sh Qwen3-32B /root/dria-nodes
#    bash scripts/test-model.sh  # uses DEFAULT_MODEL from proxy.env
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

NODES_DIR="${2:-/root/dria-nodes}"
ENV_FILE="$NODES_DIR/proxy.env"
DOT_ENV="$NODES_DIR/.env"

# ── Colors ────────────────────────────────────────────────────────────────────
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'
C='\033[0;36m'; W='\033[1;37m'; N='\033[0m'
ok()   { echo -e "${G}[PASS]${N} $*"; }
fail() { echo -e "${R}[FAIL]${N} $*"; }
info() { echo -e "${C}[INFO]${N} $*"; }
warn() { echo -e "${Y}[WARN]${N} $*"; }
hdr()  { echo -e "\n${W}══ $* ══${N}"; }

# ── Read config ───────────────────────────────────────────────────────────────
_read_var() {
    local key="$1"
    # Try proxy.env first (PROXY_* format), then .env (VIKEY_* format)
    local val=""
    [ -f "$ENV_FILE" ] && val=$(grep -E "^${key}=" "$ENV_FILE" 2>/dev/null \
        | cut -d= -f2- | tr -d "'\"\r" | head -1)
    echo "$val"
}

API_URL=$(_read_var PROXY_API_URL)
API_KEY=$(_read_var PROXY_API_KEY)

# Fallback to .env VIKEY_* format
if [ -z "$API_URL" ] && [ -f "$DOT_ENV" ]; then
    API_URL=$(grep -E "^VIKEY_API_URL=" "$DOT_ENV" 2>/dev/null | cut -d= -f2- | tr -d "'\"\r" | head -1)
fi
if [ -z "$API_KEY" ] && [ -f "$DOT_ENV" ]; then
    API_KEY=$(grep -E "^VIKEY_API_KEY=" "$DOT_ENV" 2>/dev/null | cut -d= -f2- | tr -d "'\"\r" | head -1)
fi

DEFAULT_MODEL=$(_read_var PROXY_DEFAULT_MODEL)
[ -z "$DEFAULT_MODEL" ] && DEFAULT_MODEL=$(_read_var DEFAULT_MODEL)

TARGET_MODEL="${1:-$DEFAULT_MODEL}"

[ -z "$API_URL" ] && { fail "PROXY_API_URL not found in $ENV_FILE or $DOT_ENV"; exit 1; }
[ -z "$API_KEY" ] && { fail "PROXY_API_KEY / VIKEY_API_KEY not found"; exit 1; }
[ -z "$TARGET_MODEL" ] && { fail "No model specified. Pass as argument or set DEFAULT_MODEL."; exit 1; }

ENDPOINT="${API_URL%/}/chat/completions"

echo ""
echo -e "${W}╔══════════════════════════════════════════╗${N}"
echo -e "${W}║   dkn-proxy-node  Model Test Script     ║${N}"
echo -e "${W}╚══════════════════════════════════════════╝${N}"
echo ""
info "API URL   : $API_URL"
info "Model     : $TARGET_MODEL"
info "Key       : ${API_KEY:0:8}***"
echo ""

PASS=0; FAIL=0
TMPFILE=$(mktemp /tmp/dria-test-XXXXXX)
PY_PARSER=$(mktemp /tmp/dria-py-XXXXXX.py)
trap 'rm -f "$TMPFILE" "$PY_PARSER"' EXIT

# Write SSE parser to temp file (avoids heredoc-inside-$() conflict)
# Handles multi-line JSON chunks where literal \n in content breaks lines
cat > "$PY_PARSER" << 'PYEOF'
import sys, json

out = ''
current = ''

for raw_line in sys.stdin:
    line = raw_line.rstrip('\n\r')

    if line.startswith('data:'):
        # Process accumulated previous payload
        if current:
            try:
                d = json.loads(current)
                content = (d.get('choices') or [{}])[0].get('delta', {}).get('content')
                if content:
                    out += content
            except Exception:
                pass
        payload = line[5:].lstrip(' ')
        if payload == '[DONE]':
            current = ''
            break
        current = payload
    elif line == '':
        # Blank line = SSE event boundary; process current if any
        if current:
            try:
                d = json.loads(current)
                content = (d.get('choices') or [{}])[0].get('delta', {}).get('content')
                if content:
                    out += content
            except Exception:
                pass
            current = ''
    else:
        # Continuation of previous data line (literal newline inside JSON)
        current += '\n' + line

# Process any remaining payload
if current:
    try:
        d = json.loads(current)
        content = (d.get('choices') or [{}])[0].get('delta', {}).get('content')
        if content:
            out += content
    except Exception:
        pass

sys.stdout.write(out)
PYEOF

# ── Helper: send streaming request, collect full text ─────────────────────────
send_request() {
    local label="$1"
    local payload="$2"
    local allow_empty="${3:-false}"   # true = pass even if content is empty
    local t0; t0=$(date +%s%3N)

    # Write response to temp file to avoid bash variable newline mangling
    local http_code
    http_code=$(curl -s -X POST "$ENDPOINT" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_KEY" \
        --max-time 60 \
        -o "$TMPFILE" \
        -w "%{http_code}" \
        -d "$payload") || { fail "$label — curl failed (timeout or network error)"; (( FAIL++ )) || true; return 1; }

    local t1; t1=$(date +%s%3N)
    local elapsed=$(( t1 - t0 ))

    # Check HTTP status
    if [ "$http_code" != "200" ]; then
        local msg; msg=$(cat "$TMPFILE" | grep -oE '"message":"[^"]*"' | head -1 | cut -d: -f2- | tr -d '"')
        fail "$label — HTTP $http_code: $msg"
        echo "  Body: $(head -c 300 "$TMPFILE")"
        echo ""
        (( FAIL++ )) || true
        return 1
    fi

    # Check API error in body (only if no SSE chunks present)
    if ! grep -q "^data:" "$TMPFILE" 2>/dev/null; then
        if grep -qE '"error"|"detail"' "$TMPFILE" 2>/dev/null; then
            local msg; msg=$(grep -oE '"message":"[^"]*"' "$TMPFILE" | head -1 | cut -d: -f2- | tr -d '"')
            [ -z "$msg" ] && msg=$(head -c 200 "$TMPFILE")
            fail "$label — API error: $msg"
            (( FAIL++ )) || true
            return 1
        fi
    fi

    # Parse: pipe file directly to Python — avoids bash variable newline mangling
    local text=""
    if grep -q "^data:" "$TMPFILE" 2>/dev/null; then
        # SSE streaming: pipe raw file directly to parser (no bash variable)
        text=$(tr -d '\r' < "$TMPFILE" | python3 "$PY_PARSER")
    else
        # Non-streaming plain JSON
        text=$(tr -d '\r' < "$TMPFILE" | python3 -c "
import sys,json
try:
    d=json.loads(sys.stdin.read())
    sys.stdout.write(d['choices'][0]['message']['content'] or '')
except:
    sys.stdout.write('')
")
    fi

    # Prompt tokens (if available in body)
    local prompt_tok; prompt_tok=$(grep -oE '"prompt_tokens":[0-9]+' "$TMPFILE" | grep -oE '[0-9]+' | head -1)
    local comp_tok; comp_tok=$(grep -oE '"completion_tokens":[0-9]+' "$TMPFILE" | grep -oE '[0-9]+' | head -1)

    local word_count; word_count=$(echo "$text" | wc -w)

    # Empty content is OK if allow_empty=true (e.g. max_tokens=1 may return whitespace)
    if [ -z "${text// }" ] && [ "$allow_empty" != "true" ]; then
        fail "$label (${elapsed}ms) — empty content in response"
        echo "  Raw (first 400 chars): $(head -c 400 "$TMPFILE")"
        echo ""
        (( FAIL++ )) || true
        return 1
    fi

    ok "$label (${elapsed}ms | prompt:${prompt_tok:-?}tok comp:${comp_tok:-?}tok words:${word_count})"
    if [ -n "${text// }" ]; then
        echo "  Preview: $(echo "$text" | head -c 150 | tr '\n' ' ')..."
    else
        echo "  Preview: [whitespace/newline token — expected for max_tokens=1]"
    fi
    (( PASS++ )) || true
}

# ── Test 1: Basic streaming text generation ───────────────────────────────────
hdr "Test 1: Basic text generation (streaming)"
send_request "Basic generation" "$(cat <<EOF
{
  "model": "$TARGET_MODEL",
  "messages": [
    {"role": "user", "content": "What is 2+2? Reply in one sentence."}
  ],
  "stream": true,
  "temperature": 0.7,
  "max_tokens": 64,
  "top_p": 0.9
}
EOF
)"

# ── Test 2: Longer generation (like real Dria task) ───────────────────────────
hdr "Test 2: Task-length generation"
send_request "Task-length generation" "$(cat <<EOF
{
  "model": "$TARGET_MODEL",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant. Respond concisely."},
    {"role": "user", "content": "Explain how neural networks learn in 3 bullet points."}
  ],
  "stream": true,
  "temperature": 0.8,
  "max_tokens": 256,
  "top_p": 1.0,
  "seed": 42
}
EOF
)"

# ── Test 3: JSON schema output (Dria structured tasks) ────────────────────────
hdr "Test 3: JSON schema output (structured tasks)"
send_request "JSON schema output" "$(cat <<EOF
{
  "model": "$TARGET_MODEL",
  "messages": [
    {"role": "user", "content": "Return a JSON object with fields: name (string), score (number between 0-100), tags (array of strings). Fill with example data."}
  ],
  "stream": true,
  "temperature": 0.3,
  "max_tokens": 128,
  "response_format": {
    "type": "json_schema",
    "json_schema": {
      "name": "result",
      "strict": true,
      "schema": {
        "type": "object",
        "properties": {
          "name": {"type": "string"},
          "score": {"type": "number"},
          "tags": {"type": "array", "items": {"type": "string"}}
        },
        "required": ["name", "score", "tags"]
      }
    }
  }
}
EOF
)"

# ── Test 4: Long context / reasoning (nemotron specialty) ─────────────────────
hdr "Test 4: Agentic reasoning (Nemotron specialty)"
send_request "Agentic reasoning" "$(cat <<EOF
{
  "model": "$TARGET_MODEL",
  "messages": [
    {"role": "system", "content": "You are an AI agent that breaks down tasks into steps."},
    {"role": "user", "content": "Plan in 3 steps how to sort a list of numbers using bubble sort. Be brief."}
  ],
  "stream": true,
  "temperature": 0.5,
  "max_tokens": 200,
  "top_p": 0.95,
  "seed": 123
}
EOF
)"

# ── Test 5: Edge case — max_tokens=1 (minimal response) ──────────────────────
hdr "Test 5: Edge case — max_tokens=1"
send_request "max_tokens=1" "$(cat <<EOF
{
  "model": "$TARGET_MODEL",
  "messages": [
    {"role": "user", "content": "Say yes."}
  ],
  "stream": true,
  "temperature": 0.1,
  "max_tokens": 1
}
EOF
)" "true"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${W}══ Results ══${N}"
TOTAL=$(( PASS + FAIL ))
if [ "$FAIL" -eq 0 ]; then
    echo -e "${G}All $TOTAL tests passed. Model '$TARGET_MODEL' is ready for Dria tasks.${N}"
else
    echo -e "${R}$FAIL/$TOTAL tests FAILED. Model '$TARGET_MODEL' may have issues.${N}"
    echo ""
    warn "Common causes:"
    warn "  - Model name is wrong (check marketplace.fptcloud.com)"
    warn "  - API key expired or invalid"
    warn "  - response_format not supported by this model"
fi
echo ""
