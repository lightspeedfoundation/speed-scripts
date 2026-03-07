#!/usr/bin/env bash
# ladder-buy-any.sh
# Accumulate any token at N price levels below current price.
# Each time price dips to a rung trigger, buy --eth-per-rung ETH worth.
# Optionally, when all rungs fill, start a trailing stop on the full position.
#
# Usage:
#   ./ladder-buy-any.sh --chain base --token speed --eth-per-rung 0.001 --rungs 4 --rung-spacing-pct 5
#   ./ladder-buy-any.sh --chain base --token speed --eth-per-rung 0.001 --rungs 4 --rung-spacing-pct 5 --trail-after-filled --trail-pct 4
#   ./ladder-buy-any.sh --chain base --token 0xcbB7... --tokensymbol cbBTC --eth-per-rung 0.002 --rungs 3 --rung-spacing-pct 3 --trail-after-filled --trail-pct 4
#   ./ladder-buy-any.sh --chain base --token speed --eth-per-rung 0.001 --rungs 5 --rung-spacing-pct 3 --dry-run
#
# Steps:
#   1. Auto-detects token decimals via on-chain RPC call.
#   2. Quotes EthPerRung ETH -> Token to derive reference amount.
#   3. Quotes reference amount -> ETH to establish baseline price.
#   4. Builds buy ladder: rung[i] triggers when price drops (i+1)*RungSpacingPct%.
#   5. Polls every --pollseconds. When price drops to a rung, executes buy.
#   6. If --trail-after-filled: starts trailing stop when all rungs are filled.
#   7. MaxIterations: sells all accumulated tokens at market.

set -euo pipefail

# --- defaults -----------------------------------------------------------------

CHAIN=""
TOKEN=""
ETH_PER_RUNG=""
TOKEN_SYMBOL=""
RUNGS=4
RUNG_SPACING_PCT=5
TRAIL_PCT=5
TRAIL_AFTER_FILLED=0
TRAIL_AFTER_N=0
POLL_SECONDS=60
MAX_ITERATIONS=2880
DRY_RUN=0

# --- arg parsing --------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chain)             CHAIN="$2";             shift 2 ;;
        --token)             TOKEN="$2";             shift 2 ;;
        --eth-per-rung)      ETH_PER_RUNG="$2";      shift 2 ;;
        --tokensymbol)       TOKEN_SYMBOL="$2";       shift 2 ;;
        --rungs)             RUNGS="$2";             shift 2 ;;
        --rung-spacing-pct)  RUNG_SPACING_PCT="$2";  shift 2 ;;
        --trail-pct)          TRAIL_PCT="$2";         shift 2 ;;
        --trail-after-n)      TRAIL_AFTER_N="$2";    shift 2 ;;
        --trail-after-filled) TRAIL_AFTER_FILLED=1;  shift ;;
        --pollseconds)        POLL_SECONDS="$2";      shift 2 ;;
        --maxiterations)     MAX_ITERATIONS="$2";    shift 2 ;;
        --dry-run)           DRY_RUN=1;              shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$CHAIN" || -z "$TOKEN" || -z "$ETH_PER_RUNG" ]]; then
    echo "Usage: $0 --chain <chain> --token <addr|alias> --eth-per-rung <eth> [--rungs <n>] [--rung-spacing-pct <pct>] [--trail-after-n <n>] [--trail-after-filled] [--trail-pct <pct>] [--tokensymbol <name>] [--pollseconds <s>] [--maxiterations <n>] [--dry-run]" >&2
    exit 1
fi

# Backward-compat: --trail-after-filled is an alias for --trail-after-n $RUNGS
if (( TRAIL_AFTER_FILLED == 1 )) && (( TRAIL_AFTER_N == 0 )); then
    TRAIL_AFTER_N=$RUNGS
fi

# --- colours ------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
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

