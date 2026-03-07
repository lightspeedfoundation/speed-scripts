#!/usr/bin/env bash
# momentum-any.sh
# Track a rolling price window and only buy when price breaks above the window
# high by --breakout-pct%. Once in, a trailing stop manages the exit.
# Never spends ETH unless a confirmed breakout occurs.
#
# Usage:
#   ./momentum-any.sh --chain base --token speed --amount 0.002 --window-polls 20 --breakout-pct 1 --trail-pct 5
#   ./momentum-any.sh --chain base --token 0xcbB7... --tokensymbol cbBTC --amount 0.005 --window-polls 10 --breakout-pct 0.5 --trail-pct 3 --pollseconds 30
#   ./momentum-any.sh --chain base --token speed --amount 0.001 --window-polls 20 --dry-run
#
# Steps:
#   1. Auto-detects token decimals via on-chain RPC call.
#   2. Quotes Amount ETH -> Token (reference, no buy yet).
#   3. Warm-up: polls WindowPolls times to build the initial price window.
#   4. Monitoring: each poll updates the rolling window.
#      Breakout: currentPrice >= windowHigh * (1 + breakoutPct/100)
#   5. On breakout: buys Amount ETH of token.
#   6. Post-buy: trailing stop. Sell when ETH return drops TrailPct% from peak.
#   7. MaxIterations without breakout: exits without buying.

set -euo pipefail

# --- defaults -----------------------------------------------------------------

CHAIN=""
TOKEN=""
AMOUNT=""
TOKEN_SYMBOL=""
WINDOW_POLLS=20
BREAKOUT_PCT=0
TRAIL_PCT=5
POLL_SECONDS=60
MAX_ITERATIONS=1440
VOLUME_CONFIRM=0
VOLUME_MULTIPLE=10
MAX_IMPACT_PCT=5
DRY_RUN=0

# --- arg parsing --------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chain)         CHAIN="$2";         shift 2 ;;
        --token)         TOKEN="$2";         shift 2 ;;
        --amount)        AMOUNT="$2";        shift 2 ;;
        --tokensymbol)   TOKEN_SYMBOL="$2";  shift 2 ;;
        --window-polls)  WINDOW_POLLS="$2";  shift 2 ;;
        --breakout-pct)  BREAKOUT_PCT="$2";  shift 2 ;;
        --trail-pct)     TRAIL_PCT="$2";     shift 2 ;;
        --pollseconds)      POLL_SECONDS="$2";      shift 2 ;;
        --maxiterations)    MAX_ITERATIONS="$2";    shift 2 ;;
        --volume-confirm)   VOLUME_CONFIRM=1;        shift ;;
        --volume-multiple)  VOLUME_MULTIPLE="$2";   shift 2 ;;
        --max-impact-pct)   MAX_IMPACT_PCT="$2";    shift 2 ;;
        --dry-run)          DRY_RUN=1;              shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$CHAIN" || -z "$TOKEN" || -z "$AMOUNT" ]]; then
    echo "Usage: $0 --chain <chain> --token <addr|alias> --amount <eth> [--window-polls <n>] [--breakout-pct <pct>] [--trail-pct <pct>] [--tokensymbol <name>] [--pollseconds <s>] [--maxiterations <n>] [--dry-run]" >&2
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

ETH_SCALE=1000000000000000000  # 1e18

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

awk_gte() { awk "BEGIN { exit ($1 >= $2) ? 0 : 1 }"; }
awk_lte() { awk "BEGIN { exit ($1 <= $2) ? 0 : 1 }"; }
awk_gt()  { awk "BEGIN { exit ($1 > $2)  ? 0 : 1 }"; }

# Rolling window: stored as space-separated values in a string
window_add() {
    local val="$1"
    WINDOW_DATA="$WINDOW_DATA $val"
    local count
    count=$(echo "$WINDOW_DATA" | wc -w)
    if (( count > WINDOW_POLLS )); then
        # Drop oldest (first element)
        WINDOW_DATA=$(echo "$WINDOW_DATA" | awk '{for(i=2;i<=NF;i++) printf $i" "; print ""}' | sed 's/ $//')
    fi
}

