#!/usr/bin/env bash
# hybrid-exit-any.sh
# Hybrid exit: buy immediately, sell ExitFraction% at a fixed TakePct% target,
# then trail the remainder with a TrailPct% stop. Hard stop always active.
#
# Usage:
#   ./hybrid-exit-any.sh --chain base --token speed --amount 0.002 --take-pct 10 --exit-fraction 50 --trail-pct 5 --stop-pct 10
#   ./hybrid-exit-any.sh --chain base --token speed --amount 0.002 --take-pct 15 --trail-pct 8
#   ./hybrid-exit-any.sh --chain base --token 0xcbB7... --tokensymbol cbBTC --amount 0.012 --take-pct 5 --exit-fraction 60 --trail-pct 3 --stop-pct 7
#   ./hybrid-exit-any.sh --chain base --token speed --amount 0.001 --take-pct 10 --dry-run
#
# Steps:
#   1. Auto-detects token decimals via on-chain RPC call.
#   2. Quotes Amount ETH -> Token, executes the buy.
#   3. Gets baseline sell quote to anchor all exit levels.
#   4. Phase A: polls until price >= baseline * (1 + take-pct/100) OR hard stop fires.
#   5. Phase B: sells exit-fraction% at market (partial exit, locks profit).
#   6. Phase C: trails the remaining (100-exit-fraction)% with trail-pct% stop.
#      Hard stop remains active on remainder throughout Phase C.

set -euo pipefail

# --- defaults -----------------------------------------------------------------

CHAIN=""
TOKEN=""
AMOUNT=""
TAKE_PCT=""
EXIT_FRACTION=50
TRAIL_PCT=5
STOP_PCT=10
TOKEN_SYMBOL=""
POLL_SECONDS=60
MAX_ITERATIONS=1440
DRY_RUN=0

# --- arg parsing --------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chain)          CHAIN="$2";          shift 2 ;;
        --token)          TOKEN="$2";          shift 2 ;;
        --amount)         AMOUNT="$2";         shift 2 ;;
        --take-pct)       TAKE_PCT="$2";       shift 2 ;;
        --exit-fraction)  EXIT_FRACTION="$2";  shift 2 ;;
        --trail-pct)      TRAIL_PCT="$2";      shift 2 ;;
        --stop-pct)       STOP_PCT="$2";       shift 2 ;;
        --tokensymbol)    TOKEN_SYMBOL="$2";   shift 2 ;;
        --pollseconds)    POLL_SECONDS="$2";   shift 2 ;;
        --maxiterations)  MAX_ITERATIONS="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=1;           shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$CHAIN" || -z "$TOKEN" || -z "$AMOUNT" || -z "$TAKE_PCT" ]]; then
    echo "Usage: $0 --chain <chain> --token <addr|alias> --amount <eth> --take-pct <pct> [--exit-fraction <pct>] [--trail-pct <pct>] [--stop-pct <pct>] [--tokensymbol <name>] [--pollseconds <s>] [--maxiterations <n>] [--dry-run]" >&2
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
phase_b_done=0
peak_raw=0
floor_raw=0

echo -e "${GRAY}Detecting token decimals...${RESET}"
TOKEN_DECIMALS=$(get_token_decimals "$TOKEN" "$CHAIN")
TOKEN_SCALE=$(awk "BEGIN { printf \"%.0f\", 10 ^ $TOKEN_DECIMALS }")

REMAINDER_PCT=$(awk "BEGIN { printf \"%.0f\", 100 - $EXIT_FRACTION }")

echo ""
echo -e "${YELLOW}=== Speed Hybrid Exit ===${RESET}"
[[ "$DRY_RUN" == "1" ]] && echo -e "${YELLOW}  *** DRY-RUN MODE -- no swaps will execute ***${RESET}"
echo "  Chain          : $CHAIN"
echo "  Token          : $TOKEN_LABEL  (decimals: $TOKEN_DECIMALS)"
echo "  Buy amount     : $AMOUNT ETH"
echo "  Take target    : +${TAKE_PCT}% above baseline  -> sell ${EXIT_FRACTION}% of position"
echo "  Trail stop     : ${TRAIL_PCT}% drop from peak  -> sell remainder (${REMAINDER_PCT}%)"
echo "  Hard stop      : ${STOP_PCT}% below baseline   -> sell FULL position (both phases)"
echo "  Poll interval  : $POLL_SECONDS s"
echo "  Max polls      : $MAX_ITERATIONS"
echo ""

