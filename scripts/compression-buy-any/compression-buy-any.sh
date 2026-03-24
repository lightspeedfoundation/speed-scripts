#!/usr/bin/env bash
# compression-buy-any.sh
# Wait for price to consolidate into a tight range (compression), then buy when
# price breaks out of that range (expansion). Trails the exit.
#
# Usage:
#   ./compression-buy-any.sh --chain base --token speed --amount 0.002 --window-polls 20 --compression-pct 3 --expansion-pct 1 --trail-pct 5
#   ./compression-buy-any.sh --chain base --token speed --amount 0.002 --compression-pct 2 --expansion-pct 0.5 --trail-pct 4
#   ./compression-buy-any.sh --chain base --token 0xcbB7... --tokensymbol cbBTC --amount 0.012 --window-polls 15 --compression-pct 2 --expansion-pct 0.5 --trail-pct 3 --pollseconds 30
#   ./compression-buy-any.sh --chain base --token speed --amount 0.002 --compression-pct 3 --arm-timeout 10 --dry-run
#
# Steps:
#   1. Auto-detects token decimals.
#   2. Quotes Amount ETH -> Token (reference, no buy yet).
#   3. Warm-up: builds rolling window of WindowPolls prices.
#   4. Monitoring: each poll computes rollingRange = (high-low)/mean*100.
#      ARMED when rollingRange <= CompressionPct.
#      FIRES when armed AND currentPrice >= windowHigh * (1 + ExpansionPct/100).
#   5. Executes buy on expansion breakout.
#   6. Post-buy: trailing stop identical to momentum-any.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_common.sh
source "$SCRIPT_DIR/../_common.sh"


# --- defaults -----------------------------------------------------------------

CHAIN=""
TOKEN=""
AMOUNT=""
TOKEN_SYMBOL=""
WINDOW_POLLS=20
COMPRESSION_PCT=3
EXPANSION_PCT=1
TRAIL_PCT=5
ARM_TIMEOUT=0
POLL_SECONDS=60
MAX_ITERATIONS=1440
DRY_RUN=0
BASE_TOKEN="speed"
BASE_TOKEN_SYMBOL=""

# --- arg parsing --------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chain)           CHAIN="$2";           shift 2 ;;
        --token)           TOKEN="$2";           shift 2 ;;
        --amount)          AMOUNT="$2";          shift 2 ;;
        --tokensymbol)     TOKEN_SYMBOL="$2";    shift 2 ;;
        --window-polls)    WINDOW_POLLS="$2";    shift 2 ;;
        --compression-pct) COMPRESSION_PCT="$2"; shift 2 ;;
        --expansion-pct)   EXPANSION_PCT="$2";   shift 2 ;;
        --trail-pct)       TRAIL_PCT="$2";       shift 2 ;;
        --arm-timeout)     ARM_TIMEOUT="$2";     shift 2 ;;
        --pollseconds)     POLL_SECONDS="$2";    shift 2 ;;
        --maxiterations)   MAX_ITERATIONS="$2";  shift 2 ;;
        --dry-run)         DRY_RUN=1;            shift ;;
        --base-token)         BASE_TOKEN="$2";       shift 2 ;;
        --base-token-symbol) BASE_TOKEN_SYMBOL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$CHAIN" || -z "$TOKEN" || -z "$AMOUNT" ]]; then
    echo "Usage: $0 --chain <chain> --token <addr|alias> --amount <eth> [--window-polls <n>] [--compression-pct <pct>] [--expansion-pct <pct>] [--trail-pct <pct>] [--arm-timeout <n>] [--tokensymbol <name>] [--pollseconds <s>] [--maxiterations <n>] [--dry-run]" >&2
    exit 1
fi

BASE_TOKEN="$(speed_v2_resolve_base_token "$TOKEN" "$BASE_TOKEN")"
BASE_DECIMALS=$(speed_v2_get_token_decimals "$BASE_TOKEN" "$CHAIN")
BASE_SCALE=$(awk "BEGIN { printf \"%.0f\", 10 ^ $BASE_DECIMALS }")
BASE_LABEL="$(speed_v2_base_label "$BASE_TOKEN_SYMBOL" "$BASE_TOKEN")"

if awk -v e="$EXPANSION_PCT" 'BEGIN { exit (e < 0) ? 0 : 1 }'; then
    echo "-ExpansionPct must be >= 0." >&2
    exit 1
