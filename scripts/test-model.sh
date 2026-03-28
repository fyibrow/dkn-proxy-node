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

# ── Helper: send streaming request, collect full text ─────────────────────────
send_request() {
    local label="$1"
    local payload="$2"
    local t0; t0=$(date +%s%3N)

    local response
    response=$(curl -s -X POST "$ENDPOINT" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_KEY" \
        --max-time 60 \
        -d "$payload") || { fail "$label — curl failed (timeout or network error)"; (( FAIL++ )) || true; return 1; }

    local t1; t1=$(date +%s%3N)
    local elapsed=$(( t1 - t0 ))

    # Check HTTP error embedded in JSON
    if echo "$response" | grep -qE '"error"|"code":[45][0-9][0-9]'; then
        local msg; msg=$(echo "$response" | grep -oE '"message":"[^"]*"' | head -1 | cut -d: -f2- | tr -d '"')
        fail "$label — API error: $msg"
        echo "  Response: $response" | head -c 300
        echo ""
        (( FAIL++ )) || true
        return 1
    fi

    # Extract generated text from SSE stream or plain JSON
    local text=""
    if echo "$response" | grep -q "^data:"; then
        # SSE streaming format
        text=$(echo "$response" | grep "^data:" | grep -v "\[DONE\]" \
            | sed 's/^data: //' \
            | python3 -c "
import sys, json
out = ''
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        c = d.get('choices', [{}])[0].get('delta', {}).get('content') or ''
        out += c
    except: pass
print(out, end='')
" 2>/dev/null)
    else
        # Non-streaming JSON
        text=$(echo "$response" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(d['choices'][0]['message']['content'], end='')
except Exception as e:
    print(f'parse_error:{e}', end='')
" 2>/dev/null)
    fi

    # Prompt tokens (if available)
    local prompt_tok; prompt_tok=$(echo "$response" \
        | grep -oE '"prompt_tokens":[0-9]+' | grep -oE '[0-9]+' | head -1)
    local comp_tok; comp_tok=$(echo "$response" \
        | grep -oE '"completion_tokens":[0-9]+' | grep -oE '[0-9]+' | head -1)

    local word_count; word_count=$(echo "$text" | wc -w)

    if [ -z "$text" ] || [ "$text" = "null" ]; then
        fail "$label (${elapsed}ms) — empty response"
        echo "  Raw: $(echo "$response" | head -c 400)"
        (( FAIL++ )) || true
        return 1
    fi

    ok "$label (${elapsed}ms | prompt:${prompt_tok:-?}tok comp:${comp_tok:-?}tok words:${word_count})"
    echo "  Preview: $(echo "$text" | head -c 120)..."
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
)"

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