window_max() {
    echo "$WINDOW_DATA" | tr ' ' '\n' | grep -v '^$' | sort -n | tail -1
}

# --- setup --------------------------------------------------------------------

TOKEN_LABEL="${TOKEN_SYMBOL:-$TOKEN}"
WINDOW_DATA=""
entry_made=0
token_str=""
peak_raw=0
floor_raw=0

echo -e "${GRAY}Detecting token decimals...${RESET}"
TOKEN_DECIMALS=$(get_token_decimals "$TOKEN" "$CHAIN")
TOKEN_SCALE=$(awk "BEGIN { printf \"%.0f\", 10 ^ $TOKEN_DECIMALS }")

echo ""
echo -e "${YELLOW}=== Speed Momentum Buy ===${RESET}"
[[ "$DRY_RUN" == "1" ]] && echo -e "${YELLOW}  *** DRY-RUN MODE -- no buy will execute ***${RESET}"
echo "  Chain          : $CHAIN"
echo "  Token          : $TOKEN_LABEL  (decimals: $TOKEN_DECIMALS)"
echo "  Buy amount     : $AMOUNT ETH  (on breakout)"
echo "  Window polls   : $WINDOW_POLLS  (warm-up + rolling high)"
echo "  Breakout pct   : ${BREAKOUT_PCT}% above window high"
echo "  Trail pct      : ${TRAIL_PCT}% drop from peak triggers sell"
echo "  Poll interval  : $POLL_SECONDS s"
echo "  Max polls      : $MAX_ITERATIONS"
(( VOLUME_CONFIRM == 1 )) && echo "  Volume confirm : ON  (reject breakout if pool impact > ${MAX_IMPACT_PCT}% at ${VOLUME_MULTIPLE}x size)"
echo ""

# --- step 1: reference quote (no buy yet) ------------------------------------

echo -e "${CYAN}Step 1 - Quoting $AMOUNT ETH -> $TOKEN_LABEL (reference, no buy yet)...${RESET}"

ref_buy_json=$(get_quote "eth" "$TOKEN" "$AMOUNT")
ref_token_raw=$(extract_buy_amount "$ref_buy_json")
[[ -z "$ref_token_raw" ]] && { echo "Failed to parse ref buyAmount. Aborting." >&2; exit 1; }

ref_token_human=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", $ref_token_raw / $TOKEN_SCALE }")
ref_token_str=$(format_token "$ref_token_human" "$TOKEN_DECIMALS")
awk_gt "$ref_token_str" "0" || { echo "Reference amount resolved to 0. Aborting." >&2; exit 1; }
echo "  Reference amount : $ref_token_str $TOKEN_LABEL for $AMOUNT ETH"

# --- step 2: initial price ---------------------------------------------------

echo ""
echo -e "${CYAN}Step 2 - Getting initial price...${RESET}"

init_sell_json=$(get_quote "$TOKEN" "eth" "$ref_token_str")
init_raw=$(extract_buy_amount "$init_sell_json")
[[ -z "$init_raw" ]] && { echo "Failed to parse init price. Aborting." >&2; exit 1; }
init_eth=$(to_human_eth "$init_raw")
echo "  Initial price : $init_eth ETH  (for $ref_token_str $TOKEN_LABEL)"
echo ""

window_add "$init_raw"

# --- step 3: warm-up ---------------------------------------------------------

echo -e "${CYAN}Step 3 - Warm-up: collecting $WINDOW_POLLS polls to build price window...${RESET}"

warmup_needed=$(( WINDOW_POLLS - 1 ))
warmup_done=0

