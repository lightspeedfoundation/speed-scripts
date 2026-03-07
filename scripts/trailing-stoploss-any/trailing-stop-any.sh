#!/usr/bin/env bash
# trailing-stop-any.sh
# Buy any token with ETH, then sell when ETH return drops --trailpct% below the
# running peak. The floor trails the peak upward and never moves back down.
#
# Usage:
#   ./trailing-stop-any.sh --chain base --token speed --amount 0.001 --trailpct 5
#   ./trailing-stop-any.sh --chain base --token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf --tokensymbol cbBTC --amount 0.002 --trailpct 3
#   ./trailing-stop-any.sh --chain base --token 0x... --tokensymbol PEPE --amount 0.01 --trailpct 10 --pollseconds 30
#
# Steps:
#   1. Auto-detects token decimals via on-chain RPC call.
#   2. Quotes ETH -> <Token> to show what you will get.
#   3. Executes the buy (ETH -> <Token>).
#   4. Gets baseline sell quote to establish initial peak and floor.
#   5. Polls <Token> -> ETH every --pollseconds seconds.
#      - New high? Peak and floor rise. Printed in green.
#      - Below floor? Sells immediately.
#   6. Falls back to selling after --maxiterations polls regardless.

set -euo pipefail

# --- defaults -----------------------------------------------------------------

CHAIN=""
TOKEN=""
AMOUNT=""
TRAIL_PCT=""
TOKEN_SYMBOL=""
POLL_SECONDS=60
MAX_ITERATIONS=1440

# --- arg parsing --------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chain)         CHAIN="$2";          shift 2 ;;
        --token)         TOKEN="$2";          shift 2 ;;
        --amount)        AMOUNT="$2";         shift 2 ;;
        --trailpct)      TRAIL_PCT="$2";      shift 2 ;;
        --tokensymbol)   TOKEN_SYMBOL="$2";   shift 2 ;;
        --pollseconds)   POLL_SECONDS="$2";   shift 2 ;;
        --maxiterations) MAX_ITERATIONS="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$CHAIN" || -z "$TOKEN" || -z "$AMOUNT" || -z "$TRAIL_PCT" ]]; then
    echo "Usage: $0 --chain <chain> --token <addr|alias> --amount <eth> --trailpct <pct> [--tokensymbol <name>] [--pollseconds <s>] [--maxiterations <n>]" >&2
    exit 1
fi

# --- colours ------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GRAY='\033[0;90m'
WHITE='\033[0;37m'
RESET='\033[0m'

# --- RPC endpoints (mirrors CLI constants) ------------------------------------

get_rpc_url() {
    local chain="${1,,}"
    case "$chain" in
        base|8453)          echo "https://mainnet.base.org" ;;
        mainnet|ethereum|1) echo "https://eth.llamarpc.com" ;;
        optimism|op|10)     echo "https://mainnet.optimism.io" ;;
        arbitrum|arb|42161) echo "https://arb1.arbitrum.io/rpc" ;;
        polygon|matic|137)  echo "https://polygon.llamarpc.com" ;;
        bnb|bsc|56)         echo "https://bsc-dataseed.binance.org" ;;
        *) echo "" ;;
    esac
}

# --- helpers ------------------------------------------------------------------

ETH_DECIMALS=1000000000000000000   # 1e18

to_human_eth() {
    awk "BEGIN { printf \"%.8f\", $1 / $ETH_DECIMALS }"
}

to_raw_eth() {
    awk "BEGIN { printf \"%.0f\", $1 * $ETH_DECIMALS }"
}

format_token() {
    awk "BEGIN { printf \"%.*f\", $2, $1 }"
}

extract_buy_amount() {
    local json="$1"
    echo "$json" | grep -oP '"buyAmount"\s*:\s*"\K[^"]+' 2>/dev/null || \
    echo "$json" | grep -oP '"buyAmount"\s*:\s*\K[0-9]+' 2>/dev/null || \
    echo ""
}