fi
if awk -v e="$EXPANSION_PCT" 'BEGIN { exit (e == 0) ? 0 : 1 }'; then
    echo "Warning: -ExpansionPct 0: any price at or above window high while armed triggers entry." >&2
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

# Rolling window: raw wei (for max / expansion) + human base (range/mean; awk cannot sum wei-sized ints)
WINDOW_RAW=""
WINDOW_HUMAN=""

window_max_raw() {
    echo "$WINDOW_RAW" | tr ' ' '\n' | grep -v '^$' | sort -n | tail -1
}

window_add() {
    local val="$1"
    local h
    h=$(to_human_base "$val")
    if [[ -z "$WINDOW_RAW" ]]; then
        WINDOW_RAW="$val"
        WINDOW_HUMAN="$h"
    else
        WINDOW_RAW="$WINDOW_RAW $val"
        WINDOW_HUMAN="$WINDOW_HUMAN $h"
    fi
    local count
    count=$(echo "$WINDOW_RAW" | wc -w)
    if (( count > WINDOW_POLLS )); then
        WINDOW_RAW=$(echo "$WINDOW_RAW" | awk '{for(i=2;i<=NF;i++) printf $i" "; print ""}' | sed 's/ $//')
        WINDOW_HUMAN=$(echo "$WINDOW_HUMAN" | awk '{for(i=2;i<=NF;i++) printf $i" "; print ""}' | sed 's/ $//')
    fi
}

window_stats() {
    echo "$WINDOW_HUMAN" | tr ' ' '\n' | grep -v '^$' | \
        awk 'BEGIN{max=-1e308;min=1e308;sum=0;n=0}
             {v=$1+0; if(v>max)max=v; if(v<min)min=v; sum+=v; n++}
             END{if(n>0) printf "%.10f %.10f %.10f", max, min, sum/n; else print "0 0 0"}'
}

# --- setup --------------------------------------------------------------------

TOKEN_LABEL="${TOKEN_SYMBOL:-$TOKEN}"
entry_made=0
token_str=""
peak_raw=0
floor_raw=0
armed=0
arm_poll_count=0

echo -e "${GRAY}Detecting token decimals...${RESET}"
TOKEN_DECIMALS=$(get_token_decimals "$TOKEN" "$CHAIN")
TOKEN_SCALE=$(awk "BEGIN { printf \"%.0f\", 10 ^ $TOKEN_DECIMALS }")

echo ""
echo -e "${YELLOW}=== Speed Compression Buy ===${RESET}"
[[ "$DRY_RUN" == "1" ]] && echo -e "${YELLOW}  *** DRY-RUN MODE -- compression signals logged, no buy will execute ***${RESET}"
echo "  Chain           : $CHAIN"
echo "  Token           : $TOKEN_LABEL  (decimals: $TOKEN_DECIMALS)"
echo "  Buy amount      : $AMOUNT $BASE_LABEL  (on expansion breakout)"
echo "  Window polls    : $WINDOW_POLLS  (rolling range + mean)"
echo "  Compression     : <= ${COMPRESSION_PCT} % range/mean  (arm condition)"
echo "  Expansion       : +${EXPANSION_PCT} % above window high while armed  (entry)"
echo "  Trail pct       : ${TRAIL_PCT}% drop from peak triggers sell"
(( ARM_TIMEOUT > 0 )) && echo "  Arm timeout     : $ARM_TIMEOUT polls without expansion resets arm"
echo "  Poll interval   : $POLL_SECONDS s"
echo "  Max polls       : $MAX_ITERATIONS"
echo ""

# --- step 1: reference quote --------------------------------------------------

echo -e "${CYAN}Step 1 - Quoting $AMOUNT $BASE_LABEL -> $TOKEN_LABEL (reference, no buy yet)...${RESET}"

ref_buy_json=$(get_quote "$BASE_TOKEN" "$TOKEN" "$AMOUNT")
ref_token_raw=$(extract_buy_amount "$ref_buy_json")
[[ -z "$ref_token_raw" ]] && { echo "Failed to parse ref buyAmount. Aborting." >&2; exit 1; }
ref_token_human=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", $ref_token_raw / $TOKEN_SCALE }")
ref_token_str=$(format_token "$ref_token_human" "$TOKEN_DECIMALS")
awk_gt "$ref_token_str" "0" || { echo "Reference amount resolved to 0. Aborting." >&2; exit 1; }
echo "  Reference amount : $ref_token_str $TOKEN_LABEL for $AMOUNT $BASE_LABEL"

