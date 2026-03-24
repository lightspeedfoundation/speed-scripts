#!/usr/bin/env bash
# bracket-any.sh
# Bracket (OCO) order: buy any token with ETH, then hold two simultaneous exit
# conditions — a take-profit ceiling and a stop-loss floor. First to trigger wins.
#
# Usage:
#   ./bracket-any.sh --chain base --token speed --amount 0.002 --take-pct 10 --stop-pct 5
#   ./bracket-any.sh --chain base --token 0xcbB7... --tokensymbol cbBTC --amount 0.012 --take-pct 5 --stop-pct 3 --pollseconds 30
#   ./bracket-any.sh --chain base --token speed --amount 0.001 --take-pct 8 --stop-pct 4 --dry-run
#
# Steps:
#   1. Auto-detects token decimals via on-chain RPC call.
#   2. Quotes + buys Amount ETH of token.
#   3. Baseline sell quote anchors both levels:
#        takeTarget = baseline * (1 + takePct/100)
#        stopFloor  = baseline * (1 - stopPct/100)
#   4. Polls every PollSeconds. First level hit fires the sell.
#   5. Falls back to market sell at MaxIterations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_common.sh
source "$SCRIPT_DIR/../_common.sh"


# --- defaults -----------------------------------------------------------------

CHAIN=""
TOKEN=""
AMOUNT=""
TAKE_PCT=""
STOP_PCT=""
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
        --take-pct)      TAKE_PCT="$2";      shift 2 ;;
        --stop-pct)      STOP_PCT="$2";      shift 2 ;;
        --tokensymbol)   TOKEN_SYMBOL="$2";  shift 2 ;;
        --pollseconds)   POLL_SECONDS="$2";  shift 2 ;;
        --maxiterations) MAX_ITERATIONS="$2"; shift 2 ;;
        --dry-run)       DRY_RUN=1;          shift ;;
        --base-token)         BASE_TOKEN="$2";       shift 2 ;;
        --base-token-symbol) BASE_TOKEN_SYMBOL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$CHAIN" || -z "$TOKEN" || -z "$AMOUNT" || -z "$TAKE_PCT" || -z "$STOP_PCT" ]]; then
    echo "Usage: $0 --chain <chain> --token <addr|alias> --amount <eth> --take-pct <pct> --stop-pct <pct> [--tokensymbol <name>] [--pollseconds <s>] [--maxiterations <n>] [--dry-run]" >&2
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
DARKRED='\033[0;31m'
RESET='\033[0m'

# --- helpers ------------------------------------------------------------------


to_human_base() {
    awk "BEGIN { printf \"%.8f\", $1 / $BASE_SCALE }"
}

format_token() {
    awk "BEGIN { printf \"%.*f\", $2, $1 }"
}

extract_buy_amount() { speed_v2_extract_buy_amount "$1"; }

get_token_decimals() { speed_v2_get_token_decimals "$1" "$2"; }

get_quote() {
    local sell_tok="$1" buy_tok="$2" sell_amt="$3"
    speed_v2_get_quote "$CHAIN" "$sell_tok" "$buy_tok" "$sell_amt"
}

awk_gte() { awk "BEGIN { exit ($1 >= $2) ? 0 : 1 }"; }
awk_lte() { awk "BEGIN { exit ($1 <= $2) ? 0 : 1 }"; }
awk_gt()  { awk "BEGIN { exit ($1 > $2)  ? 0 : 1 }"; }

# --- setup --------------------------------------------------------------------

TOKEN_LABEL="${TOKEN_SYMBOL:-$TOKEN}"

echo -e "${GRAY}Detecting token decimals...${RESET}"
TOKEN_DECIMALS=$(get_token_decimals "$TOKEN" "$CHAIN")
TOKEN_SCALE=$(awk "BEGIN { printf \"%.0f\", 10 ^ $TOKEN_DECIMALS }")

echo ""
echo -e "${YELLOW}=== Speed Bracket Order (OCO) ===${RESET}"
[[ "$DRY_RUN" == "1" ]] && echo -e "${YELLOW}  *** DRY-RUN MODE -- no buy or sell will execute ***${RESET}"
echo "  Chain         : $CHAIN"
echo "  Token         : $TOKEN_LABEL  (decimals: $TOKEN_DECIMALS)"
echo "  Base spent    : $AMOUNT $BASE_LABEL"
echo "  Take-profit   : +${TAKE_PCT} % above entry baseline"
echo "  Stop-loss     : -${STOP_PCT} % below entry baseline"
echo "  Poll interval : $POLL_SECONDS s"
echo "  Max polls     : $MAX_ITERATIONS"
echo ""