get_token_decimals() {
    local token_addr="$1" chain="$2"
    local lower="${token_addr,,}"

    [[ "$lower" =~ ^(speed|eth|ether|native)$ ]] && echo 18 && return
    [[ "$lower" != 0x* ]] && echo 18 && return

    local rpc
    rpc=$(get_rpc_url "$chain")
    if [[ -z "$rpc" ]]; then
        echo "Warning: unknown chain '$chain', assuming 18 decimals." >&2
        echo 18; return
    fi

    local body="{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$token_addr\",\"data\":\"0x313ce567\"},\"latest\"],\"id\":1}"
    local resp
    resp=$(curl -sf -X POST "$rpc" -H "Content-Type: application/json" -d "$body" 2>/dev/null) || {
        echo "Warning: RPC call failed, assuming 18 decimals." >&2
        echo 18; return
    }

    local result_field hex
    result_field=$(echo "$resp" | grep -oP '"result"\s*:\s*"\K[^"]+' 2>/dev/null || echo "")
    if [[ -z "$result_field" || "$result_field" == "0x" ]]; then
        echo "Warning: empty decimals result, assuming 18." >&2
        echo 18; return
    fi

    hex="${result_field#0x}"
    hex=$(echo "$hex" | sed 's/^0*//')
    [[ -z "$hex" ]] && hex="0"
    echo "obase=10; ibase=16; ${hex^^}" | bc 2>/dev/null || echo 18
}

get_quote() {
    local sell_tok="$1" buy_tok="$2" sell_amt="$3"
    local output json
    output=$(speed quote --json -c "$CHAIN" --sell "$sell_tok" --buy "$buy_tok" -a "$sell_amt" 2>&1)
    json=$(echo "$output" | grep -m1 '^{' || echo "")
    if [[ -z "$json" ]]; then
        echo "No JSON from quote. Output: $output" >&2; return 1
    fi
    if echo "$json" | grep -q '"error"'; then
        local err
        err=$(echo "$json" | grep -oP '"error"\s*:\s*"\K[^"]+' || echo "$json")
        echo "Quote error: $err" >&2; return 1
    fi
    echo "$json"
}

run_sell() {
    local token_amount="$1"
    echo ""
    echo -e "${CYAN}>>> Executing: speed swap -c $CHAIN --sell $TOKEN --buy eth -a $token_amount -y${RESET}"
    speed swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$token_amount" -y
    exit $?
}

# --- setup --------------------------------------------------------------------

TOKEN_LABEL="${TOKEN_SYMBOL:-$TOKEN}"

echo -e "${GRAY}Detecting token decimals...${RESET}"
TOKEN_DECIMALS=$(get_token_decimals "$TOKEN" "$CHAIN")
TOKEN_SCALE=$(awk "BEGIN { printf \"%.0f\", 10 ^ $TOKEN_DECIMALS }")

echo ""
echo -e "${YELLOW}=== Speed Trailing Stop-Loss ===${RESET}"
echo "  Chain         : $CHAIN"
echo "  Token         : $TOKEN_LABEL  (decimals: $TOKEN_DECIMALS)"
echo "  ETH spent     : $AMOUNT ETH"
echo "  Trail %       : $TRAIL_PCT % drop from peak triggers sell"
echo "  Poll interval : $POLL_SECONDS s"
echo "  Max polls     : $MAX_ITERATIONS"
echo ""

# --- step 1: quote the buy ----------------------------------------------------

echo -e "${CYAN}Step 1 - Quoting ETH -> $TOKEN_LABEL for $AMOUNT ETH...${RESET}"

buy_json=$(get_quote "eth" "$TOKEN" "$AMOUNT")
token_raw=$(extract_buy_amount "$buy_json")

if [[ -z "$token_raw" ]]; then
    echo "Failed to parse buyAmount from: $buy_json" >&2; exit 1
fi

token_human=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", $token_raw / $TOKEN_SCALE }")
token_str=$(format_token "$token_human" "$TOKEN_DECIMALS")

if awk "BEGIN { exit ($token_str > 0) ? 0 : 1 }"; then
    : # ok
else
    echo "Token amount resolved to 0 (raw=$token_raw, decimals=$TOKEN_DECIMALS). Aborting." >&2; exit 1
fi

echo "  You will get : $token_str $TOKEN_LABEL for $AMOUNT ETH"
echo ""

# --- step 2: execute the buy --------------------------------------------------

echo -e "${CYAN}Step 2 - Buying $TOKEN_LABEL...${RESET}"
echo -e "${CYAN}>>> Executing: speed swap -c $CHAIN --sell eth --buy $TOKEN -a $AMOUNT -y${RESET}"
speed swap -c "$CHAIN" --sell eth --buy "$TOKEN" -a "$AMOUNT" -y || {
    echo "Buy swap failed. Aborting." >&2; exit 1
}
echo ""