# --- step 1: buy --------------------------------------------------------------

echo -e "${CYAN}Step 1 - Quoting $AMOUNT ETH -> $TOKEN_LABEL...${RESET}"

buy_preview_json=$(get_quote "eth" "$TOKEN" "$AMOUNT")
est_token_raw=$(extract_buy_amount "$buy_preview_json")
[[ -z "$est_token_raw" ]] && { echo "Failed to parse buy preview. Aborting." >&2; exit 1; }
est_token_str=$(awk "BEGIN { printf \"%.*f\", $TOKEN_DECIMALS, $est_token_raw / $TOKEN_SCALE }")
echo "  Estimated receive : $est_token_str $TOKEN_LABEL"

if [[ "$DRY_RUN" != "1" ]]; then
    echo ""
    echo -e "${GREEN}Executing buy: $AMOUNT ETH -> $TOKEN_LABEL${RESET}"
    echo -e "${CYAN}>>> speed swap -c $CHAIN --sell eth --buy $TOKEN -a $AMOUNT -y${RESET}"
    speed swap -c "$CHAIN" --sell eth --buy "$TOKEN" -a "$AMOUNT" -y || {
        echo "Buy failed. Aborting." >&2; exit 1
    }
    echo ""
fi

# --- step 2: baseline quote ---------------------------------------------------

echo -e "${CYAN}Step 2 - Getting baseline sell quote to anchor exit levels...${RESET}"

ref_token_raw=$(extract_buy_amount "$buy_preview_json")
ref_token_str=$(awk "BEGIN { printf \"%.*f\", $TOKEN_DECIMALS, $ref_token_raw / $TOKEN_SCALE }")
awk_gt "$ref_token_str" "0" || { echo "Reference amount resolved to 0. Aborting." >&2; exit 1; }

baseline_json=$(get_quote "$TOKEN" "eth" "$ref_token_str")
baseline_raw=$(extract_buy_amount "$baseline_json")
[[ -z "$baseline_raw" ]] && { echo "Failed to parse baseline quote. Aborting." >&2; exit 1; }
baseline_eth=$(to_human_eth "$baseline_raw")

take_target_raw=$(awk "BEGIN { printf \"%.0f\", $baseline_raw * (1 + $TAKE_PCT / 100) }")
stop_thresh_raw=$(awk "BEGIN { printf \"%.0f\", $baseline_raw * (1 - $STOP_PCT / 100) }")
take_target_eth=$(to_human_eth "$take_target_raw")
stop_thresh_eth=$(to_human_eth "$stop_thresh_raw")

partial_token_str=$(awk "BEGIN { printf \"%.*f\", $TOKEN_DECIMALS, $ref_token_str * $EXIT_FRACTION / 100 }")
remainder_token_str=$(awk "BEGIN { printf \"%.*f\", $TOKEN_DECIMALS, $ref_token_str * (100 - $EXIT_FRACTION) / 100 }")

echo -e "${GRAY}  Baseline         : $baseline_eth ETH  (for $ref_token_str $TOKEN_LABEL)${RESET}"
echo -e "${GRAY}  Take target      : $take_target_eth ETH  (+${TAKE_PCT}%)  -> sell $partial_token_str $TOKEN_LABEL (${EXIT_FRACTION}%)${RESET}"
echo -e "${GRAY}  Remainder        : $remainder_token_str $TOKEN_LABEL (${REMAINDER_PCT}%) -> trailed at -${TRAIL_PCT}%${RESET}"
echo -e "${GRAY}  Hard stop        : $stop_thresh_eth ETH  (-${STOP_PCT}%)${RESET}"
echo ""

# --- step 3: Phase A + Phase C loop ------------------------------------------

echo -e "${CYAN}Step 3 - Phase A: watching for take target (+${TAKE_PCT}%)...${RESET}"
echo ""

iteration=0