while (( warmup_done < warmup_needed )); do
    (( warmup_done++ )) || true
    ts=$(date +"%H:%M:%S")
    echo -e "${GRAY}[$ts] Warm-up $warmup_done/$warmup_needed - waiting $POLL_SECONDS s...${RESET}"
    sleep "$POLL_SECONDS"

    poll_json=$(get_quote "$TOKEN" "eth" "$ref_token_str" 2>&1) || {
        echo "Warning: warm-up poll $warmup_done failed - using last known value."
        window_add "$init_raw"
        continue
    }

    w_raw=$(extract_buy_amount "$poll_json")
    if [[ -z "$w_raw" ]]; then
        echo "Warning: empty buyAmount on warm-up $warmup_done - retrying."
        window_add "$init_raw"
        continue
    fi

    w_eth=$(to_human_eth "$w_raw")
    w_high=$(window_max)
    w_high_eth=$(to_human_eth "$w_high")
    w_pct=$(awk "BEGIN { printf \"%+.2f\", ($w_raw - $w_high) / $w_high * 100 }")
    w_count=$(echo "$WINDOW_DATA" | wc -w)
    ts2=$(date +"%H:%M:%S")
    echo -e "${GRAY}[$ts2] Price: $w_eth ETH  window high: $w_high_eth  ($w_pct% vs high)  [$w_count samples]${RESET}"
    window_add "$w_raw"
done

window_high_raw=$(window_max)
window_high_eth=$(to_human_eth "$window_high_raw")
echo ""
echo -e "${CYAN}Warm-up complete. Window high: $window_high_eth ETH  ($WINDOW_POLLS polls)${RESET}"
if awk_gt "$BREAKOUT_PCT" "0"; then
    breakout_thresh_eth=$(awk "BEGIN { printf \"%.8f\", $window_high_raw * (1 + $BREAKOUT_PCT / 100) / $ETH_SCALE }")
    echo -e "${CYAN}Breakout threshold: $breakout_thresh_eth ETH  (window high + ${BREAKOUT_PCT}%)${RESET}"
fi
echo ""

# --- step 4: monitoring + breakout detection ---------------------------------

echo -e "${CYAN}Step 4 - Monitoring for breakout...${RESET}"
echo ""

iteration=0

