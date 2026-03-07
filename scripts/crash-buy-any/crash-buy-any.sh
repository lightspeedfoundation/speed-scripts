#!/usr/bin/env bash
# crash-buy-any.sh
# Crash buy: monitor price velocity and buy immediately when price drops
# --crash-pct% relative to a rolling baseline. Rides the bounce via trailing stop.
#
# Usage:
#   ./crash-buy-any.sh --chain base --token speed --amount 0.002 --crash-pct 5 --trail-pct 5
#   ./crash-buy-any.sh --chain base --token speed --amount 0.002 --crash-pct 5 --trail-pct 5 --baseline-polls 3
#   ./crash-buy-any.sh --chain base --token 0xcbB7... --tokensymbol cbBTC --amount 0.012 --crash-pct 3 --trail-pct 3 --pollseconds 30 --baseline-polls 4
#   ./crash-buy-any.sh --chain base --token speed --amount 0.001 --crash-pct 5 --dry-run
#
# Steps:
#   1. Auto-detects token decimals via on-chain RPC call.
#   2. Quotes Amount ETH -> Token (reference, no buy yet).
#   3. Gets initial price quote to seed the baseline window.
#   4. Detection loop: computes baseline = mean of last --baseline-polls prices.
#      dropPct = (baseline - currentRaw) / baseline * 100.
#      If dropPct >= crashPct: CRASH -> buy immediately.
#      --baseline-polls 1 (default) = single-poll comparison (backward-compatible).
#      --baseline-polls 3-5 = rolling mean; resists single-tick whale false positives.
#   5. Post-buy: trailing stop (same as trailing-stop-any.sh).

set -euo pipefail

# --- defaults -----------------------------------------------------------------

CHAIN=""
TOKEN=""
AMOUNT=""
CRASH_PCT=""
TRAIL_PCT=5
BASELINE_POLLS=1
TOKEN_SYMBOL=""
POLL_SECONDS=30
MAX_ITERATIONS=2880
TIME_STOP_MINUTES=0
DRY_RUN=0

# --- arg parsing --------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chain)           CHAIN="$2";           shift 2 ;;
        --token)           TOKEN="$2";           shift 2 ;;
        --amount)          AMOUNT="$2";          shift 2 ;;
        --crash-pct)       CRASH_PCT="$2";       shift 2 ;;
        --trail-pct)       TRAIL_PCT="$2";       shift 2 ;;
        --baseline-polls)  BASELINE_POLLS="$2";  shift 2 ;;
        --tokensymbol)     TOKEN_SYMBOL="$2";    shift 2 ;;
        --pollseconds)        POLL_SECONDS="$2";        shift 2 ;;
        --maxiterations)      MAX_ITERATIONS="$2";      shift 2 ;;
        --time-stop-minutes)  TIME_STOP_MINUTES="$2";   shift 2 ;;
        --dry-run)            DRY_RUN=1;                shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$CHAIN" || -z "$TOKEN" || -z "$AMOUNT" || -z "$CRASH_PCT" ]]; then
    echo "Usage: $0 --chain <chain> --token <addr|alias> --amount <eth> --crash-pct <pct> [--trail-pct <pct>] [--baseline-polls <n>] [--tokensymbol <name>] [--pollseconds <s>] [--maxiterations <n>] [--dry-run]" >&2
    exit 1
fi
if (( BASELINE_POLLS < 1 )); then
    echo "--baseline-polls must be >= 1" >&2; exit 1
fi

# --- colours ------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GRAY='\033[0;90m'
WHITE='\033[0;37m'
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
        echo "Warning: unknown chain '$chain', assuming 18 decimals." >&2; echo 18; return
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
entry_made=0
token_str=""
peak_raw=0
floor_raw=0

# Rolling baseline window stored as a space-delimited string
price_window=""
window_count=0

echo -e "${GRAY}Detecting token decimals...${RESET}"
TOKEN_DECIMALS=$(get_token_decimals "$TOKEN" "$CHAIN")
TOKEN_SCALE=$(awk "BEGIN { printf \"%.0f\", 10 ^ $TOKEN_DECIMALS }")

