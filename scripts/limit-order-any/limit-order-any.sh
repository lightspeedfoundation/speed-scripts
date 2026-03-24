#!/usr/bin/env bash
# limit-order-any.sh
# Buy any token with ETH, then sell when ETH return rises by --targetpct.
#
# Usage:
#   ./limit-order-any.sh --chain base --token speed --amount 0.001 --targetpct 5
#   ./limit-order-any.sh --chain base --token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf --amount 0.002 --targetpct 2.5
#   ./limit-order-any.sh --chain base --token 0x... --tokensymbol PEPE --amount 0.01 --targetpct 10 --pollseconds 30
#
# Steps:
#   1. Auto-detects token decimals via on-chain RPC call (no manual flag needed).
#   2. Quotes ETH -> <Token> to show what you will get.
#   3. Executes the buy (ETH -> <Token>).
#   4. Polls <Token> -> ETH every --pollseconds seconds.
#   5. Fires the sell when ETH return >= original ETH * (1 + targetpct/100).
#   6. Falls back to selling after --maxiterations polls regardless.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_common.sh
source "$SCRIPT_DIR/../_common.sh"


# --- defaults -----------------------------------------------------------------

CHAIN=""
TOKEN=""
AMOUNT=""
TARGET_PCT=""
TOKEN_SYMBOL=""
POLL_SECONDS=60
MAX_ITERATIONS=1440
DRY_RUN=0
BASE_TOKEN="speed"
BASE_TOKEN_SYMBOL=""

# --- arg parsing --------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chain)         CHAIN="$2";         shift 2 ;;
        --token)         TOKEN="$2";         shift 2 ;;
        --amount)        AMOUNT="$2";        shift 2 ;;
        --targetpct)     TARGET_PCT="$2";    shift 2 ;;
        --tokensymbol)   TOKEN_SYMBOL="$2";  shift 2 ;;
        --pollseconds)   POLL_SECONDS="$2";  shift 2 ;;
        --maxiterations) MAX_ITERATIONS="$2";shift 2 ;;
        --dry-run)       DRY_RUN=1;          shift ;;
        --base-token)         BASE_TOKEN="$2";       shift 2 ;;
        --base-token-symbol) BASE_TOKEN_SYMBOL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$CHAIN" || -z "$TOKEN" || -z "$AMOUNT" || -z "$TARGET_PCT" ]]; then
    echo "Usage: $0 --chain <chain> --token <addr|alias> --amount <base> --targetpct <pct> [--tokensymbol <name>] [--pollseconds <s>] [--maxiterations <n>] [--dry-run] [--base-token ...] [--base-token-symbol ...]" >&2
    exit 1
fi

BASE_TOKEN="$(speed_v2_resolve_base_token "$TOKEN" "$BASE_TOKEN")"
BASE_DECIMALS=$(speed_v2_get_token_decimals "$BASE_TOKEN" "$CHAIN")
BASE_SCALE=$(awk "BEGIN { printf \"%.0f\", 10 ^ $BASE_DECIMALS }")
BASE_LABEL="$(speed_v2_base_label "$BASE_TOKEN_SYMBOL" "$BASE_TOKEN")"

# --- colours ------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GRAY='\033[0;90m'
WHITE='\033[0;37m'
RESET='\033[0m'

# --- helpers ------------------------------------------------------------------

to_human_base() {
    awk "BEGIN { printf \"%.8f\", $1 / $BASE_SCALE }"
}

# Format token human amount with its own decimal count, no scientific notation
format_token() {
    local human="$1"
    local decimals="$2"
    awk "BEGIN { printf \"%.*f\", $decimals, $human }"
}

extract_buy_amount() { speed_v2_extract_buy_amount "$1"; }

get_token_decimals() { speed_v2_get_token_decimals "$1" "$2"; }

get_quote() {
    local sell_tok="$1" buy_tok="$2" sell_amt="$3"
    speed_v2_get_quote "$CHAIN" "$sell_tok" "$buy_tok" "$sell_amt"
}

run_sell() {
    local token_amount="$1"
    echo ""
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "${YELLOW}>>> [DRY-RUN] Would execute: speed swap -c $CHAIN --sell $TOKEN --buy ${BASE_TOKEN} -a $token_amount -y${RESET}"
        return 0
    fi
    echo -e "${CYAN}>>> Executing: speed swap -c $CHAIN --sell $TOKEN --buy ${BASE_TOKEN} -a $token_amount -y${RESET}"
    speed swap -c "$CHAIN" --sell "$TOKEN" --buy "$BASE_TOKEN" -a "$token_amount" -y
    exit $?
}

# --- setup --------------------------------------------------------------------

TOKEN_LABEL="${TOKEN_SYMBOL:-$TOKEN}"

echo -e "${GRAY}Detecting token decimals...${RESET}"
TOKEN_DECIMALS=$(get_token_decimals "$TOKEN" "$CHAIN")
TOKEN_SCALE=$(awk "BEGIN { printf \"%.0f\", 10 ^ $TOKEN_DECIMALS }")

echo ""
echo -e "${YELLOW}=== Speed Limit Order ===${RESET}"
echo "  Chain         : $CHAIN"
echo "  Token         : $TOKEN_LABEL  (decimals: $TOKEN_DECIMALS)"
echo "  Base spent    : $AMOUNT $BASE_LABEL"
echo "  Target return : +$TARGET_PCT %"
echo "  Poll interval : $POLL_SECONDS s"
echo "  Max polls     : $MAX_ITERATIONS"
[[ "$DRY_RUN" == "1" ]] && echo "  *** DRY-RUN MODE -- no swaps will execute ***"
echo ""

