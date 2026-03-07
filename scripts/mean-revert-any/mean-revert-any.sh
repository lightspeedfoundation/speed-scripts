#!/usr/bin/env bash
# mean-revert-any.sh
# Build a rolling price mean and only buy when price dips --dip-pct% below it.
# Exits when price recovers back toward the mean or at a hard stop-loss.
# Never spends ETH unless a confirmed dip occurs.
#
# Usage:
#   ./mean-revert-any.sh --chain base --token speed --amount 0.002 --window-polls 20 --dip-pct 3 --recover-pct 1 --stop-pct 10
#   ./mean-revert-any.sh --chain base --token 0xcbB7... --tokensymbol cbBTC --amount 0.012 --dip-pct 2 --recover-pct 0.5 --stop-pct 8 --pollseconds 60
#   ./mean-revert-any.sh --chain base --token speed --amount 0.002 --dip-pct 3 --trail-pct 3 --stop-pct 10
#   ./mean-revert-any.sh --chain base --token speed --amount 0.001 --dip-pct 2 --dry-run
#
# Steps:
#   1. Auto-detects token decimals via on-chain RPC call.
#   2. Quotes Amount ETH -> Token (reference, no buy yet).
#   3. Warm-up: polls WindowPolls times to build the rolling price window (SMA).
#   4. Detection: each poll updates the rolling window and recomputes the mean.
#      Dip condition: currentPrice <= rollingMean * (1 - dipPct/100)
#   5. On dip confirmed: buys Amount ETH of token.
#   6. Post-buy exits:
#      a. Mean-recovery (default): sell when price >= mean * (1 - recoverPct/100).
#      b. Trailing stop (--trail-pct > 0): peak/floor trailing stop.
#      Hard stop always active: sell if price <= entryPrice * (1 - stopPct/100).
#   7. MaxIterations without dip: exits without buying.

set -euo pipefail

# --- defaults -----------------------------------------------------------------

CHAIN=""
TOKEN=""
AMOUNT=""
TOKEN_SYMBOL=""
WINDOW_POLLS=20
DIP_PCT=3
RECOVER_PCT=1
STOP_PCT=10
TRAIL_PCT=0
POLL_SECONDS=60
MAX_ITERATIONS=1440
TIME_STOP_MINUTES=0
DRY_RUN=0

# --- arg parsing --------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chain)         CHAIN="$2";         shift 2 ;;
        --token)         TOKEN="$2";         shift 2 ;;
        --amount)        AMOUNT="$2";        shift 2 ;;
        --tokensymbol)   TOKEN_SYMBOL="$2";  shift 2 ;;
        --window-polls)  WINDOW_POLLS="$2";  shift 2 ;;
        --dip-pct)       DIP_PCT="$2";       shift 2 ;;
        --recover-pct)   RECOVER_PCT="$2";   shift 2 ;;
        --stop-pct)      STOP_PCT="$2";      shift 2 ;;
        --trail-pct)     TRAIL_PCT="$2";     shift 2 ;;
        --pollseconds)        POLL_SECONDS="$2";        shift 2 ;;
        --maxiterations)      MAX_ITERATIONS="$2";      shift 2 ;;
        --time-stop-minutes)  TIME_STOP_MINUTES="$2";   shift 2 ;;
        --dry-run)            DRY_RUN=1;                shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$CHAIN" || -z "$TOKEN" || -z "$AMOUNT" ]]; then
    echo "Usage: $0 --chain <chain> --token <addr|alias> --amount <eth> [--window-polls <n>] [--dip-pct <pct>] [--recover-pct <pct>] [--stop-pct <pct>] [--trail-pct <pct>] [--tokensymbol <name>] [--pollseconds <s>] [--maxiterations <n>] [--dry-run]" >&2
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

# Rolling window stored as space-separated raw integers
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

window_mean() {
    echo "$WINDOW_DATA" | tr ' ' '\n' | grep -v '^$' | \
        awk '{sum += $1; count++} END { if (count > 0) printf "%.0f", sum/count; else print 0 }'
}