# --- step 1: quote the buy ----------------------------------------------------

echo -e "${CYAN}Step 1 - Quoting $BASE_LABEL -> $TOKEN_LABEL for $AMOUNT $BASE_LABEL...${RESET}"

buy_json=$(get_quote "$BASE_TOKEN" "$TOKEN" "$AMOUNT")
token_raw=$(extract_buy_amount "$buy_json")
[[ -z "$token_raw" ]] && { echo "Failed to parse buyAmount. Aborting." >&2; exit 1; }

token_human=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", $token_raw / $TOKEN_SCALE }")
token_str=$(format_token "$token_human" "$TOKEN_DECIMALS")
awk_gt "$token_str" "0" || { echo "Token amount resolved to 0. Aborting." >&2; exit 1; }
echo "  You will get : $token_str $TOKEN_LABEL for $AMOUNT $BASE_LABEL"
echo ""

# --- step 2: execute the buy --------------------------------------------------

echo -e "${CYAN}Step 2 - Buying $TOKEN_LABEL...${RESET}"

if [[ "$DRY_RUN" == "1" ]]; then
    echo -e "${YELLOW}  [DRY-RUN] Would execute: speed swap -c $CHAIN --sell ${BASE_TOKEN} --buy $TOKEN -a $AMOUNT -y${RESET}"
else
    echo -e "${CYAN}>>> speed swap -c $CHAIN --sell ${BASE_TOKEN} --buy $TOKEN -a $AMOUNT -y${RESET}"
    speed swap -c "$CHAIN" --sell "$BASE_TOKEN" --buy "$TOKEN" -a "$AMOUNT" -y || {
        echo "Buy swap failed. Aborting." >&2; exit 1
    }
fi
echo ""

# --- step 3: baseline sell quote — anchors both levels ------------------------

echo -e "${CYAN}Step 3 - Baseline sell quote ($TOKEN_LABEL -> $BASE_LABEL)...${RESET}"

sell_json=$(get_quote "$TOKEN" "$BASE_TOKEN" "$token_str")
baseline_raw=$(extract_buy_amount "$sell_json")
[[ -z "$baseline_raw" ]] && { echo "Failed to parse baseline buyAmount. Aborting." >&2; exit 1; }
baseline_eth=$(to_human_base "$baseline_raw")

take_target_raw=$(awk "BEGIN { printf \"%.0f\", $baseline_raw * (1 + $TAKE_PCT / 100) }")
stop_floor_raw=$(awk  "BEGIN { printf \"%.0f\", $baseline_raw * (1 - $STOP_PCT / 100) }")
take_target_eth=$(to_human_base "$take_target_raw")
stop_floor_eth=$(to_human_base  "$stop_floor_raw")

echo "  Baseline $BASE_LABEL back : $baseline_eth $BASE_LABEL"
echo "  Take-profit target: $take_target_eth $BASE_LABEL  (baseline +${TAKE_PCT}%)"
echo "  Stop-loss floor   : $stop_floor_eth $BASE_LABEL  (baseline -${STOP_PCT}%)"
echo ""

# --- step 4: poll for bracket exits -------------------------------------------

echo -e "${CYAN}Step 4 - Monitoring bracket. First level hit wins...${RESET}"
echo ""

iteration=0

