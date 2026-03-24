#!/usr/bin/env bash
# market-watch-any.sh
# Quote-only market watcher for any target/base token pair.

set -euo pipefail

CHAIN=""
TOKEN=""
AMOUNT=""
TOKEN_SYMBOL=""
BASE_TOKEN="speed"
BASE_TOKEN_SYMBOL=""
POLL_SECONDS=60
MAX_ITERATIONS=0 # 0 = run forever

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chain) CHAIN="$2"; shift 2 ;;
        --token) TOKEN="$2"; shift 2 ;;
        --amount) AMOUNT="$2"; shift 2 ;;
        --tokensymbol) TOKEN_SYMBOL="$2"; shift 2 ;;
        --base-token) BASE_TOKEN="$2"; shift 2 ;;
        --base-token-symbol) BASE_TOKEN_SYMBOL="$2"; shift 2 ;;
        --pollseconds) POLL_SECONDS="$2"; shift 2 ;;
        --maxiterations) MAX_ITERATIONS="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$CHAIN" || -z "$TOKEN" || -z "$AMOUNT" ]]; then
    echo "Usage: $0 --chain <chain> --token <addr|alias> --amount <base amount> [--tokensymbol <name>] [--base-token <addr|alias>] [--base-token-symbol <name>] [--pollseconds <s>] [--maxiterations <n>]" >&2
    exit 1
fi

if [[ "${BASE_TOKEN,,}" == "${TOKEN,,}" ]]; then
    BASE_TOKEN="eth"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GRAY='\033[0;90m'
RESET='\033[0m'

rpc_for_chain() {
    case "${1,,}" in
        base|8453) echo "https://mainnet.base.org" ;;
        ethereum|mainnet|eth|1) echo "https://eth.llamarpc.com" ;;
        optimism|op|10) echo "https://mainnet.optimism.io" ;;
        arbitrum|arb|42161) echo "https://arb1.arbitrum.io/rpc" ;;
        polygon|matic|137) echo "https://polygon.llamarpc.com" ;;
        bnb|bsc|56) echo "https://bsc-dataseed.binance.org" ;;
        *) echo "" ;;
    esac
}