while (( iteration < MAX_ITERATIONS )); do
    (( iteration++ )) || true
    ts=$(date +"%H:%M:%S")
    echo -e "${GRAY}[$ts] Poll $iteration / $MAX_ITERATIONS - waiting $POLL_SECONDS s...${RESET}"
    sleep "$POLL_SECONDS"

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

    # Update rolling window
    window_add "$current_raw"
    window_high_raw=$(window_max)
    window_high_eth=$(to_human_eth "$window_high_raw")

    # ── post-entry: trailing stop ─────────────────────────────────────────────
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

        echo -e "${color}[$ts2] POST-ENTRY — $t_eth ETH  peak: $peak_eth  floor: $floor_eth  (${pct_from_peak}% from peak)${RESET}"

        if awk_lte "$t_raw" "$floor_raw"; then
            gain_pct=$(awk "BEGIN { printf \"%.4f\", ($t_eth - $AMOUNT) / $AMOUNT * 100 }")
            echo ""
            echo -e "${RED}Trail floor breached! $t_eth ETH back  (${gain_pct}% vs entry cost)${RESET}"
            if [[ "$DRY_RUN" == "1" ]]; then
                echo -e "${YELLOW}[DRY-RUN] Would SELL $token_str $TOKEN_LABEL -> ETH${RESET}"
                exit 0
            fi
            echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy eth -a $token_str -y${RESET}"
            speed swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$token_str" -y
            exit $?
        fi
        continue
    fi

    # ── pre-entry: watch for breakout ─────────────────────────────────────────
    breakout_thresh=$(awk "BEGIN { printf \"%.0f\", $window_high_raw * (1 + $BREAKOUT_PCT / 100) }")
    pct_vs_high=$(awk "BEGIN { printf \"%+.4f\", ($current_raw - $window_high_raw) / $window_high_raw * 100 }")
    pct_vs_thresh=$(awk "BEGIN { printf \"%+.4f\", ($current_raw - $breakout_thresh) / $breakout_thresh * 100 }")

    if awk_gte "$current_raw" "$window_high_raw"; then
        color="$YELLOW"
    elif awk "BEGIN { exit (($window_high_raw - $current_raw) / $window_high_raw < 0.02) ? 0 : 1 }"; then
        color="$WHITE"
    else
        color="$GRAY"
    fi

    echo -e "${color}[$ts2] Price: $current_eth ETH  win-high: $window_high_eth  (${pct_vs_high}%)  thresh: ${pct_vs_thresh}% away${RESET}"

    if awk_gte "$current_raw" "$breakout_thresh"; then
        breakout_thresh_eth=$(to_human_eth "$breakout_thresh")
        echo ""
        echo -e "${GREEN}BREAKOUT detected! Price $current_eth ETH >= threshold $breakout_thresh_eth ETH  (+${pct_vs_high}% vs window high)${RESET}"

        # ── Volume confirmation check ──────────────────────────────────────────
        skip_entry=0
        if (( VOLUME_CONFIRM == 1 )); then
            large_amount=$(awk "BEGIN { printf \"%.8f\", $AMOUNT * $VOLUME_MULTIPLE }")
            small_q_json=$(get_quote "eth" "$TOKEN" "$AMOUNT" 2>&1) || { echo "Warning: volume small quote failed -- skipping check."; }
            large_q_json=$(get_quote "eth" "$TOKEN" "$large_amount" 2>&1) || { echo "Warning: volume large quote failed -- skipping check."; }
            if [[ -n "$small_q_json" && -n "$large_q_json" ]]; then
                small_ba=$(extract_buy_amount "$small_q_json")
                large_ba=$(extract_buy_amount "$large_q_json")
                if [[ -n "$small_ba" && -n "$large_ba" ]]; then
                    impact_pct=$(awk "BEGIN {
                        small_ppu = $small_ba / $AMOUNT
                        large_ppu = $large_ba / $large_amount
                        if (large_ppu > 0) printf \"%.2f\", (small_ppu / large_ppu - 1) * 100
                        else print \"0\"
                    }")
                    if awk "BEGIN { exit ($impact_pct > $MAX_IMPACT_PCT) ? 0 : 1 }"; then
                        echo -e "${YELLOW}  [VOLUME] Pool impact: ${impact_pct}% at ${VOLUME_MULTIPLE}x size > ${MAX_IMPACT_PCT}%. Breakout rejected (thin pool). Watching for next signal.${RESET}"
                        skip_entry=1
                    else
                        echo -e "${GREEN}  [VOLUME] Pool impact: ${impact_pct}% at ${VOLUME_MULTIPLE}x size (max: ${MAX_IMPACT_PCT}%). Liquidity OK. Entering.${RESET}"
                    fi
                fi
            fi
        fi

        if (( skip_entry == 1 )); then
            continue
        fi

        if [[ "$DRY_RUN" == "1" ]]; then
            echo -e "${YELLOW}  [DRY-RUN] Would BUY $AMOUNT ETH of $TOKEN_LABEL now. Continuing to observe...${RESET}"
        else
            echo ""
            echo -e "${GREEN}Executing breakout buy: $AMOUNT ETH -> $TOKEN_LABEL${RESET}"
            echo -e "${CYAN}>>> speed swap -c $CHAIN --sell eth --buy $TOKEN -a $AMOUNT -y${RESET}"
            speed swap -c "$CHAIN" --sell eth --buy "$TOKEN" -a "$AMOUNT" -y || {
                echo "Breakout buy failed. Aborting." >&2; exit 1
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
            echo -e "${GRAY}  Entry price   : $entry_eth ETH  (for $token_str $TOKEN_LABEL)${RESET}"
            echo -e "${GRAY}  Trail peak    : $peak_eth ETH${RESET}"
            echo -e "${GRAY}  Trail floor   : $floor_eth ETH  (-${TRAIL_PCT}%)${RESET}"
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
    echo -e "${YELLOW}Max iterations ($MAX_ITERATIONS) reached. No breakout detected. Exiting without a trade.${RESET}"
fi