# --- setup --------------------------------------------------------------------

TOKEN_LABEL="${TOKEN_SYMBOL:-$TOKEN}"
entry_made=0
token_str=""
entry_raw=0
stop_thresh_raw=0
peak_raw=0
floor_raw=0

echo -e "${GRAY}Detecting token decimals...${RESET}"
TOKEN_DECIMALS=$(get_token_decimals "$TOKEN" "$CHAIN")
TOKEN_SCALE=$(awk "BEGIN { printf \"%.0f\", 10 ^ $TOKEN_DECIMALS }")

if awk_gt "$TRAIL_PCT" "0"; then
    exit_mode="trailing-stop  (${TRAIL_PCT}% drop from peak)"
else
    exit_mode="mean-recovery  (sell at mean - ${RECOVER_PCT}%)"
fi

echo ""
echo -e "${YELLOW}=== Speed Mean-Reversion Buy ===${RESET}"
[[ "$DRY_RUN" == "1" ]] && echo -e "${YELLOW}  *** DRY-RUN MODE -- no buy will execute ***${RESET}"
echo "  Chain          : $CHAIN"
echo "  Token          : $TOKEN_LABEL  (decimals: $TOKEN_DECIMALS)"
echo "  Buy amount     : $AMOUNT ETH  (on dip)"
echo "  Window polls   : $WINDOW_POLLS  (rolling SMA)"
echo "  Dip trigger    : ${DIP_PCT}% below rolling mean"
echo "  Exit mode      : $exit_mode"
echo "  Hard stop      : ${STOP_PCT}% below entry price"
echo "  Poll interval  : $POLL_SECONDS s"
echo "  Max polls      : $MAX_ITERATIONS"
(( TIME_STOP_MINUTES > 0 )) && echo "  Time stop      : ${TIME_STOP_MINUTES} min  (exits at thesis timeout regardless of price)"
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
    w_mean=$(window_mean)
    w_mean_eth=$(to_human_eth "$w_mean")
    w_dip_pct=$(awk "BEGIN { printf \"%+.2f\", ($w_mean > 0) ? ($w_mean - $w_raw) / $w_mean * 100 : 0 }")
    w_count=$(echo "$WINDOW_DATA" | wc -w)
    ts2=$(date +"%H:%M:%S")
    echo -e "${GRAY}[$ts2] Price: $w_eth ETH  mean: $w_mean_eth  (dip: $w_dip_pct%)  [$w_count samples]${RESET}"
    window_add "$w_raw"
done

rolling_mean=$(window_mean)
rolling_mean_eth=$(to_human_eth "$rolling_mean")
dip_thresh_raw=$(awk "BEGIN { printf \"%.0f\", $rolling_mean * (1 - $DIP_PCT / 100) }")
dip_thresh_eth=$(to_human_eth "$dip_thresh_raw")

echo ""
echo -e "${CYAN}Warm-up complete. Rolling mean: $rolling_mean_eth ETH  ($WINDOW_POLLS polls)${RESET}"
echo -e "${CYAN}Dip entry threshold : $dip_thresh_eth ETH  (mean - ${DIP_PCT}%)${RESET}"
echo ""

# --- step 4: monitoring + dip detection / post-entry exit --------------------