# --- step 2: initial price ----------------------------------------------------

echo ""
echo -e "${CYAN}Step 2 - Getting initial price...${RESET}"

init_sell_json=$(get_quote "$TOKEN" "$BASE_TOKEN" "$ref_token_str")
init_raw=$(extract_buy_amount "$init_sell_json")
[[ -z "$init_raw" ]] && { echo "Failed to parse initial price. Aborting." >&2; exit 1; }
init_eth=$(to_human_base "$init_raw")
echo "  Initial price : $init_eth $BASE_LABEL  (for $ref_token_str $TOKEN_LABEL)"
echo ""

window_add "$init_raw"

# --- step 3: warm-up ----------------------------------------------------------

echo -e "${CYAN}Step 3 - Warm-up: collecting $WINDOW_POLLS polls to build price window...${RESET}"

warmup_needed=$(( WINDOW_POLLS - 1 ))
warmup_done=0

while (( warmup_done < warmup_needed )); do
    (( warmup_done++ )) || true
    ts=$(date +"%H:%M:%S")
    echo -e "${GRAY}[$ts] Warm-up $warmup_done/$warmup_needed - waiting $POLL_SECONDS s...${RESET}"
    sleep "$POLL_SECONDS"

    poll_json=$(get_quote "$TOKEN" "$BASE_TOKEN" "$ref_token_str" 2>&1) || {
        echo "Warning: warm-up poll $warmup_done failed - using last known."
        window_add "$init_raw"
        continue
    }
    w_raw=$(extract_buy_amount "$poll_json")
    if [[ -z "$w_raw" ]]; then
        window_add "$init_raw"
        continue
    fi
    w_eth=$(to_human_base "$w_raw")
    read -r w_high w_low w_mean <<< "$(window_stats)"
    w_range=$(awk "BEGIN { printf \"%.2f\", ($w_mean > 0) ? ($w_high - $w_low) / $w_mean * 100 : 0 }")
    w_count=$(echo "$WINDOW_RAW" | wc -w)
    ts2=$(date +"%H:%M:%S")
    echo -e "${GRAY}[$ts2] Price: $w_eth $BASE_LABEL  range: ${w_range}%  compress<=${COMPRESSION_PCT}%  [$w_count samples]${RESET}"
    window_add "$w_raw"
done

read -r w_high w_low w_mean <<< "$(window_stats)"
w_range=$(awk "BEGIN { printf \"%.2f\", ($w_mean > 0) ? ($w_high - $w_low) / $w_mean * 100 : 0 }")
w_mean_eth="$w_mean"

echo ""
echo -e "${CYAN}Warm-up complete. Range: ${w_range}%  Mean: $w_mean_eth $BASE_LABEL  ($WINDOW_POLLS polls)${RESET}"
echo ""

# --- step 4: monitoring -------------------------------------------------------

echo -e "${CYAN}Step 4 - Monitoring for compression then expansion...${RESET}"
echo ""

iteration=0