echo ""
if (( BASELINE_POLLS == 1 )); then
    baseline_label="single-poll (prev tick)"
else
    baseline_label="${BASELINE_POLLS}-poll rolling mean"
fi

echo -e "${YELLOW}=== Speed Crash Buy ===${RESET}"
[[ "$DRY_RUN" == "1" ]] && echo -e "${YELLOW}  *** DRY-RUN MODE -- crash signals logged, no buy will execute ***${RESET}"
echo "  Chain          : $CHAIN"
echo "  Token          : $TOKEN_LABEL  (decimals: $TOKEN_DECIMALS)"
echo "  Buy amount     : $AMOUNT ETH  (on crash)"
echo "  Crash trigger  : ${CRASH_PCT}% drop vs $baseline_label"
echo "  Baseline polls : $BASELINE_POLLS  (window warm-up: $BASELINE_POLLS polls)"
echo "  Trail pct      : ${TRAIL_PCT}% drop from peak triggers sell"
echo "  Poll interval  : $POLL_SECONDS s"
echo "  Max polls      : $MAX_ITERATIONS"
(( TIME_STOP_MINUTES > 0 )) && echo "  Time stop      : ${TIME_STOP_MINUTES} min  (exits at thesis timeout regardless of price)"
echo ""

# --- step 1: reference quote --------------------------------------------------

echo -e "${CYAN}Step 1 - Quoting $AMOUNT ETH -> $TOKEN_LABEL (reference, no buy yet)...${RESET}"

ref_buy_json=$(get_quote "eth" "$TOKEN" "$AMOUNT")
ref_token_raw=$(extract_buy_amount "$ref_buy_json")
[[ -z "$ref_token_raw" ]] && { echo "Failed to parse ref buyAmount. Aborting." >&2; exit 1; }

ref_token_human=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", $ref_token_raw / $TOKEN_SCALE }")
ref_token_str=$(awk "BEGIN { printf \"%.*f\", $TOKEN_DECIMALS, $ref_token_human }")
awk_gt "$ref_token_str" "0" || { echo "Reference amount resolved to 0. Aborting." >&2; exit 1; }
echo "  Reference amount : $ref_token_str $TOKEN_LABEL for $AMOUNT ETH"

# --- step 2: initial price ----------------------------------------------------

echo ""
echo -e "${CYAN}Step 2 - Getting initial price...${RESET}"

init_sell_json=$(get_quote "$TOKEN" "eth" "$ref_token_str")
init_raw=$(extract_buy_amount "$init_sell_json")
[[ -z "$init_raw" ]] && { echo "Failed to parse initial price. Aborting." >&2; exit 1; }
init_eth=$(to_human_eth "$init_raw")
echo "  Initial price : $init_eth ETH  (for $ref_token_str $TOKEN_LABEL)"
echo ""

# Seed baseline window with initial price
price_window="$init_raw"
window_count=1

# --- step 3: crash detection + post-entry trailing stop -----------------------

echo -e "${CYAN}Step 3 - Monitoring for crash...${RESET}"
echo ""

iteration=0
start_epoch=$(date +%s)