# --- step 3: baseline sell quote — sets initial peak -------------------------

echo -e "${CYAN}Step 3 - Baseline sell quote ($TOKEN_LABEL -> ETH) — setting initial peak...${RESET}"

sell_json=$(get_quote "$TOKEN" "eth" "$token_str")
baseline_raw=$(extract_buy_amount "$sell_json")

if [[ -z "$baseline_raw" ]]; then
    echo "Failed to parse baseline buyAmount from: $sell_json" >&2; exit 1
fi

baseline_eth=$(to_human_eth "$baseline_raw")

# Peak starts at baseline; floor = peak * (1 - trailpct/100)
peak_raw="$baseline_raw"
floor_raw=$(awk "BEGIN { printf \"%.0f\", $peak_raw * (1 - $TRAIL_PCT / 100) }")
peak_eth=$(to_human_eth "$peak_raw")
floor_eth=$(to_human_eth "$floor_raw")

echo "  Baseline ETH back : $baseline_eth ETH"
echo "  Initial peak      : $peak_eth ETH"
echo "  Initial floor     : $floor_eth ETH  (peak - $TRAIL_PCT %)"
echo ""

# --- step 4: poll with trailing floor -----------------------------------------

iteration=0

while (( iteration < MAX_ITERATIONS )); do
    (( iteration++ )) || true
    ts=$(date +"%H:%M:%S")
    echo -e "${GRAY}[$ts] Poll $iteration / $MAX_ITERATIONS - waiting $POLL_SECONDS s...${RESET}"
    sleep "$POLL_SECONDS"

    poll_json=$(get_quote "$TOKEN" "eth" "$token_str" 2>&1) || {
        echo "Warning: quote failed on poll $iteration - retrying next interval."
        continue
    }

    current_raw=$(extract_buy_amount "$poll_json")
    if [[ -z "$current_raw" ]]; then
        echo "Warning: could not parse buyAmount on poll $iteration - retrying."
        continue
    fi

    eth_back=$(to_human_eth "$current_raw")
    ts2=$(date +"%H:%M:%S")

    # Update peak if new high
    if awk "BEGIN { exit ($current_raw > $peak_raw) ? 0 : 1 }"; then
        peak_raw="$current_raw"
        floor_raw=$(awk "BEGIN { printf \"%.0f\", $peak_raw * (1 - $TRAIL_PCT / 100) }")
        peak_eth=$(to_human_eth "$peak_raw")
        floor_eth=$(to_human_eth "$floor_raw")
    fi

    pct_from_peak=$(awk "BEGIN { printf \"%.4f\", ($current_raw - $peak_raw) / $peak_raw * 100 }")

    # Color: green = at/above peak, red = within 25% of trail distance to floor, white = ok
    trail_dist=$(awk "BEGIN { printf \"%.0f\", $peak_raw - $floor_raw }")
    dist_to_floor=$(awk "BEGIN { printf \"%.0f\", $current_raw - $floor_raw }")

    if awk "BEGIN { exit ($current_raw >= $peak_raw) ? 0 : 1 }"; then
        color="$GREEN"
    elif awk "BEGIN { exit ($trail_dist > 0 && $dist_to_floor / $trail_dist < 0.25) ? 0 : 1 }"; then
        color="$RED"
    else
        color="$WHITE"
    fi

    echo -e "${color}[$ts2] $eth_back ETH back  peak: $peak_eth  floor: $floor_eth  (${pct_from_peak} % from peak)${RESET}"

    # Trigger: current dropped to or below floor
    if awk "BEGIN { exit ($current_raw <= $floor_raw) ? 0 : 1 }"; then
        gain_pct=$(awk "BEGIN { printf \"%.4f\", ($current_raw - $baseline_raw) / $baseline_raw * 100 }")
        echo ""
        echo -e "${RED}Floor breached! $eth_back ETH back  ($gain_pct % vs baseline)${RESET}"
        run_sell "$token_str"
    fi
done

# --- max iterations hit -------------------------------------------------------

echo ""
echo -e "${YELLOW}Max iterations ($MAX_ITERATIONS) reached. Selling now.${RESET}"
run_sell "$token_str"