while (( iteration < MAX_ITERATIONS )); do
    (( iteration++ )) || true
    ts=$(date +"%H:%M:%S")
    echo -e "${GRAY}[$ts] Poll $iteration / $MAX_ITERATIONS - waiting $POLL_SECONDS s...${RESET}"
    sleep "$POLL_SECONDS"

    poll_json=$(get_quote "$TOKEN" "$BASE_TOKEN" "$ref_token_str" 2>&1) || {
        echo "Warning: quote failed on poll $iteration - retrying."
        continue
    }
    current_raw=$(extract_buy_amount "$poll_json")
    [[ -z "$current_raw" ]] && { echo "Warning: empty buyAmount on poll $iteration - retrying."; continue; }
    current_eth=$(to_human_base "$current_raw")
    ts2=$(date +"%H:%M:%S")

    # Update rolling window and recompute stats
    window_add "$current_raw"
    read -r window_high_eth window_low_eth rolling_mean_eth <<< "$(window_stats)"
    window_high_raw=$(window_max_raw)
    range_ratio=$(awk "BEGIN { printf \"%.2f\", ($rolling_mean_eth > 0) ? ($window_high_eth - $window_low_eth) / $rolling_mean_eth * 100 : 0 }")

    # ── post-entry: trailing stop ──────────────────────────────────────────────
    if [[ "$entry_made" == "1" ]]; then
        tq_json=$(get_quote "$TOKEN" "$BASE_TOKEN" "$token_str" 2>&1) || { echo "Warning: trail quote failed - retrying."; continue; }
        t_raw=$(extract_buy_amount "$tq_json")
        [[ -z "$t_raw" ]] && { echo "Warning: empty trail buyAmount - retrying."; continue; }
        t_eth=$(to_human_base "$t_raw")

        if awk_gt "$t_raw" "$peak_raw"; then
            peak_raw="$t_raw"
            floor_raw=$(awk "BEGIN { printf \"%.0f\", $peak_raw * (1 - $TRAIL_PCT / 100) }")
        fi

        peak_eth=$(to_human_base "$peak_raw")
        floor_eth=$(to_human_base "$floor_raw")
        pct_from_peak=$(awk "BEGIN { printf \"%.4f\", ($t_raw - $peak_raw) / $peak_raw * 100 }")
        trail_dist=$(awk "BEGIN { printf \"%.0f\", $peak_raw - $floor_raw }")
        dist_to_floor=$(awk "BEGIN { printf \"%.0f\", $t_raw - $floor_raw }")

        if awk_gte "$t_raw" "$peak_raw"; then color="$GREEN"
        elif awk "BEGIN { exit ($trail_dist > 0 && $dist_to_floor / $trail_dist < 0.25) ? 0 : 1 }"; then color="$RED"
        else color="$WHITE"; fi

        echo -e "${color}[$ts2] POST-ENTRY  $t_eth $BASE_LABEL  peak: $peak_eth  floor: $floor_eth  (${pct_from_peak}% from peak)${RESET}"

        if awk_lte "$t_raw" "$floor_raw"; then
            gain_pct=$(awk "BEGIN { printf \"%.4f\", ($t_eth - $AMOUNT) / $AMOUNT * 100 }")
            echo ""
            echo -e "${RED}Trail floor breached! $t_eth $BASE_LABEL back  (${gain_pct}% vs entry cost)${RESET}"
            if [[ "$DRY_RUN" == "1" ]]; then echo -e "${YELLOW}[DRY-RUN] Would SELL $token_str $TOKEN_LABEL -> $BASE_LABEL${RESET}"; exit 0; fi
            echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy ${BASE_TOKEN} -a $token_str -y${RESET}"
            speed swap -c "$CHAIN" --sell "$TOKEN" --buy "$BASE_TOKEN" -a "$token_str" -y
            exit $?
        fi
        continue
    fi

    # ── compression state machine ──────────────────────────────────────────────
    is_compressed=0
    awk "BEGIN { exit ($range_ratio <= $COMPRESSION_PCT) ? 0 : 1 }" 2>/dev/null && is_compressed=1

    if (( armed == 1 && is_compressed == 0 )); then
        armed=0; arm_poll_count=0
        echo -e "${GRAY}[$ts2] COMPRESSION  range: ${range_ratio}%  mean: $rolling_mean_eth $BASE_LABEL  [COMPRESSION LOST]${RESET}"
    elif (( armed == 0 && is_compressed == 1 )); then
        armed=1; arm_poll_count=0
        echo -e "${CYAN}[$ts2] COMPRESSION  range: ${range_ratio}% <= ${COMPRESSION_PCT}%  mean: $rolling_mean_eth $BASE_LABEL -- ARMED${RESET}"
    elif (( armed == 1 )); then
        (( arm_poll_count++ )) || true
        if (( ARM_TIMEOUT > 0 && arm_poll_count >= ARM_TIMEOUT )); then
            armed=0; arm_poll_count=0
            echo -e "${YELLOW}[$ts2] COMPRESSION  range: ${range_ratio}%  -- ARM TIMEOUT ($ARM_TIMEOUT polls). Resetting.${RESET}"
        fi
    fi

    # ── expansion breakout check (only when armed) ─────────────────────────────
    expansion_thresh=$(awk -v w="$window_high_raw" -v p="$EXPANSION_PCT" 'BEGIN { printf "%.0f", w * (1 + p / 100) }')
    expansion_thresh_eth=$(to_human_base "$expansion_thresh")
    pct_vs_high=$(awk -v c="$current_raw" -v wh="$window_high_raw" 'BEGIN { printf "%+.4f", (c - wh) / wh * 100 }')

    if (( armed == 1 )); then
        if awk_gte "$current_raw" "$expansion_thresh"; then color="$GREEN"
        elif awk -v c="$current_raw" -v wh="$window_high_raw" 'BEGIN { exit (c >= wh) ? 0 : 1 }'; then color="$YELLOW"
        else color="$CYAN"; fi
        armed_label="ARMED"
    else
        if (( is_compressed == 1 )); then color="$CYAN"; else color="$GRAY"; fi
        armed_label="watching"
    fi

    echo -e "${color}[$ts2] [$armed_label] price: $current_eth $BASE_LABEL  win-high: $window_high_eth $BASE_LABEL  range: ${range_ratio}%  exp-thresh: $expansion_thresh_eth $BASE_LABEL  (${pct_vs_high}% vs high)${RESET}"

    if (( armed == 1 )); then
        if awk_gte "$current_raw" "$expansion_thresh"; then
            echo ""
            echo -e "${GREEN}EXPANSION BREAKOUT! Price $current_eth $BASE_LABEL >= $expansion_thresh_eth $BASE_LABEL while compressed  (+${pct_vs_high}% vs window high)${RESET}"

            if [[ "$DRY_RUN" == "1" ]]; then
                echo -e "${YELLOW}  [DRY-RUN] Would BUY $AMOUNT $BASE_LABEL of $TOKEN_LABEL now. Continuing to observe...${RESET}"
                armed=0
            else
                echo ""
                echo -e "${GREEN}Executing compression breakout buy: $AMOUNT $BASE_LABEL -> $TOKEN_LABEL${RESET}"
                echo -e "${CYAN}>>> speed swap -c $CHAIN --sell ${BASE_TOKEN} --buy $TOKEN -a $AMOUNT -y${RESET}"
                speed swap -c "$CHAIN" --sell "$BASE_TOKEN" --buy "$TOKEN" -a "$AMOUNT" -y || {
                    echo "Compression buy failed. Aborting." >&2; exit 1
                }
                echo ""

                echo -e "${CYAN}Getting post-buy quote to anchor trailing stop...${RESET}"
                post_buy_json=$(get_quote "$TOKEN" "$BASE_TOKEN" "$ref_token_str" 2>&1) || { echo "Post-buy quote failed. Aborting." >&2; exit 1; }
                post_buy_raw=$(extract_buy_amount "$post_buy_json")
                [[ -z "$post_buy_raw" ]] && { echo "Empty post-buy raw. Aborting." >&2; exit 1; }

                token_str="$ref_token_str"
                peak_raw="$post_buy_raw"
                floor_raw=$(awk "BEGIN { printf \"%.0f\", $peak_raw * (1 - $TRAIL_PCT / 100) }")
                entry_made=1

                entry_eth=$(to_human_base "$post_buy_raw")
                peak_eth=$(to_human_base "$peak_raw")
                floor_eth=$(to_human_base "$floor_raw")
                echo -e "${GRAY}  Entry price  : $entry_eth $BASE_LABEL  (for $token_str $TOKEN_LABEL)${RESET}"
                echo -e "${GRAY}  Trail peak   : $peak_eth $BASE_LABEL${RESET}"
                echo -e "${GRAY}  Trail floor  : $floor_eth $BASE_LABEL  (-${TRAIL_PCT}%)${RESET}"
                echo ""
            fi
        fi
    fi
done

# --- max iterations -----------------------------------------------------------

echo ""
if [[ "$entry_made" == "1" ]]; then
    echo -e "${YELLOW}Max iterations ($MAX_ITERATIONS) reached. Selling position...${RESET}"
    echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy ${BASE_TOKEN} -a $token_str -y${RESET}"
    speed swap -c "$CHAIN" --sell "$TOKEN" --buy "$BASE_TOKEN" -a "$token_str" -y
else
    echo -e "${YELLOW}Max iterations ($MAX_ITERATIONS) reached. No expansion breakout detected. Exiting without a trade.${RESET}"
fi