while (( iteration < MAX_ITERATIONS )); do
    (( iteration++ )) || true
    ts=$(date +"%H:%M:%S")
    echo -e "${GRAY}[$ts] Poll $iteration / $MAX_ITERATIONS - waiting $POLL_SECONDS s...${RESET}"
    sleep "$POLL_SECONDS"

    q_json=$(get_quote "$TOKEN" "eth" "$ref_token_str" 2>&1) || {
        echo "Warning: quote failed on poll $iteration - retrying."
        continue
    }
    current_raw=$(extract_buy_amount "$q_json")
    [[ -z "$current_raw" ]] && { echo "Warning: empty buyAmount on poll $iteration - retrying."; continue; }
    current_eth=$(to_human_eth "$current_raw")
    ts2=$(date +"%H:%M:%S")

    # ── Phase C: trailing stop on remainder ────────────────────────────────────
    if [[ "$phase_b_done" == "1" ]]; then
        rq_json=$(get_quote "$TOKEN" "eth" "$remainder_token_str" 2>&1) || { echo "Warning: remainder quote failed - retrying."; continue; }
        r_raw=$(extract_buy_amount "$rq_json")
        [[ -z "$r_raw" ]] && { echo "Warning: empty remainder buyAmount - retrying."; continue; }
        r_eth=$(to_human_eth "$r_raw")

        # Hard stop on remainder
        stop_remain_raw=$(awk "BEGIN { printf \"%.0f\", $stop_thresh_raw * (100 - $EXIT_FRACTION) / 100 }")
        if awk_lte "$r_raw" "$stop_remain_raw"; then
            echo ""
            echo -e "${RED}HARD STOP on remainder! $r_eth ETH back${RESET}"
            if [[ "$DRY_RUN" == "1" ]]; then echo -e "${YELLOW}[DRY-RUN] Would SELL $remainder_token_str $TOKEN_LABEL -> ETH${RESET}"; exit 0; fi
            echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy eth -a $remainder_token_str -y${RESET}"
            speed swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$remainder_token_str" -y
            exit $?
        fi

        if awk_gt "$r_raw" "$peak_raw"; then
            peak_raw="$r_raw"
            floor_raw=$(awk "BEGIN { printf \"%.0f\", $peak_raw * (1 - $TRAIL_PCT / 100) }")
        fi

        peak_eth=$(to_human_eth "$peak_raw")
        floor_eth=$(to_human_eth "$floor_raw")
        pct_from_peak=$(awk "BEGIN { printf \"%.4f\", ($r_raw - $peak_raw) / $peak_raw * 100 }")
        trail_dist=$(awk "BEGIN { printf \"%.0f\", $peak_raw - $floor_raw }")
        dist_to_floor=$(awk "BEGIN { printf \"%.0f\", $r_raw - $floor_raw }")

        if awk_gte "$r_raw" "$peak_raw"; then
            color="$GREEN"
        elif awk "BEGIN { exit ($trail_dist > 0 && $dist_to_floor / $trail_dist < 0.25) ? 0 : 1 }"; then
            color="$RED"
        else
            color="$WHITE"
        fi

        echo -e "${color}[$ts2] PHASE-C  remainder: $r_eth ETH  peak: $peak_eth  floor: $floor_eth  (${pct_from_peak}% from peak)${RESET}"

        if awk_lte "$r_raw" "$floor_raw"; then
            echo ""
            echo -e "${RED}Trail floor breached! Remainder: $r_eth ETH back${RESET}"
            if [[ "$DRY_RUN" == "1" ]]; then echo -e "${YELLOW}[DRY-RUN] Would SELL $remainder_token_str $TOKEN_LABEL -> ETH${RESET}"; exit 0; fi
            echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy eth -a $remainder_token_str -y${RESET}"
            speed swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$remainder_token_str" -y
            exit $?
        fi
        continue
    fi

    # ── Phase A: hard stop on full position ────────────────────────────────────
    if awk_lte "$current_raw" "$stop_thresh_raw"; then
        loss_pct=$(awk "BEGIN { printf \"%.4f\", ($current_eth - $AMOUNT) / $AMOUNT * 100 }")
        echo ""
        echo -e "${RED}HARD STOP triggered! $current_eth ETH back  (${loss_pct}% vs entry cost)${RESET}"
        if [[ "$DRY_RUN" == "1" ]]; then echo -e "${YELLOW}[DRY-RUN] Would SELL full $ref_token_str $TOKEN_LABEL -> ETH${RESET}"; exit 0; fi
        echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy eth -a $ref_token_str -y${RESET}"
        speed swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$ref_token_str" -y
        exit $?
    fi

    # ── Phase A: display and take-profit check ─────────────────────────────────
    pct_vs_baseline=$(awk "BEGIN { printf \"%+.4f\", ($current_raw - $baseline_raw) / $baseline_raw * 100 }")
    pct_to_take=$(awk "BEGIN { printf \"%+.4f\", $TAKE_PCT - ${pct_vs_baseline#+} }")

    if awk_gte "$current_raw" "$take_target_raw"; then
        color="$GREEN"
    elif awk "BEGIN { exit (${pct_vs_baseline#+} >= $TAKE_PCT * 0.5) ? 0 : 1 }" 2>/dev/null; then
        color="$YELLOW"
    elif awk "BEGIN { exit (${pct_vs_baseline#+} >= 0) ? 0 : 1 }" 2>/dev/null; then
        color="$WHITE"
    else
        color="$GRAY"
    fi

    echo -e "${color}[$ts2] PHASE-A  price: $current_eth ETH  baseline: $baseline_eth  (${pct_vs_baseline}% vs baseline)  take: +${TAKE_PCT}%  (${pct_to_take}% away)${RESET}"

    if awk_gte "$current_raw" "$take_target_raw"; then
        echo ""
        echo -e "${GREEN}Take target reached! $current_eth ETH  (${pct_vs_baseline}% vs baseline)${RESET}"
        echo -e "${GREEN}Selling ${EXIT_FRACTION}% of position ($partial_token_str $TOKEN_LABEL)...${RESET}"

        if [[ "$DRY_RUN" == "1" ]]; then
            echo -e "${YELLOW}  [DRY-RUN] Would SELL $partial_token_str $TOKEN_LABEL -> ETH${RESET}"
            echo -e "${YELLOW}  [DRY-RUN] Would trail remaining $remainder_token_str $TOKEN_LABEL with -${TRAIL_PCT}% stop${RESET}"
        else
            echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy eth -a $partial_token_str -y${RESET}"
            speed swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$partial_token_str" -y || {
                echo "Partial sell failed. Aborting." >&2; exit 1
            }
        fi

        echo ""
        echo -e "${CYAN}Phase B complete. Trailing $remainder_token_str $TOKEN_LABEL (${REMAINDER_PCT}%) with -${TRAIL_PCT}% stop...${RESET}"

        rq_json=$(get_quote "$TOKEN" "eth" "$remainder_token_str" 2>&1) || { echo "Remainder quote failed. Aborting." >&2; exit 1; }
        peak_raw=$(extract_buy_amount "$rq_json")
        floor_raw=$(awk "BEGIN { printf \"%.0f\", $peak_raw * (1 - $TRAIL_PCT / 100) }")
        peak_eth=$(to_human_eth "$peak_raw")
        floor_eth=$(to_human_eth "$floor_raw")
        echo -e "${GRAY}  Trail peak  : $peak_eth ETH${RESET}"
        echo -e "${GRAY}  Trail floor : $floor_eth ETH  (-${TRAIL_PCT}%)${RESET}"
        echo ""

        phase_b_done=1
    fi
done

# --- max iterations -----------------------------------------------------------

echo ""
if [[ "$phase_b_done" == "1" ]]; then
    echo -e "${YELLOW}Max iterations ($MAX_ITERATIONS) reached. Selling remainder...${RESET}"
    if [[ "$DRY_RUN" == "1" ]]; then echo -e "${YELLOW}[DRY-RUN] Would SELL $remainder_token_str $TOKEN_LABEL -> ETH${RESET}"; exit 0; fi
    echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy eth -a $remainder_token_str -y${RESET}"
    speed swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$remainder_token_str" -y
else
    echo -e "${YELLOW}Max iterations ($MAX_ITERATIONS) reached. Selling full position...${RESET}"
    if [[ "$DRY_RUN" == "1" ]]; then echo -e "${YELLOW}[DRY-RUN] Would SELL $ref_token_str $TOKEN_LABEL -> ETH${RESET}"; exit 0; fi
    echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy eth -a $ref_token_str -y${RESET}"
    speed swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$ref_token_str" -y
fi