echo -e "${CYAN}Step 4 - Monitoring for dip...${RESET}"
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

    # Update rolling window and recompute mean
    window_add "$current_raw"
    rolling_mean=$(window_mean)
    rolling_mean_eth=$(to_human_eth "$rolling_mean")
    dip_thresh_raw=$(awk "BEGIN { printf \"%.0f\", $rolling_mean * (1 - $DIP_PCT / 100) }")

    # ── post-entry: exit management ───────────────────────────────────────────
    if [[ "$entry_made" == "1" ]]; then
        tq_json=$(get_quote "$TOKEN" "eth" "$token_str" 2>&1) || { echo "Warning: exit quote failed - retrying."; continue; }
        t_raw=$(extract_buy_amount "$tq_json")
        [[ -z "$t_raw" ]] && { echo "Warning: empty exit buyAmount - retrying."; continue; }
        t_eth=$(to_human_eth "$t_raw")

        # Hard stop — checked before both exit modes
        if awk_lte "$t_raw" "$stop_thresh_raw"; then
            loss_pct=$(awk "BEGIN { printf \"%.4f\", ($t_eth - $AMOUNT) / $AMOUNT * 100 }")
            echo ""
            echo -e "${RED}HARD STOP triggered! $t_eth ETH back  (${loss_pct}% vs entry cost)${RESET}"
            if [[ "$DRY_RUN" == "1" ]]; then
                echo -e "${YELLOW}[DRY-RUN] Would SELL $token_str $TOKEN_LABEL -> ETH now.${RESET}"
                exit 0
            fi
            echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy eth -a $token_str -y${RESET}"
            speed swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$token_str" -y
            exit $?
        fi

        stop_thresh_eth=$(to_human_eth "$stop_thresh_raw")

        if awk_gt "$TRAIL_PCT" "0"; then
            # ── trailing stop exit ─────────────────────────────────────────────
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

            echo -e "${color}[$ts2] POST-ENTRY  trail: $t_eth ETH  peak: $peak_eth  floor: $floor_eth  (${pct_from_peak}% from peak)  stop<$stop_thresh_eth${RESET}"

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

        else
            # ── mean-recovery exit ─────────────────────────────────────────────
            recovery_target_raw=$(awk "BEGIN { printf \"%.0f\", $rolling_mean * (1 - $RECOVER_PCT / 100) }")
            recovery_target_eth=$(to_human_eth "$recovery_target_raw")
            pct_vs_target=$(awk "BEGIN { printf \"%+.4f\", ($t_raw - $recovery_target_raw) / $recovery_target_raw * 100 }")

            if awk_gte "$t_raw" "$recovery_target_raw"; then
                color="$GREEN"
            elif awk "BEGIN { exit ($t_raw <= $stop_thresh_raw * 1.15) ? 0 : 1 }"; then
                color="$RED"
            else
                color="$WHITE"
            fi

            echo -e "${color}[$ts2] POST-ENTRY  recov: $t_eth ETH  mean: $rolling_mean_eth  target: $recovery_target_eth  (${pct_vs_target}% vs target)  stop<$stop_thresh_eth${RESET}"

            if awk_gte "$t_raw" "$recovery_target_raw"; then
                gain_pct=$(awk "BEGIN { printf \"%.4f\", ($t_eth - $AMOUNT) / $AMOUNT * 100 }")
                echo ""
                echo -e "${GREEN}Recovery target reached! $t_eth ETH back  (${gain_pct}% vs entry cost)${RESET}"
                if [[ "$DRY_RUN" == "1" ]]; then
                    echo -e "${YELLOW}[DRY-RUN] Would SELL $token_str $TOKEN_LABEL -> ETH${RESET}"
                    exit 0
                fi
                echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy eth -a $token_str -y${RESET}"
                speed swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$token_str" -y
                exit $?
            fi
        fi

        continue
    fi

    # ── pre-entry: watch for dip ──────────────────────────────────────────────
    dip_pct_current=$(awk "BEGIN { printf \"%+.4f\", ($rolling_mean > 0) ? ($rolling_mean - $current_raw) / $rolling_mean * 100 : 0 }")
    pct_vs_thresh=$(awk "BEGIN { printf \"%+.4f\", ($dip_thresh_raw > 0) ? ($current_raw - $dip_thresh_raw) / $dip_thresh_raw * 100 : 0 }")

    # Color: gray = above mean, white = dipping but not close, yellow = 50%+ of trigger, green = triggered
    if awk "BEGIN { exit (${dip_pct_current#+} >= $DIP_PCT) ? 0 : 1 }" 2>/dev/null; then
        color="$GREEN"
    elif awk "BEGIN { exit (${dip_pct_current#+} >= $DIP_PCT * 0.5) ? 0 : 1 }" 2>/dev/null; then
        color="$YELLOW"
    elif awk "BEGIN { exit (${dip_pct_current#+} >= 0) ? 0 : 1 }" 2>/dev/null; then
        color="$WHITE"
    else
        color="$GRAY"
    fi

    echo -e "${color}[$ts2] Price: $current_eth ETH  mean: $rolling_mean_eth  dip: ${dip_pct_current}%  trigger: ${DIP_PCT}%  (thresh: ${pct_vs_thresh}% away)${RESET}"

    # Dip entry condition
    if awk_lte "$current_raw" "$dip_thresh_raw"; then
        dip_thresh_disp=$(to_human_eth "$dip_thresh_raw")
        echo ""
        echo -e "${GREEN}DIP detected! Price $current_eth ETH <= threshold $dip_thresh_disp ETH  (${dip_pct_current}% below mean)${RESET}"

        if [[ "$DRY_RUN" == "1" ]]; then
            echo -e "${YELLOW}  [DRY-RUN] Would BUY $AMOUNT ETH of $TOKEN_LABEL now. Continuing to observe...${RESET}"
        else
            echo ""
            echo -e "${GREEN}Executing dip buy: $AMOUNT ETH -> $TOKEN_LABEL${RESET}"
            echo -e "${CYAN}>>> speed swap -c $CHAIN --sell eth --buy $TOKEN -a $AMOUNT -y${RESET}"
            speed swap -c "$CHAIN" --sell eth --buy "$TOKEN" -a "$AMOUNT" -y || {
                echo "Dip buy failed. Aborting." >&2; exit 1
            }
            echo ""

            echo -e "${CYAN}Getting post-buy quote to anchor exit levels...${RESET}"
            post_buy_json=$(get_quote "$TOKEN" "eth" "$ref_token_str" 2>&1) || { echo "Post-buy quote failed. Aborting." >&2; exit 1; }
            post_buy_raw=$(extract_buy_amount "$post_buy_json")
            [[ -z "$post_buy_raw" ]] && { echo "Empty post-buy raw. Aborting." >&2; exit 1; }

            token_str="$ref_token_str"
            entry_raw="$post_buy_raw"
            stop_thresh_raw=$(awk "BEGIN { printf \"%.0f\", $entry_raw * (1 - $STOP_PCT / 100) }")

            entry_eth=$(to_human_eth "$post_buy_raw")
            stop_thresh_eth=$(to_human_eth "$stop_thresh_raw")
            echo -e "${GRAY}  Entry price    : $entry_eth ETH  (for $token_str $TOKEN_LABEL)${RESET}"
            echo -e "${GRAY}  Hard stop      : $stop_thresh_eth ETH  (-${STOP_PCT}% from entry)${RESET}"

            if awk_gt "$TRAIL_PCT" "0"; then
                peak_raw="$post_buy_raw"
                floor_raw=$(awk "BEGIN { printf \"%.0f\", $peak_raw * (1 - $TRAIL_PCT / 100) }")
                peak_eth=$(to_human_eth "$peak_raw")
                floor_eth=$(to_human_eth "$floor_raw")
                echo -e "${GRAY}  Trail peak     : $peak_eth ETH${RESET}"
                echo -e "${GRAY}  Trail floor    : $floor_eth ETH  (-${TRAIL_PCT}%)${RESET}"
            else
                recovery_target_raw=$(awk "BEGIN { printf \"%.0f\", $rolling_mean * (1 - $RECOVER_PCT / 100) }")
                recovery_target_eth=$(to_human_eth "$recovery_target_raw")
                echo -e "${GRAY}  Recovery target: $recovery_target_eth ETH  (mean - ${RECOVER_PCT}%)${RESET}"
            fi

            echo ""
            entry_made=1
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
    echo -e "${YELLOW}Max iterations ($MAX_ITERATIONS) reached. No dip detected. Exiting without a trade.${RESET}"
fi