awk_lte() { awk "BEGIN { exit ($1 <= $2) ? 0 : 1 }"; }
awk_gte() { awk "BEGIN { exit ($1 >= $2) ? 0 : 1 }"; }
awk_gt()  { awk "BEGIN { exit ($1 > $2)  ? 0 : 1 }"; }

# --- setup --------------------------------------------------------------------

TOKEN_LABEL="${TOKEN_SYMBOL:-$TOKEN}"
total_eth_spent=0
total_buys=0
acc_token_human=0

echo -e "${GRAY}Detecting token decimals...${RESET}"
TOKEN_DECIMALS=$(get_token_decimals "$TOKEN" "$CHAIN")
TOKEN_SCALE=$(awk "BEGIN { printf \"%.0f\", 10 ^ $TOKEN_DECIMALS }")

total_eth_required=$(awk "BEGIN { printf \"%.8f\", $ETH_PER_RUNG * $RUNGS }")

echo ""
echo -e "${YELLOW}=== Speed Ladder Buy ===${RESET}"
[[ "$DRY_RUN" == "1" ]] && echo -e "${YELLOW}  *** DRY-RUN MODE -- no swaps will execute ***${RESET}"
echo "  Chain            : $CHAIN"
echo "  Token            : $TOKEN_LABEL  (decimals: $TOKEN_DECIMALS)"
echo "  ETH per rung     : $ETH_PER_RUNG ETH"
echo "  Rungs            : $RUNGS"
echo "  Rung spacing     : ${RUNG_SPACING_PCT}% drop per level"
echo "  Max ETH outlay   : $total_eth_required ETH (if all rungs fill)"
if (( TRAIL_AFTER_N > 0 )); then
    if (( TRAIL_AFTER_N == RUNGS )); then
        trail_label="all $RUNGS rungs"
    else
        trail_label="$TRAIL_AFTER_N of $RUNGS rungs"
    fi
    echo "  Trail after      : ${TRAIL_PCT}% trailing stop after $trail_label fill"
fi
echo "  Poll interval    : $POLL_SECONDS s"
echo "  Max polls        : $MAX_ITERATIONS"
echo ""

# --- step 1: reference quote --------------------------------------------------

echo -e "${CYAN}Step 1 - Quoting $ETH_PER_RUNG ETH -> $TOKEN_LABEL to establish reference...${RESET}"

ref_buy_json=$(get_quote "eth" "$TOKEN" "$ETH_PER_RUNG")
ref_token_raw=$(extract_buy_amount "$ref_buy_json")
[[ -z "$ref_token_raw" ]] && { echo "Failed to parse ref buyAmount. Aborting." >&2; exit 1; }

ref_token_human=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", $ref_token_raw / $TOKEN_SCALE }")
ref_token_str=$(format_token "$ref_token_human" "$TOKEN_DECIMALS")
awk_gt "$ref_token_str" "0" || { echo "Reference token amount resolved to 0. Aborting." >&2; exit 1; }
echo "  Reference amount : $ref_token_str $TOKEN_LABEL per $ETH_PER_RUNG ETH"

# --- step 2: baseline price ---------------------------------------------------

echo ""
echo -e "${CYAN}Step 2 - Quoting $TOKEN_LABEL -> ETH to establish baseline price...${RESET}"

base_sell_json=$(get_quote "$TOKEN" "eth" "$ref_token_str")
base_raw=$(extract_buy_amount "$base_sell_json")
[[ -z "$base_raw" ]] && { echo "Failed to parse base buyAmount. Aborting." >&2; exit 1; }
base_eth=$(to_human_eth "$base_raw")
echo "  Baseline price : $base_eth ETH (for $ref_token_str $TOKEN_LABEL)"
echo ""

# --- step 3: build buy ladder -------------------------------------------------

echo -e "${CYAN}Step 3 - Building buy ladder...${RESET}"

declare -a RUNG_TRIGGER_RAWS=()
declare -a RUNG_DROP_PCTS=()
declare -a RUNG_STATUS=()      # "waiting" | "filled"
declare -a RUNG_TOKEN_STRS=()