while (( iteration < MAX_ITERATIONS )); do
    (( iteration++ )) || true
    ts=$(date +"%H:%M:%S")
    echo -e "${GRAY}[$ts] Poll $iteration / $MAX_ITERATIONS - waiting $POLL_SECONDS s...${RESET}"
    sleep "$POLL_SECONDS"

    # Time stop check
    if (( TIME_STOP_MINUTES > 0 )); then
        now_epoch=$(date +%s)
        elapsed_min=$(( (now_epoch - start_epoch) / 60 ))
        if (( elapsed_min >= TIME_STOP_MINUTES )); then
            echo ""
            if [[ "$entry_made" == "1" ]]; then
                echo -e "${YELLOW}Time stop reached (${elapsed_min}m elapsed). Selling open position.${RESET}"
                echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy eth -a $token_str -y${RESET}"
                speed swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$token_str" -y
                exit $?
            else
                echo -e "${YELLOW}Time stop reached (${elapsed_min}m elapsed). Thesis did not play out. Exiting without a trade.${RESET}"
                exit 0
            fi
        fi
    fi

    poll_json=$(get_quote "$TOKEN" "eth" "$ref_token_str" 2>&1) || {
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

    # ── post-entry: trailing stop ──────────────────────────────────────────────
    if [[ "$entry_made" == "1" ]]; then
        tq_json=$(get_quote "$TOKEN" "eth" "$token_str" 2>&1) || { echo "Warning: trail quote failed - retrying."; continue; }
        t_raw=$(extract_buy_amount "$tq_json")
        [[ -z "$t_raw" ]] && { echo "Warning: empty trail buyAmount - retrying."; continue; }
        t_eth=$(to_human_eth "$t_raw")

        if awk_gt "$t_raw" "$peak_raw"; then
            peak_raw="$t_raw"
            floor_raw=$(awk "BEGIN { printf \"%.0f\", $peak_raw * (1 - $TRAIL_PCT / 100) }")
        fi

        peak_eth=$(to_human_eth "$peak_raw")
        floor_eth=$(to_human_eth "$floor_raw")
        pct_from_peak=$(awk "BEGIN { printf \"%.4f\", ($t_raw - $peak_raw) / $peak_raw * 100 }")

        trail_dist=$(awk "BEGIN { printf \"%.0f\", $peak_raw - $floor_raw }")
        dist_to_floor=$(awk "BEGIN { printf \"%.0f\", $t_raw - $floor_raw }")

        if awk_gte "$t_raw" "$peak_raw"; then
            color="$GREEN"
        elif awk "BEGIN { exit ($trail_dist > 0 && $dist_to_floor / $trail_dist < 0.25) ? 0 : 1 }"; then
            color="$RED"
        else
            color="$WHITE"
        fi

        echo -e "${color}[$ts2] POST-ENTRY  $t_eth ETH  peak: $peak_eth  floor: $floor_eth  (${pct_from_peak}% from peak)${RESET}"

        if awk_lte "$t_raw" "$floor_raw"; then
            gain_pct=$(awk "BEGIN { printf \"%.4f\", ($t_eth - $AMOUNT) / $AMOUNT * 100 }")
            echo ""
            echo -e "${RED}Trail floor breached! $t_eth ETH back  (${gain_pct}% vs entry cost)${RESET}"
            if [[ "$DRY_RUN" == "1" ]]; then
                echo -e "${YELLOW}[DRY-RUN] Would SELL $token_str $TOKEN_LABEL -> ETH${RESET}"; exit 0
            fi
            echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy eth -a $token_str -y${RESET}"
            speed swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$token_str" -y
            exit $?
        fi
        continue
    fi

    # ── pre-entry: velocity crash detection ────────────────────────────────────
    # Slide window: append current_raw, drop oldest if over BASELINE_POLLS
    price_window="$price_window $current_raw"
    window_count=$(( window_count + 1 ))
    if (( window_count > BASELINE_POLLS + 1 )); then
        price_window="${price_window# }"        # strip leading space
        price_window="${price_window#* }"       # drop first element
        window_count=$(( window_count - 1 ))
    fi

    # Require window to have >= BASELINE_POLLS historical entries before detecting
    if (( window_count <= BASELINE_POLLS )); then
        echo -e "${GRAY}[$ts2] Warming up baseline window... ($(( window_count - 1 ))/$BASELINE_POLLS polls)${RESET}"
        continue
    fi

    # Baseline = mean of all window entries except the last (current)
    baseline_values="${price_window% *}"    # all but last element
    baseline_raw=$(awk "BEGIN {
        n=split(\"$baseline_values\", a, \" \"); s=0; for(i=1;i<=n;i++) s+=a[i]; printf \"%.0f\", s/n
    }")
    baseline_eth=$(to_human_eth "$baseline_raw")

    drop_pct=$(awk "BEGIN { printf \"%+.4f\", ($baseline_raw > 0) ? ($baseline_raw - $current_raw) / $baseline_raw * 100 : 0 }")
    pct_to_trig=$(awk "BEGIN { printf \"%+.4f\", $CRASH_PCT - ${drop_pct#+} }")

    if awk "BEGIN { exit (${drop_pct#+} >= $CRASH_PCT) ? 0 : 1 }" 2>/dev/null; then
        color="$GREEN"
    elif awk "BEGIN { exit (${drop_pct#+} >= $CRASH_PCT * 0.5) ? 0 : 1 }" 2>/dev/null; then
        color="$YELLOW"
    elif awk "BEGIN { exit (${drop_pct#+} >= 0) ? 0 : 1 }" 2>/dev/null; then
        color="$WHITE"
    else
        color="$GRAY"
    fi

    echo -e "${color}[$ts2] Price: $current_eth ETH  baseline: $baseline_eth  drop: ${drop_pct}%  trigger: ${CRASH_PCT}%  (${pct_to_trig}% away)${RESET}"

    # Crash entry condition
    if awk "BEGIN { exit (${drop_pct#+} >= $CRASH_PCT) ? 0 : 1 }" 2>/dev/null; then
        echo ""
        echo -e "${GREEN}CRASH detected! Price dropped ${drop_pct}% vs ${BASELINE_POLLS}-poll baseline  ($baseline_eth ETH -> $current_eth ETH)${RESET}"

        if [[ "$DRY_RUN" == "1" ]]; then
            echo -e "${YELLOW}  [DRY-RUN] Would BUY $AMOUNT ETH of $TOKEN_LABEL now. Continuing to observe...${RESET}"
        else
            echo ""
            echo -e "${GREEN}Executing crash buy: $AMOUNT ETH -> $TOKEN_LABEL${RESET}"
            echo -e "${CYAN}>>> speed swap -c $CHAIN --sell eth --buy $TOKEN -a $AMOUNT -y${RESET}"
            speed swap -c "$CHAIN" --sell eth --buy "$TOKEN" -a "$AMOUNT" -y || {
                echo "Crash buy failed. Aborting." >&2; exit 1
            }
            echo ""

            echo -e "${CYAN}Getting post-buy quote to anchor trailing stop...${RESET}"
            post_buy_json=$(get_quote "$TOKEN" "eth" "$ref_token_str" 2>&1) || { echo "Post-buy quote failed. Aborting." >&2; exit 1; }
            post_buy_raw=$(extract_buy_amount "$post_buy_json")
            [[ -z "$post_buy_raw" ]] && { echo "Empty post-buy raw. Aborting." >&2; exit 1; }

            token_str="$ref_token_str"
            peak_raw="$post_buy_raw"
            floor_raw=$(awk "BEGIN { printf \"%.0f\", $peak_raw * (1 - $TRAIL_PCT / 100) }")
            entry_made=1

            entry_eth=$(to_human_eth "$post_buy_raw")
            peak_eth=$(to_human_eth "$peak_raw")
            floor_eth=$(to_human_eth "$floor_raw")
            echo -e "${GRAY}  Entry price  : $entry_eth ETH  (for $token_str $TOKEN_LABEL)${RESET}"
            echo -e "${GRAY}  Trail peak   : $peak_eth ETH${RESET}"
            echo -e "${GRAY}  Trail floor  : $floor_eth ETH  (-${TRAIL_PCT}%)${RESET}"
            echo ""
        fi
    fi

done

# --- max iterations -----------------------------------------------------------

echo ""
if [[ "$entry_made" == "1" ]]; then
    echo -e "${YELLOW}Max iterations ($MAX_ITERATIONS) reached. Selling position...${RESET}"
    echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy eth -a $token_str -y${RESET}"
    speed swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$token_str" -y
else
    echo -e "${YELLOW}Max iterations ($MAX_ITERATIONS) reached. No crash detected. Exiting without a trade.${RESET}"
fi
