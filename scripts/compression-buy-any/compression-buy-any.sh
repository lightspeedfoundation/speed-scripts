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
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$CHAIN" || -z "$TOKEN" || -z "$AMOUNT" ]]; then
    echo "Usage: $0 --chain <chain> --token <addr|alias> --amount <eth> [--window-polls <n>] [--compression-pct <pct>] [--expansion-pct <pct>] [--trail-pct <pct>] [--arm-timeout <n>] [--tokensymbol <name>] [--pollseconds <s>] [--maxiterations <n>] [--dry-run]" >&2
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

# Rolling window as space-separated values
WINDOW_DATA=""

window_add() {
    local val="$1"
    WINDOW_DATA="$WINDOW_DATA $val"
    local count
    count=$(echo "$WINDOW_DATA" | wc -w)
    if (( count > WINDOW_POLLS )); then
        WINDOW_DATA=$(echo "$WINDOW_DATA" | awk '{for(i=2;i<=NF;i++) printf $i" "; print ""}' | sed 's/ $//')
    fi
}

window_stats() {
    echo "$WINDOW_DATA" | tr ' ' '\n' | grep -v '^$' | \
        awk 'BEGIN{max=-1e18;min=1e18;sum=0;n=0}
             {v=$1+0; if(v>max)max=v; if(v<min)min=v; sum+=v; n++}
             END{if(n>0) printf "%.0f %.0f %.0f", max, min, sum/n; else print "0 0 0"}'
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
echo "  Buy amount      : $AMOUNT ETH  (on expansion breakout)"
echo "  Window polls    : $WINDOW_POLLS  (rolling range + mean)"
echo "  Compression     : <= ${COMPRESSION_PCT}% range/mean  (arm condition)"
echo "  Expansion       : +${EXPANSION_PCT}% above window high while armed  (entry)"
echo "  Trail pct       : ${TRAIL_PCT}% drop from peak triggers sell"
(( ARM_TIMEOUT > 0 )) && echo "  Arm timeout     : $ARM_TIMEOUT polls without expansion resets arm"
echo "  Poll interval   : $POLL_SECONDS s"
echo "  Max polls       : $MAX_ITERATIONS"
echo ""

# --- step 1: reference quote --------------------------------------------------

echo -e "${CYAN}Step 1 - Quoting $AMOUNT ETH -> $TOKEN_LABEL (reference, no buy yet)...${RESET}"

ref_buy_json=$(get_quote "eth" "$TOKEN" "$AMOUNT")
ref_token_raw=$(extract_buy_amount "$ref_buy_json")
[[ -z "$ref_token_raw" ]] && { echo "Failed to parse ref buyAmount. Aborting." >&2; exit 1; }
ref_token_human=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", $ref_token_raw / $TOKEN_SCALE }")
ref_token_str=$(format_token "$ref_token_human" "$TOKEN_DECIMALS")
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

    poll_json=$(get_quote "$TOKEN" "eth" "$ref_token_str" 2>&1) || {
        echo "Warning: warm-up poll $warmup_done failed - using last known."
        window_add "$init_raw"
        continue
    }
    w_raw=$(extract_buy_amount "$poll_json")
    if [[ -z "$w_raw" ]]; then
        window_add "$init_raw"
        continue
    fi
    w_eth=$(to_human_eth "$w_raw")
    read -r w_high w_low w_mean <<< "$(window_stats)"
    w_range=$(awk "BEGIN { printf \"%.2f\", ($w_mean > 0) ? ($w_high - $w_low) / $w_mean * 100 : 0 }")
    w_count=$(echo "$WINDOW_DATA" | wc -w)
    ts2=$(date +"%H:%M:%S")
    echo -e "${GRAY}[$ts2] Price: $w_eth ETH  range: ${w_range}%  compress<=${COMPRESSION_PCT}%  [$w_count samples]${RESET}"
    window_add "$w_raw"
done

read -r w_high w_low w_mean <<< "$(window_stats)"
w_range=$(awk "BEGIN { printf \"%.2f\", ($w_mean > 0) ? ($w_high - $w_low) / $w_mean * 100 : 0 }")
w_mean_eth=$(to_human_eth "$w_mean")