for (( i=0; i<RUNGS; i++ )); do
    drop_pct=$(awk "BEGIN { printf \"%.2f\", ($i + 1) * $RUNG_SPACING_PCT }")
    trigger_raw=$(awk "BEGIN { printf \"%.0f\", $base_raw * (1 - $drop_pct / 100) }")
    trigger_eth=$(to_human_eth "$trigger_raw")
    RUNG_TRIGGER_RAWS+=("$trigger_raw")
    RUNG_DROP_PCTS+=("$drop_pct")
    RUNG_STATUS+=("waiting")
    RUNG_TOKEN_STRS+=("")
    echo -e "${GRAY}  Rung $i: buy $ETH_PER_RUNG ETH when price drops ${drop_pct}%  (trigger: $trigger_eth ETH)${RESET}"
done
echo ""

# --- step 4: poll loop --------------------------------------------------------

iteration=0
filled_count=0
in_trail_mode=0
trail_peak_raw=0
trail_floor_raw=0

while (( iteration < MAX_ITERATIONS )); do
    (( iteration++ )) || true
    ts=$(date +"%H:%M:%S")
    echo -e "${GRAY}[$ts] Poll $iteration / $MAX_ITERATIONS - waiting $POLL_SECONDS s...${RESET}"
    sleep "$POLL_SECONDS"

    poll_json=$(get_quote "$TOKEN" "eth" "$ref_token_str" 2>&1) || {
        echo "Warning: quote failed on poll $iteration - retrying next interval."
        continue
    }

    current_raw=$(extract_buy_amount "$poll_json")
    if [[ -z "$current_raw" ]]; then
        echo "Warning: could not parse buyAmount on poll $iteration - retrying."
        continue
    fi

    current_eth=$(to_human_eth "$current_raw")
    pct_from_base=$(awk "BEGIN { printf \"%+.4f\", ($current_raw - $base_raw) / $base_raw * 100 }")
    ts2=$(date +"%H:%M:%S")

    # ── trailing stop mode ────────────────────────────────────────────────────
    if [[ "$in_trail_mode" == "1" ]]; then
        acc_str=$(format_token "$acc_token_human" "$TOKEN_DECIMALS")
        acc_json=$(get_quote "$TOKEN" "eth" "$acc_str" 2>&1) || { echo "Warning: acc quote failed - retrying."; continue; }
        acc_raw=$(extract_buy_amount "$acc_json")
        [[ -z "$acc_raw" ]] && { echo "Warning: empty acc buyAmount - retrying."; continue; }
        acc_eth=$(to_human_eth "$acc_raw")

        if awk_gt "$acc_raw" "$trail_peak_raw"; then
            trail_peak_raw="$acc_raw"
            trail_floor_raw=$(awk "BEGIN { printf \"%.0f\", $trail_peak_raw * (1 - $TRAIL_PCT / 100) }")
        fi
        trail_peak_eth=$(to_human_eth "$trail_peak_raw")
        trail_floor_eth=$(to_human_eth "$trail_floor_raw")
        pct_from_peak=$(awk "BEGIN { printf \"%.4f\", ($acc_raw - $trail_peak_raw) / $trail_peak_raw * 100 }")

        trail_dist=$(awk "BEGIN { printf \"%.0f\", $trail_peak_raw - $trail_floor_raw }")
        dist_to_floor=$(awk "BEGIN { printf \"%.0f\", $acc_raw - $trail_floor_raw }")

        if awk_gte "$acc_raw" "$trail_peak_raw"; then
            color="$GREEN"
        elif awk "BEGIN { exit ($trail_dist > 0 && $dist_to_floor / $trail_dist < 0.25) ? 0 : 1 }"; then
            color="$RED"
        else
            color="$CYAN"
        fi

        echo -e "${color}[$ts2] TRAIL MODE — acc pos: $acc_eth ETH  peak: $trail_peak_eth  floor: $trail_floor_eth  (${pct_from_peak}% from peak)${RESET}"

        if awk_lte "$acc_raw" "$trail_floor_raw"; then
            gain_pct=$(awk "BEGIN { printf \"%.4f\", ($acc_raw / $ETH_SCALE - $total_eth_spent) / $total_eth_spent * 100 }")
            echo ""
            echo -e "${RED}Trail floor breached! $acc_eth ETH back  (${gain_pct}% vs cost basis)${RESET}"
            if [[ "$DRY_RUN" == "1" ]]; then
                echo -e "${YELLOW}  [DRY-RUN] Would SELL all accumulated $acc_str $TOKEN_LABEL -> ETH${RESET}"
                exit 0
            fi
            echo -e "${CYAN}>>> Selling all: speed swap -c $CHAIN --sell $TOKEN --buy eth -a $acc_str -y${RESET}"
            speed swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$acc_str" -y
            exit $?
        fi
        continue
    fi

    # ── accumulation mode ─────────────────────────────────────────────────────
    echo -e "${WHITE}[$ts2] Price: $current_eth ETH  (${pct_from_base}% from base)  Filled: ${filled_count}/${RUNGS}${RESET}"

    # Sort rungs by trigger (highest first = least drop required)
    for (( i=0; i<RUNGS; i++ )); do
        [[ "${RUNG_STATUS[$i]}" == "filled" ]] && continue
        if awk_lte "$current_raw" "${RUNG_TRIGGER_RAWS[$i]}"; then
            trigger_eth_disp=$(to_human_eth "${RUNG_TRIGGER_RAWS[$i]}")
            echo -e "${MAGENTA}  Rung $i: BUY triggered (price $current_eth <= trigger $trigger_eth_disp, -${RUNG_DROP_PCTS[$i]}%)${RESET}"

            if [[ "$DRY_RUN" == "1" ]]; then
                echo -e "${YELLOW}  [DRY-RUN] Would BUY $ETH_PER_RUNG ETH of $TOKEN_LABEL at $current_eth ETH${RESET}"
                RUNG_STATUS[$i]="filled"
                (( filled_count++ )) || true
                (( total_buys++ )) || true
                total_eth_spent=$(awk "BEGIN { printf \"%.8f\", $total_eth_spent + $ETH_PER_RUNG }")
                # Estimate token amount for dry-run accumulation
                rung_buy_json=$(get_quote "eth" "$TOKEN" "$ETH_PER_RUNG" 2>&1) || true
                if [[ -n "$rung_buy_json" ]]; then
                    rung_token_raw=$(extract_buy_amount "$rung_buy_json" || echo "0")
                    rung_token_h=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", ${rung_token_raw:-0} / $TOKEN_SCALE }")
                    acc_token_human=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", $acc_token_human + $rung_token_h }")
                fi
            else
                rung_buy_json=$(get_quote "eth" "$TOKEN" "$ETH_PER_RUNG" 2>&1) || {
                    echo "Warning: pre-buy quote failed for rung $i - skipping." >&2; continue
                }
                rung_token_raw=$(extract_buy_amount "$rung_buy_json")
                [[ -z "$rung_token_raw" ]] && { echo "Warning: empty token raw for rung $i - skipping."; continue; }
                rung_token_h=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", $rung_token_raw / $TOKEN_SCALE }")
                rung_token_str=$(format_token "$rung_token_h" "$TOKEN_DECIMALS")

                echo -e "${CYAN}  >>> speed swap -c $CHAIN --sell eth --buy $TOKEN -a $ETH_PER_RUNG -y${RESET}"
                swap_out=$(speed --json --yes swap -c "$CHAIN" --sell eth --buy "$TOKEN" -a "$ETH_PER_RUNG" 2>&1)
                swap_json=$(echo "$swap_out" | grep -m1 '^{' || echo "")
                if echo "$swap_json" | grep -q '"error"'; then
                    echo "Warning: buy swap failed for rung $i -- skipping." >&2; continue
                fi
                tx_hash=$(echo "$swap_json" | grep -oP '"txHash"\s*:\s*"\K[^"]+' || echo "")
                [[ -n "$tx_hash" ]] && echo -e "${GRAY}  TX: $tx_hash${RESET}"

                RUNG_STATUS[$i]="filled"
                RUNG_TOKEN_STRS[$i]="$rung_token_str"
                (( filled_count++ )) || true
                (( total_buys++ )) || true
                total_eth_spent=$(awk "BEGIN { printf \"%.8f\", $total_eth_spent + $ETH_PER_RUNG }")
                acc_token_human=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", $acc_token_human + $rung_token_h }")
            fi
        fi
    done

    # Re-count filled
    filled_count=0
    for (( i=0; i<RUNGS; i++ )); do
        [[ "${RUNG_STATUS[$i]}" == "filled" ]] && (( filled_count++ )) || true
    done

    if (( in_trail_mode == 0 && TRAIL_AFTER_N > 0 && filled_count >= TRAIL_AFTER_N )); then
        acc_str=$(format_token "$acc_token_human" "$TOKEN_DECIMALS")
        if (( TRAIL_AFTER_N == RUNGS )); then
            trail_label="All $RUNGS rungs"
        else
            trail_label="$filled_count/$RUNGS rungs"
        fi
        echo ""
        echo -e "${GREEN}$trail_label filled! Switching to trailing stop mode...${RESET}"
        echo -e "${GRAY}  Accumulated: $acc_str $TOKEN_LABEL  (cost: $total_eth_spent ETH)${RESET}"
        acc_q=$(get_quote "$TOKEN" "eth" "$acc_str" 2>&1) || { echo "Warning: initial trail quote failed."; continue; }
        trail_peak_raw=$(extract_buy_amount "$acc_q")
        [[ -z "$trail_peak_raw" ]] && { echo "Warning: empty trail peak raw."; continue; }
        trail_floor_raw=$(awk "BEGIN { printf \"%.0f\", $trail_peak_raw * (1 - $TRAIL_PCT / 100) }")
        trail_peak_eth=$(to_human_eth "$trail_peak_raw")
        trail_floor_eth=$(to_human_eth "$trail_floor_raw")
        echo -e "${GRAY}  Trail peak  : $trail_peak_eth ETH${RESET}"
        echo -e "${GRAY}  Trail floor : $trail_floor_eth ETH  (-${TRAIL_PCT}%)${RESET}"
        echo ""
        in_trail_mode=1
    elif (( filled_count >= RUNGS && TRAIL_AFTER_N == 0 )); then
        echo ""
        echo -e "${GREEN}All $RUNGS rungs filled. No trailing stop set. Monitoring until max iterations.${RESET}"
    fi
done

# --- max iterations: sell all accumulated ------------------------------------

echo ""
echo -e "${YELLOW}Max iterations ($MAX_ITERATIONS) reached.${RESET}"

if awk_gt "$acc_token_human" "0"; then
    acc_str=$(format_token "$acc_token_human" "$TOKEN_DECIMALS")
    echo -e "${YELLOW}Selling all accumulated tokens: $acc_str $TOKEN_LABEL${RESET}"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "${YELLOW}  [DRY-RUN] Would SELL $acc_str $TOKEN_LABEL -> ETH${RESET}"
    else
        echo -e "${CYAN}>>> speed swap -c $CHAIN --sell $TOKEN --buy eth -a $acc_str -y${RESET}"
        speed swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$acc_str" -y
    fi
else
    echo -e "${GRAY}No accumulated tokens to sell.${RESET}"
fi

echo ""
echo -e "${YELLOW}=== Ladder Buy Session Complete ===${RESET}"
echo "  Total buys   : $total_buys"
echo "  ETH spent    : $total_eth_spent ETH"