while (( iteration < MAX_ITERATIONS )); do
    (( iteration++ )) || true
    ts=$(date +"%H:%M:%S")
    echo -e "${GRAY}[$ts] Poll $iteration / $MAX_ITERATIONS - waiting $POLL_SECONDS s...${RESET}"
    sleep "$POLL_SECONDS"

    poll_json=$(get_quote "$TOKEN" "$BASE_TOKEN" "$token_str" 2>&1) || {
        echo "Warning: quote failed on poll $iteration - retrying."
        continue
    }

    current_raw=$(extract_buy_amount "$poll_json")
    if [[ -z "$current_raw" ]]; then
        echo "Warning: empty buyAmount on poll $iteration - retrying."
        continue
    fi

    current_eth=$(to_human_base "$current_raw")
    ts2=$(date +"%H:%M:%S")

    pct_vs_base=$(awk "BEGIN { printf \"%+.4f\", ($current_raw - $baseline_raw) / $baseline_raw * 100 }")
    # Match bracket-any.ps1: TP = (takeTarget - current) / current; SL cushion = (current - stopFloor) / current
    pct_to_tp=$(awk   "BEGIN { c=$current_raw; if (c <= 0) print 0; else printf \"%+.4f\", ($take_target_raw - c) / c * 100 }")
    pct_to_sl=$(awk   "BEGIN { c=$current_raw; if (c <= 0) print 0; else printf \"%+.4f\", (c - $stop_floor_raw) / c * 100 }")

    tp_zone=$(awk "BEGIN { printf \"%.0f\", ($take_target_raw - $baseline_raw) * 0.25 }")
    sl_zone=$(awk "BEGIN { printf \"%.0f\", ($baseline_raw - $stop_floor_raw) * 0.25 }")

    if awk_gte "$current_raw" "$take_target_raw"; then
        color="$GREEN"
    elif awk_lte "$current_raw" "$stop_floor_raw"; then
        color="$RED"
    elif awk_gte "$current_raw" "$(awk "BEGIN { printf \"%.0f\", $take_target_raw - $tp_zone }")"; then
        color="$YELLOW"
    elif awk_lte "$current_raw" "$(awk "BEGIN { printf \"%.0f\", $stop_floor_raw + $sl_zone }")"; then
        color="$DARKRED"
    else
        color="$WHITE"
    fi

    echo -e "${color}[$ts2] $current_eth $BASE_LABEL  (${pct_vs_base}% vs entry)  TP: ${pct_to_tp}% to target  SL: ${pct_to_sl}% cushion to floor  [take: $take_target_eth $BASE_LABEL  stop: $stop_floor_eth $BASE_LABEL]${RESET}"

    # Take-profit
    if awk_gte "$current_raw" "$take_target_raw"; then
        gain_pct=$(awk "BEGIN { printf \"%.4f\", ($current_eth - $AMOUNT) / $AMOUNT * 100 }")
        echo ""
        echo -e "${GREEN}TAKE-PROFIT triggered! $current_eth $BASE_LABEL back  (+${gain_pct}% gain vs base spent)${RESET}"
        if [[ "$DRY_RUN" == "1" ]]; then
            echo -e "${YELLOW}[DRY-RUN] Would SELL $token_str $TOKEN_LABEL -> $BASE_LABEL now.${RESET}"; exit 0
        fi
        echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy ${BASE_TOKEN} -a $token_str -y${RESET}"
        speed swap -c "$CHAIN" --sell "$TOKEN" --buy "$BASE_TOKEN" -a "$token_str" -y
        exit $?
    fi

    # Stop-loss
    if awk_lte "$current_raw" "$stop_floor_raw"; then
        loss_pct=$(awk "BEGIN { printf \"%.4f\", ($current_eth - $AMOUNT) / $AMOUNT * 100 }")
        echo ""
        echo -e "${RED}STOP-LOSS triggered! $current_eth $BASE_LABEL back  (${loss_pct}% vs base spent)${RESET}"
        if [[ "$DRY_RUN" == "1" ]]; then
            echo -e "${YELLOW}[DRY-RUN] Would SELL $token_str $TOKEN_LABEL -> $BASE_LABEL now.${RESET}"; exit 0
        fi
        echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy ${BASE_TOKEN} -a $token_str -y${RESET}"
        speed swap -c "$CHAIN" --sell "$TOKEN" --buy "$BASE_TOKEN" -a "$token_str" -y
        exit $?
    fi
done

# --- max iterations -----------------------------------------------------------

echo ""
echo -e "${YELLOW}Max iterations ($MAX_ITERATIONS) reached. Selling at market...${RESET}"
if [[ "$DRY_RUN" == "1" ]]; then
    echo -e "${YELLOW}[DRY-RUN] Would SELL $token_str $TOKEN_LABEL -> $BASE_LABEL now.${RESET}"; exit 0
fi
echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy ${BASE_TOKEN} -a $token_str -y${RESET}"
speed swap -c "$CHAIN" --sell "$TOKEN" --buy "$BASE_TOKEN" -a "$token_str" -y