echo ""
echo -e "${CYAN}Warm-up complete. Range: ${w_range}%  Mean: $w_mean_eth ETH  ($WINDOW_POLLS polls)${RESET}"
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

    poll_json=$(get_quote "$TOKEN" "eth" "$ref_token_str" 2>&1) || {
        echo "Warning: quote failed on poll $iteration - retrying."
        continue
    }
    current_raw=$(extract_buy_amount "$poll_json")
    [[ -z "$current_raw" ]] && { echo "Warning: empty buyAmount on poll $iteration - retrying."; continue; }
    current_eth=$(to_human_eth "$current_raw")
    ts2=$(date +"%H:%M:%S")

    # Update rolling window and recompute stats
    window_add "$current_raw"
    read -r window_high window_low rolling_mean <<< "$(window_stats)"
    window_high_eth=$(to_human_eth "$window_high")
    range_ratio=$(awk "BEGIN { printf \"%.2f\", ($rolling_mean > 0) ? ($window_high - $window_low) / $rolling_mean * 100 : 0 }")

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

        if awk_gte "$t_raw" "$peak_raw"; then color="$GREEN"
        elif awk "BEGIN { exit ($trail_dist > 0 && $dist_to_floor / $trail_dist < 0.25) ? 0 : 1 }"; then color="$RED"
        else color="$WHITE"; fi

        echo -e "${color}[$ts2] POST-ENTRY  $t_eth ETH  peak: $peak_eth  floor: $floor_eth  (${pct_from_peak}% from peak)${RESET}"

        if awk_lte "$t_raw" "$floor_raw"; then
            gain_pct=$(awk "BEGIN { printf \"%.4f\", ($t_eth - $AMOUNT) / $AMOUNT * 100 }")
            echo ""
            echo -e "${RED}Trail floor breached! $t_eth ETH back  (${gain_pct}% vs entry cost)${RESET}"
            if [[ "$DRY_RUN" == "1" ]]; then echo -e "${YELLOW}[DRY-RUN] Would SELL $token_str $TOKEN_LABEL -> ETH${RESET}"; exit 0; fi
            echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy eth -a $token_str -y${RESET}"
            speed swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$token_str" -y
            exit $?
        fi
        continue
    fi

    # ── compression state machine ──────────────────────────────────────────────
    is_compressed=0
    awk "BEGIN { exit ($range_ratio <= $COMPRESSION_PCT) ? 0 : 1 }" 2>/dev/null && is_compressed=1

    if (( armed == 1 && is_compressed == 0 )); then
        armed=0; arm_poll_count=0
        echo -e "${GRAY}[$ts2] COMPRESSION  range: ${range_ratio}%  mean: $(to_human_eth "$rolling_mean")  [COMPRESSION LOST]${RESET}"
    elif (( armed == 0 && is_compressed == 1 )); then
        armed=1; arm_poll_count=0
        echo -e "${CYAN}[$ts2] COMPRESSION  range: ${range_ratio}% <= ${COMPRESSION_PCT}%  mean: $(to_human_eth "$rolling_mean") -- ARMED${RESET}"
    elif (( armed == 1 )); then
        (( arm_poll_count++ )) || true
        if (( ARM_TIMEOUT > 0 && arm_poll_count >= ARM_TIMEOUT )); then
            armed=0; arm_poll_count=0
            echo -e "${YELLOW}[$ts2] COMPRESSION  range: ${range_ratio}%  -- ARM TIMEOUT ($ARM_TIMEOUT polls). Resetting.${RESET}"
        fi
    fi

    # ── expansion breakout check (only when armed) ─────────────────────────────
    expansion_thresh=$(awk "BEGIN { printf \"%.0f\", $window_high * (1 + $EXPANSION_PCT / 100) }")
    expansion_thresh_eth=$(to_human_eth "$expansion_thresh")
    pct_vs_high=$(awk "BEGIN { printf \"%+.4f\", ($current_raw - $window_high) / $window_high * 100 }")

    if (( armed == 1 )); then
        if awk_gte "$current_raw" "$expansion_thresh"; then color="$GREEN"
        elif awk "BEGIN { exit ($current_raw >= $window_high) ? 0 : 1 }"; then color="$YELLOW"
        else color="$CYAN"; fi
        armed_label="ARMED"
    else
        if (( is_compressed == 1 )); then color="$CYAN"; else color="$GRAY"; fi
        armed_label="watching"
    fi

    echo -e "${color}[$ts2] [$armed_label] price: $current_eth  win-high: $window_high_eth  range: ${range_ratio}%  exp-thresh: $expansion_thresh_eth  (${pct_vs_high}% vs high)${RESET}"

    if (( armed == 1 )); then
        if awk_gte "$current_raw" "$expansion_thresh"; then
            echo ""
            echo -e "${GREEN}EXPANSION BREAKOUT! Price $current_eth ETH >= $expansion_thresh_eth ETH while compressed  (+${pct_vs_high}% vs window high)${RESET}"

            if [[ "$DRY_RUN" == "1" ]]; then
                echo -e "${YELLOW}  [DRY-RUN] Would BUY $AMOUNT ETH of $TOKEN_LABEL now. Continuing to observe...${RESET}"
                armed=0
            else
                echo ""
                echo -e "${GREEN}Executing compression breakout buy: $AMOUNT ETH -> $TOKEN_LABEL${RESET}"
                echo -e "${CYAN}>>> speed swap -c $CHAIN --sell eth --buy $TOKEN -a $AMOUNT -y${RESET}"
                speed swap -c "$CHAIN" --sell eth --buy "$TOKEN" -a "$AMOUNT" -y || {
                    echo "Compression buy failed. Aborting." >&2; exit 1
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
    fi
done

# --- max iterations -----------------------------------------------------------

echo ""
if [[ "$entry_made" == "1" ]]; then
    echo -e "${YELLOW}Max iterations ($MAX_ITERATIONS) reached. Selling position...${RESET}"
    echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy eth -a $token_str -y${RESET}"
    speed swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$token_str" -y
else
    echo -e "${YELLOW}Max iterations ($MAX_ITERATIONS) reached. No expansion breakout detected. Exiting without a trade.${RESET}"
fi
