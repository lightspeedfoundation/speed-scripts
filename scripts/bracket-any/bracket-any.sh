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
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$CHAIN" || -z "$TOKEN" || -z "$AMOUNT" || -z "$TAKE_PCT" || -z "$STOP_PCT" ]]; then
    echo "Usage: $0 --chain <chain> --token <addr|alias> --amount <eth> --take-pct <pct> --stop-pct <pct> [--tokensymbol <name>] [--pollseconds <s>] [--maxiterations <n>] [--dry-run]" >&2
    exit 1
fi

# --- colours ------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GRAY='\033[0;90m'
WHITE='\033[0;37m'
DARKRED='\033[0;31m'
RESET='\033[0m'

# --- RPC endpoints ------------------------------------------------------------

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

ETH_SCALE=1000000000000000000

to_human_eth() {
    awk "BEGIN { printf \"%.8f\", $1 / $ETH_SCALE }"
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
        echo "Warning: RPC call failed, assuming 18 decimals." >&2; echo 18; return
    }

    local result_field hex
    result_field=$(echo "$resp" | grep -oP '"result"\s*:\s*"\K[^"]+' 2>/dev/null || echo "")
    if [[ -z "$result_field" || "$result_field" == "0x" ]]; then
        echo "Warning: empty decimals result, assuming 18." >&2; echo 18; return
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
echo "  ETH spent     : $AMOUNT ETH"
echo "  Take-profit   : +${TAKE_PCT}% above entry baseline"
echo "  Stop-loss     : -${STOP_PCT}% below entry baseline"
echo "  Poll interval : $POLL_SECONDS s"
echo "  Max polls     : $MAX_ITERATIONS"
echo ""

# --- step 1: quote the buy ----------------------------------------------------

echo -e "${CYAN}Step 1 - Quoting ETH -> $TOKEN_LABEL for $AMOUNT ETH...${RESET}"

buy_json=$(get_quote "eth" "$TOKEN" "$AMOUNT")
token_raw=$(extract_buy_amount "$buy_json")
[[ -z "$token_raw" ]] && { echo "Failed to parse buyAmount. Aborting." >&2; exit 1; }

token_human=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", $token_raw / $TOKEN_SCALE }")
token_str=$(format_token "$token_human" "$TOKEN_DECIMALS")
awk_gt "$token_str" "0" || { echo "Token amount resolved to 0. Aborting." >&2; exit 1; }
echo "  You will get : $token_str $TOKEN_LABEL for $AMOUNT ETH"
echo ""

# --- step 2: execute the buy --------------------------------------------------

echo -e "${CYAN}Step 2 - Buying $TOKEN_LABEL...${RESET}"

if [[ "$DRY_RUN" == "1" ]]; then
    echo -e "${YELLOW}  [DRY-RUN] Would execute: speed swap -c $CHAIN --sell eth --buy $TOKEN -a $AMOUNT -y${RESET}"
else
    echo -e "${CYAN}>>> speed swap -c $CHAIN --sell eth --buy $TOKEN -a $AMOUNT -y${RESET}"
    speed swap -c "$CHAIN" --sell eth --buy "$TOKEN" -a "$AMOUNT" -y || {
        echo "Buy swap failed. Aborting." >&2; exit 1
    }
fi
echo ""

# --- step 3: baseline sell quote — anchors both levels ------------------------

echo -e "${CYAN}Step 3 - Baseline sell quote ($TOKEN_LABEL -> ETH)...${RESET}"

sell_json=$(get_quote "$TOKEN" "eth" "$token_str")
baseline_raw=$(extract_buy_amount "$sell_json")
[[ -z "$baseline_raw" ]] && { echo "Failed to parse baseline buyAmount. Aborting." >&2; exit 1; }
baseline_eth=$(to_human_eth "$baseline_raw")

take_target_raw=$(awk "BEGIN { printf \"%.0f\", $baseline_raw * (1 + $TAKE_PCT / 100) }")
stop_floor_raw=$(awk  "BEGIN { printf \"%.0f\", $baseline_raw * (1 - $STOP_PCT / 100) }")
take_target_eth=$(to_human_eth "$take_target_raw")
stop_floor_eth=$(to_human_eth  "$stop_floor_raw")

echo "  Baseline ETH back : $baseline_eth ETH"
echo "  Take-profit target: $take_target_eth ETH  (baseline +${TAKE_PCT}%)"
echo "  Stop-loss floor   : $stop_floor_eth ETH  (baseline -${STOP_PCT}%)"
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

    poll_json=$(get_quote "$TOKEN" "eth" "$token_str" 2>&1) || {
        echo "Warning: quote failed on poll $iteration - retrying."
        continue
    }

    current_raw=$(extract_buy_amount "$poll_json")
    if [[ -z "$current_raw" ]]; then
        echo "Warning: empty buyAmount on poll $iteration - retrying."
        continue
    fi

    current_eth=$(to_human_eth "$current_raw")
    ts2=$(date +"%H:%M:%S")

    pct_vs_base=$(awk "BEGIN { printf \"%+.4f\", ($current_raw - $baseline_raw) / $baseline_raw * 100 }")
    pct_to_tp=$(awk   "BEGIN { printf \"%+.4f\", ($current_raw - $take_target_raw) / $take_target_raw * 100 }")
    pct_to_sl=$(awk   "BEGIN { printf \"%+.4f\", ($current_raw - $stop_floor_raw)  / $stop_floor_raw  * 100 }")

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

    echo -e "${color}[$ts2] $current_eth ETH  (${pct_vs_base}% vs entry)  TP: ${pct_to_tp}% away  SL: ${pct_to_sl}% away  [take: $take_target_eth  stop: $stop_floor_eth]${RESET}"

    # Take-profit
    if awk_gte "$current_raw" "$take_target_raw"; then
        gain_pct=$(awk "BEGIN { printf \"%.4f\", ($current_eth - $AMOUNT) / $AMOUNT * 100 }")
        echo ""
        echo -e "${GREEN}TAKE-PROFIT triggered! $current_eth ETH back  (+${gain_pct}% gain vs ETH spent)${RESET}"
        if [[ "$DRY_RUN" == "1" ]]; then
            echo -e "${YELLOW}[DRY-RUN] Would SELL $token_str $TOKEN_LABEL -> ETH now.${RESET}"; exit 0
        fi
        echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy eth -a $token_str -y${RESET}"
        speed swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$token_str" -y
        exit $?
    fi

    # Stop-loss
    if awk_lte "$current_raw" "$stop_floor_raw"; then
        loss_pct=$(awk "BEGIN { printf \"%.4f\", ($current_eth - $AMOUNT) / $AMOUNT * 100 }")
        echo ""
        echo -e "${RED}STOP-LOSS triggered! $current_eth ETH back  (${loss_pct}% vs ETH spent)${RESET}"
        if [[ "$DRY_RUN" == "1" ]]; then
            echo -e "${YELLOW}[DRY-RUN] Would SELL $token_str $TOKEN_LABEL -> ETH now.${RESET}"; exit 0
        fi
        echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy eth -a $token_str -y${RESET}"
        speed swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$token_str" -y
        exit $?
    fi
done

# --- max iterations -----------------------------------------------------------

echo ""
echo -e "${YELLOW}Max iterations ($MAX_ITERATIONS) reached. Selling at market...${RESET}"
if [[ "$DRY_RUN" == "1" ]]; then
    echo -e "${YELLOW}[DRY-RUN] Would SELL $token_str $TOKEN_LABEL -> ETH now.${RESET}"; exit 0
fi
echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy eth -a $token_str -y${RESET}"
speed swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$token_str" -y