get_token_decimals() {
    local token="$1" chain="$2"
    local lower="${token,,}"
    [[ "$lower" =~ ^(speed|eth|ether|native)$ ]] && echo 18 && return
    [[ "$lower" != 0x* ]] && echo 18 && return

    local rpc
    rpc="$(rpc_for_chain "$chain")"
    [[ -z "$rpc" ]] && { echo 18; return; }

    local body resp hex
    body="{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$token\",\"data\":\"0x313ce567\"},\"latest\"],\"id\":1}"
    resp="$(curl -sf -X POST "$rpc" -H "Content-Type: application/json" -d "$body" 2>/dev/null)" || { echo 18; return; }
    hex="$(echo "$resp" | sed -n 's/.*"result":"\([^"]*\)".*/\1/p' | sed 's/^0x//' | sed 's/^0*//')"
    [[ -z "$hex" ]] && { echo 18; return; }
    printf "%d\n" "0x${hex^^}" 2>/dev/null || echo 18
}

get_quote() {
    local sell_tok="$1" buy_tok="$2" sell_amt="$3"
    local out json
    out="$(speed quote --json -c "$CHAIN" --sell "$sell_tok" --buy "$buy_tok" -a "$sell_amt" 2>&1)" || {
        echo "$out" >&2
        return 1
    }
    json="$(echo "$out" | sed -n '/^{/p' | head -1)"
    [[ -z "$json" ]] && { echo "No JSON from quote: $out" >&2; return 1; }
    if echo "$json" | grep -q '"error"'; then
        echo "Quote error: $json" >&2
        return 1
    fi
    echo "$json"
}

extract_buy_amount() {
    echo "$1" | sed -n 's/.*"buyAmount"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

TOKEN_DECIMALS="$(get_token_decimals "$TOKEN" "$CHAIN")"
BASE_DECIMALS="$(get_token_decimals "$BASE_TOKEN" "$CHAIN")"
TOKEN_SCALE="$(awk -v d="$TOKEN_DECIMALS" 'BEGIN { printf "%.0f", 10^d }')"
BASE_SCALE="$(awk -v d="$BASE_DECIMALS" 'BEGIN { printf "%.0f", 10^d }')"

TOKEN_LABEL="${TOKEN_SYMBOL:-$TOKEN}"
BASE_LABEL="${BASE_TOKEN_SYMBOL:-$BASE_TOKEN}"

echo ""
echo -e "${YELLOW}=== Speed Market Watch (Quotes Only) ===${RESET}"
echo "  Chain         : $CHAIN"
echo "  Target token  : $TOKEN_LABEL (decimals: $TOKEN_DECIMALS)"
echo "  Base token    : $BASE_LABEL (decimals: $BASE_DECIMALS)"
echo "  Reference buy : $AMOUNT $BASE_LABEL"
echo "  Poll interval : $POLL_SECONDS s"
if [[ "$MAX_ITERATIONS" -le 0 ]]; then
    echo "  Max polls     : infinite"
else
    echo "  Max polls     : $MAX_ITERATIONS"
fi
echo ""

echo -e "${CYAN}Step 1 - Building reference position from quote ($BASE_LABEL -> $TOKEN_LABEL)...${RESET}"
buy_json="$(get_quote "$BASE_TOKEN" "$TOKEN" "$AMOUNT")"
token_raw="$(extract_buy_amount "$buy_json")"
[[ -z "$token_raw" ]] && { echo "Failed to parse buyAmount: $buy_json" >&2; exit 1; }
token_human="$(awk -v raw="$token_raw" -v s="$TOKEN_SCALE" -v d="$TOKEN_DECIMALS" 'BEGIN { printf "%.*f", d, raw/s }')"

if ! awk -v v="$token_human" 'BEGIN { exit (v > 0) ? 0 : 1 }'; then
    echo "Reference token amount resolved to 0 (raw=$token_raw, decimals=$TOKEN_DECIMALS)." >&2
    exit 1
fi

echo "  Ref position  : $token_human $TOKEN_LABEL"
echo ""

echo -e "${CYAN}Step 2 - Baseline quote ($TOKEN_LABEL -> $BASE_LABEL)...${RESET}"
baseline_json="$(get_quote "$TOKEN" "$BASE_TOKEN" "$token_human")"
baseline_raw="$(extract_buy_amount "$baseline_json")"
[[ -z "$baseline_raw" ]] && { echo "Failed to parse baseline buyAmount: $baseline_json" >&2; exit 1; }
baseline_val="$(awk -v raw="$baseline_raw" -v s="$BASE_SCALE" 'BEGIN { printf "%.8f", raw/s }')"
high_raw="$baseline_raw"
low_raw="$baseline_raw"
last_raw="$baseline_raw"
echo "  Baseline      : $baseline_val $BASE_LABEL"
echo ""

iteration=0
while [[ "$MAX_ITERATIONS" -le 0 || "$iteration" -lt "$MAX_ITERATIONS" ]]; do
    ((iteration++)) || true
    ts="$(date +"%H:%M:%S")"
    echo -e "${GRAY}[$ts] Poll $iteration - waiting $POLL_SECONDS s...${RESET}"
    sleep "$POLL_SECONDS"

    poll_json="$(get_quote "$TOKEN" "$BASE_TOKEN" "$token_human" 2>&1)" || {
        echo "Warning: quote failed on poll $iteration: $poll_json" >&2
        continue
    }
    current_raw="$(extract_buy_amount "$poll_json")"
    [[ -z "$current_raw" ]] && { echo "Warning: missing buyAmount on poll $iteration"; continue; }
    last_raw="$current_raw"

    if awk -v a="$current_raw" -v b="$high_raw" 'BEGIN { exit (a>b) ? 0 : 1 }'; then high_raw="$current_raw"; fi
    if awk -v a="$current_raw" -v b="$low_raw"  'BEGIN { exit (a<b) ? 0 : 1 }'; then low_raw="$current_raw"; fi

    current_val="$(awk -v raw="$current_raw" -v s="$BASE_SCALE" 'BEGIN { printf "%.8f", raw/s }')"
    high_val="$(awk -v raw="$high_raw" -v s="$BASE_SCALE" 'BEGIN { printf "%.8f", raw/s }')"
    low_val="$(awk -v raw="$low_raw" -v s="$BASE_SCALE" 'BEGIN { printf "%.8f", raw/s }')"
    pct_vs_base="$(awk -v c="$current_raw" -v b="$baseline_raw" 'BEGIN { printf "%.4f", (c-b)/b*100 }')"

    ts2="$(date +"%H:%M:%S")"
    if awk -v p="$pct_vs_base" 'BEGIN { exit (p>=0) ? 0 : 1 }'; then
        echo -e "${GREEN}[$ts2] $current_val $BASE_LABEL  (+$pct_vs_base% vs baseline)  [H $high_val / L $low_val]${RESET}"
    else
        echo -e "${RED}[$ts2] $current_val $BASE_LABEL  ($pct_vs_base% vs baseline)  [H $high_val / L $low_val]${RESET}"
    fi
done

echo ""
if [[ "$MAX_ITERATIONS" -gt 0 ]]; then
    last_val="$(awk -v raw="$last_raw" -v s="$BASE_SCALE" 'BEGIN { printf "%.8f", raw/s }')"
    high_val="$(awk -v raw="$high_raw" -v s="$BASE_SCALE" 'BEGIN { printf "%.8f", raw/s }')"
    low_val="$(awk -v raw="$low_raw" -v s="$BASE_SCALE" 'BEGIN { printf "%.8f", raw/s }')"
    net_pct="$(awk -v l="$last_raw" -v b="$baseline_raw" 'BEGIN { printf "%.4f", (l-b)/b*100 }')"
    range_pct="$(awk -v h="$high_raw" -v l="$low_raw" -v b="$baseline_raw" 'BEGIN { printf "%.4f", (h-l)/b*100 }')"
    off_high_pct="$(awk -v h="$high_raw" -v l="$last_raw" -v b="$baseline_raw" 'BEGIN { printf "%.4f", (h-l)/b*100 }')"

    echo -e "${YELLOW}=== Market Watch Summary ===${RESET}"
    echo "  Polls         : $iteration"
    echo "  Baseline      : $baseline_val $BASE_LABEL"
    if awk -v p="$net_pct" 'BEGIN { exit (p>=0) ? 0 : 1 }'; then
        echo "  Last          : $last_val $BASE_LABEL  (+$net_pct% vs baseline)"
    else
        echo "  Last          : $last_val $BASE_LABEL  ($net_pct% vs baseline)"
    fi
    echo "  High / Low    : $high_val / $low_val $BASE_LABEL"
    echo "  Range         : $range_pct% of baseline"
    echo "  Off high      : -$off_high_pct% from session high"
    echo ""
    echo -e "${YELLOW}Done: reached MaxIterations ($MAX_ITERATIONS).${RESET}"
fi