# --- step 1: quote the buy ----------------------------------------------------

echo -e "${CYAN}Step 1 - Quoting $BASE_LABEL -> $TOKEN_LABEL for $AMOUNT $BASE_LABEL...${RESET}"

buy_json=$(get_quote "$BASE_TOKEN" "$TOKEN" "$AMOUNT")
token_raw=$(extract_buy_amount "$buy_json")

if [[ -z "$token_raw" ]]; then
    echo "Failed to parse buyAmount from: $buy_json" >&2
    exit 1
fi

token_human=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", $token_raw / $TOKEN_SCALE }")
token_str=$(format_token "$token_human" "$TOKEN_DECIMALS")

# guard against zero (wrong decimals)
if awk "BEGIN { exit ($token_str > 0) ? 0 : 1 }"; then
    : # ok
else
    echo "Token amount resolved to 0 (raw=$token_raw, decimals=$TOKEN_DECIMALS). Aborting." >&2
    exit 1
fi

echo "  You will get : $token_str $TOKEN_LABEL for $AMOUNT $BASE_LABEL"
echo ""

# --- step 2: execute the buy --------------------------------------------------

if [[ "$DRY_RUN" == "1" ]]; then
    echo -e "${CYAN}Step 2 - [DRY-RUN] Skipping buy; using Step 1 quote buy amount.${RESET}"
    echo ""
else
    echo -e "${CYAN}Step 2 - Buying $TOKEN_LABEL...${RESET}"
    echo -e "${CYAN}>>> Executing: speed swap -c $CHAIN --sell ${BASE_TOKEN} --buy $TOKEN -a $AMOUNT -y${RESET}"
    speed swap -c "$CHAIN" --sell "$BASE_TOKEN" --buy "$TOKEN" -a "$AMOUNT" -y || {
        echo "Buy swap failed. Aborting." >&2
        exit 1
    }
    echo ""
fi

# --- step 3: baseline sell quote ----------------------------------------------

echo -e "${CYAN}Step 3 - Baseline sell quote ($TOKEN_LABEL -> $BASE_LABEL)...${RESET}"

sell_json=$(get_quote "$TOKEN" "$BASE_TOKEN" "$token_str")
baseline_raw=$(extract_buy_amount "$sell_json")

if [[ -z "$baseline_raw" ]]; then
    echo "Failed to parse baseline buyAmount from: $sell_json" >&2
    exit 1
fi

baseline_eth=$(to_human_base "$baseline_raw")
# targetRaw = Amount * BASE_SCALE * (1 + TargetPct/100) — parity with .ps1
target_raw=$(awk -v a="$AMOUNT" -v s="$BASE_SCALE" -v p="$TARGET_PCT" 'BEGIN { printf "%.0f", a*s*(1+p/100) }')
target_eth=$(awk -v a="$AMOUNT" -v p="$TARGET_PCT" 'BEGIN { printf "%.8f", a*(1+p/100) }')

echo "  Baseline $BASE_LABEL back : $baseline_eth $BASE_LABEL"
echo "  Target $BASE_LABEL back   : $target_eth $BASE_LABEL  (paid $AMOUNT $BASE_LABEL, want +$TARGET_PCT %)"
echo ""

# --- step 4: poll for target --------------------------------------------------

iteration=0

while (( iteration < MAX_ITERATIONS )); do
    (( iteration++ )) || true
    ts=$(date +"%H:%M:%S")
    echo -e "${GRAY}[$ts] Poll $iteration / $MAX_ITERATIONS - waiting $POLL_SECONDS s...${RESET}"
    sleep "$POLL_SECONDS"

    poll_json=$(get_quote "$TOKEN" "$BASE_TOKEN" "$token_str" 2>&1) || {
        echo "Warning: quote failed on poll $iteration - retrying next interval."
        continue
    }

    current_raw=$(extract_buy_amount "$poll_json")
    if [[ -z "$current_raw" ]]; then
        echo "Warning: could not parse buyAmount on poll $iteration - retrying."
        continue
    fi

    eth_back=$(to_human_base "$current_raw")
    ts2=$(date +"%H:%M:%S")
    pct_delta=$(awk "BEGIN { printf \"%.4f\", ($current_raw - $target_raw) / $target_raw * 100 }")

    if awk "BEGIN { exit ($current_raw >= $target_raw) ? 0 : 1 }"; then
        color="$GREEN"; sign="+"
    elif awk "BEGIN { exit ($pct_delta > -1) ? 0 : 1 }"; then
        color="$WHITE"; sign=""
    else
        color="$RED"; sign=""
    fi

    echo -e "${color}[$ts2] $eth_back $BASE_LABEL back  (${sign}${pct_delta} % vs target)${RESET}"

    if awk "BEGIN { exit ($current_raw >= $target_raw) ? 0 : 1 }"; then
        echo ""
        echo -e "${GREEN}Target reached! $eth_back $BASE_LABEL back  (+${pct_delta} % gain)${RESET}"
        run_sell "$token_str"
        [[ "$DRY_RUN" == "1" ]] && exit 0
    fi
done

# --- max iterations hit -------------------------------------------------------

echo ""
echo -e "${YELLOW}Max iterations ($MAX_ITERATIONS) reached. Selling now.${RESET}"
run_sell "$token_str"
[[ "$DRY_RUN" == "1" ]] && exit 0
