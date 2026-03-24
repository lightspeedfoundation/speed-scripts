#!/usr/bin/env bash
# value-average-any.sh
# On each interval, buy the deficit (or sell the surplus) needed to keep a
# portfolio value trajectory growing by --target-increment ETH per interval.
# Buys more when price is low, less when high. Optionally sells surplus.
#
# Usage:
#   ./value-average-any.sh --chain base --token speed --target-increment 0.001 --intervals 24 --interval-seconds 3600
#   ./value-average-any.sh --chain base --token speed --target-increment 0.001 --intervals 10 --interval-seconds 1800 --allow-sell
#   ./value-average-any.sh --chain base --token 0xcbB7... --tokensymbol cbBTC --target-increment 0.002 --intervals 12 --allow-sell
#   ./value-average-any.sh --chain base --token speed --target-increment 0.001 --intervals 10 --dry-run
#
# Steps:
#   1. Auto-detects token decimals via on-chain RPC call.
#   2. Starts with zero accumulated tokens and a zero target value.
#   3. Each interval:
#      a. Raises target by --target-increment ETH.
#      b. Quotes current accumulated position -> ETH = current value.
#      c. deficit = target - current value.
#      d. If deficit > 0: buy min(deficit, max-buy-per-interval) ETH of token.
#      e. If deficit < 0 and --allow-sell: sell proportional fraction.
#      f. Print: interval, target, current value, action, avg cost.
#   4. Final summary after all intervals.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_common.sh
source "$SCRIPT_DIR/../_common.sh"


# --- defaults -----------------------------------------------------------------

CHAIN=""
TOKEN=""
TARGET_INCREMENT=""
TOKEN_SYMBOL=""
INTERVALS=20
INTERVAL_SECONDS=3600
MAX_BUY_PER_INTERVAL=""   # empty = auto (TargetIncrement * 3)
ALLOW_SELL=0
DRY_RUN=0
DUST_THRESHOLD=0.0001
BASE_TOKEN="speed"
BASE_TOKEN_SYMBOL=""

# --- arg parsing --------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chain)                CHAIN="$2";                shift 2 ;;
        --token)                TOKEN="$2";                shift 2 ;;
        --target-increment)     TARGET_INCREMENT="$2";     shift 2 ;;
        --tokensymbol)          TOKEN_SYMBOL="$2";         shift 2 ;;
        --intervals)            INTERVALS="$2";            shift 2 ;;
        --interval-seconds)     INTERVAL_SECONDS="$2";    shift 2 ;;
        --max-buy-per-interval) MAX_BUY_PER_INTERVAL="$2"; shift 2 ;;
        --allow-sell)           ALLOW_SELL=1;              shift ;;
        --dry-run)              DRY_RUN=1;                 shift ;;
        --dust-threshold)       DUST_THRESHOLD="$2";     shift 2 ;;
        --base-token)         BASE_TOKEN="$2";       shift 2 ;;
        --base-token-symbol) BASE_TOKEN_SYMBOL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$CHAIN" || -z "$TOKEN" || -z "$TARGET_INCREMENT" ]]; then
    echo "Usage: $0 --chain <chain> --token <addr|alias> --target-increment <base> [--intervals <n>] [--interval-seconds <s>] [--max-buy-per-interval <base>] [--dust-threshold <base>] [--allow-sell] [--tokensymbol <name>] [--dry-run]" >&2
    exit 1
fi

BASE_TOKEN="$(speed_v2_resolve_base_token "$TOKEN" "$BASE_TOKEN")"
BASE_DECIMALS=$(speed_v2_get_token_decimals "$BASE_TOKEN" "$CHAIN")
BASE_SCALE=$(awk "BEGIN { printf \"%.0f\", 10 ^ $BASE_DECIMALS }")
BASE_LABEL="$(speed_v2_base_label "$BASE_TOKEN_SYMBOL" "$BASE_TOKEN")"

awk_gt0() { awk -v x="$1" 'BEGIN { exit (x > 0) ? 0 : 1 }'; }
awk_gte1() { awk -v x="$1" 'BEGIN { exit (x >= 1) ? 0 : 1 }'; }

if ! awk_gt0 "$TARGET_INCREMENT"; then echo "-TargetIncrement must be > 0." >&2; exit 1; fi
if ! awk_gte1 "$INTERVALS"; then echo "-Intervals must be >= 1." >&2; exit 1; fi

# Auto max-buy
if [[ -z "$MAX_BUY_PER_INTERVAL" ]]; then
    MAX_BUY_PER_INTERVAL=$(awk "BEGIN { printf \"%.8f\", $TARGET_INCREMENT * 3 }")
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

awk_gt()  { awk "BEGIN { exit ($1 > $2)  ? 0 : 1 }"; }
awk_lt()  { awk "BEGIN { exit ($1 < $2)  ? 0 : 1 }"; }
awk_gte() { awk "BEGIN { exit ($1 >= $2) ? 0 : 1 }"; }

fmt8() { awk -v x="$1" 'BEGIN { printf "%.8f", x + 0 }'; }

# --- setup --------------------------------------------------------------------

TOKEN_LABEL="${TOKEN_SYMBOL:-$TOKEN}"

echo -e "${GRAY}Detecting token decimals...${RESET}"
TOKEN_DECIMALS=$(get_token_decimals "$TOKEN" "$CHAIN")
TOKEN_SCALE=$(awk "BEGIN { printf \"%.0f\", 10 ^ $TOKEN_DECIMALS }")

total_target_eth=$(awk "BEGIN { printf \"%.8f\", $TARGET_INCREMENT * $INTERVALS }")
dust_fmt=$(awk -v d="$DUST_THRESHOLD" 'BEGIN { printf "%.8f", d }')
inc_fmt=$(awk -v x="$TARGET_INCREMENT" 'BEGIN { printf "%.8f", x }')
maxbuy_fmt=$(awk -v x="$MAX_BUY_PER_INTERVAL" 'BEGIN { printf "%.8f", x }')

echo ""
echo -e "${YELLOW}=== Speed Value Averaging ===${RESET}"
[[ "$DRY_RUN" == "1" ]] && echo -e "${YELLOW}  *** DRY-RUN MODE -- no swaps will execute ***${RESET}"
echo "  Chain              : $CHAIN"
echo "  Token              : $TOKEN_LABEL  (decimals: $TOKEN_DECIMALS)"
echo "  Target increment   : $inc_fmt $BASE_LABEL per interval"
echo "  Max buy/interval   : $maxbuy_fmt $BASE_LABEL"
echo "  Intervals          : $INTERVALS"
echo "  Interval length    : $INTERVAL_SECONDS s"
echo "  Final target value : $total_target_eth $BASE_LABEL  (after all intervals)"
echo "  Dust threshold     : $dust_fmt $BASE_LABEL  (min buy; raise for 6-dec stablecoins, etc.)"
if [[ "$ALLOW_SELL" == "1" ]]; then echo "  Allow sell         : True"; else echo "  Allow sell         : False"; fi
echo ""

# --- state --------------------------------------------------------------------

acc_token_human=0
target_value_eth=0
total_eth_spent=0
total_eth_received=0
total_buys=0
total_sells=0
skipped_dust=0

# --- interval loop ------------------------------------------------------------

for (( interval=1; interval<=INTERVALS; interval++ )); do
    ts=$(date +"%H:%M:%S")

    if (( interval > 1 )); then
        echo ""
        echo -e "${GRAY}[$ts] Interval $interval/$INTERVALS - waiting $INTERVAL_SECONDS s...${RESET}"
        sleep "$INTERVAL_SECONDS"
    else
        echo -e "${GRAY}[$ts] Interval $interval/$INTERVALS - starting now...${RESET}"
    fi

    ts2=$(date +"%H:%M:%S")

    # a) Raise target
    target_value_eth=$(awk "BEGIN { printf \"%.8f\", $target_value_eth + $TARGET_INCREMENT }")

    # b) Get current position value
    current_value_eth=0
    current_value_raw=0

    if awk_gt "$acc_token_human" "0"; then
        acc_str=$(format_token "$acc_token_human" "$TOKEN_DECIMALS")
        val_json=$(get_quote "$TOKEN" "$BASE_TOKEN" "$acc_str" 2>&1) || {
            echo "Warning: could not get position value on interval $interval -- using 0." >&2
        }
        if [[ -n "$val_json" ]]; then
            current_value_raw=$(extract_buy_amount "$val_json" || echo "0")
            current_value_eth=$(to_human_base "${current_value_raw:-0}")
        fi
    fi

    # c) Compute deficit
    deficit_eth=$(awk "BEGIN { printf \"%.8f\", $target_value_eth - $current_value_eth }")

    avg_cost="N/A"
    if awk_gt "$acc_token_human" "0" && awk_gt "$total_eth_spent" "0"; then
        avg_cost=$(awk "BEGIN { printf \"%.8f\", $total_eth_spent / $acc_token_human }")
    fi

    echo ""
    echo -e "${YELLOW}=== Interval $interval/$INTERVALS  [$ts2] ===${RESET}"
    echo "  Target value    : $(fmt8 "$target_value_eth") $BASE_LABEL"
    acc_disp=$(format_token "$acc_token_human" "$TOKEN_DECIMALS")
    printf "  Current value   : %s $BASE_LABEL  (%s %s held)\n" "$(fmt8 "$current_value_eth")" "$acc_disp" "$TOKEN_LABEL"
    printf "  Deficit/Surplus : %+.8f $BASE_LABEL\n" "$deficit_eth"
    if [[ "$avg_cost" == "N/A" ]]; then
        echo "  Avg entry cost  : N/A $BASE_LABEL per $TOKEN_LABEL"
    else
        echo "  Avg entry cost  : $(fmt8 "$avg_cost") $BASE_LABEL per $TOKEN_LABEL"
    fi

    # d) Buy if below target
    if awk_gt "$deficit_eth" "0"; then
        buy_eth=$(awk "BEGIN { printf \"%.8f\", ($deficit_eth < $MAX_BUY_PER_INTERVAL) ? $deficit_eth : $MAX_BUY_PER_INTERVAL }")

        if awk -v b="$buy_eth" -v dt="$DUST_THRESHOLD" 'BEGIN { exit (b < dt) ? 0 : 1 }'; then
            echo -e "${GRAY}  Action          : SKIP (buy amount $buy_eth $BASE_LABEL below dust threshold $dust_fmt $BASE_LABEL)${RESET}"
            (( skipped_dust++ )) || true
        else
            echo -e "${CYAN}  Action          : BUY $buy_eth $BASE_LABEL of $TOKEN_LABEL${RESET}"

            if [[ "$DRY_RUN" == "1" ]]; then
                dry_buy_json=$(get_quote "$BASE_TOKEN" "$TOKEN" "$buy_eth" 2>&1) || true
                if [[ -n "${dry_buy_json:-}" ]]; then
                    dry_tok_raw=$(extract_buy_amount "$dry_buy_json" || echo "0")
                    dry_tok_h=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", ${dry_tok_raw:-0} / $TOKEN_SCALE }")
                    echo -e "${YELLOW}  [DRY-RUN] Would buy $dry_tok_h $TOKEN_LABEL for $buy_eth $BASE_LABEL${RESET}"
                    acc_token_human=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", $acc_token_human + $dry_tok_h }")
                    total_eth_spent=$(awk "BEGIN { printf \"%.8f\", $total_eth_spent + $buy_eth }")
                    (( total_buys++ )) || true
                fi
            else
                pre_buy_json=$(get_quote "$BASE_TOKEN" "$TOKEN" "$buy_eth" 2>&1) || {
                    echo "Warning: pre-buy quote failed on interval $interval -- skipping." >&2
                    continue
                }
                pre_tok_raw=$(extract_buy_amount "$pre_buy_json")
                [[ -z "$pre_tok_raw" ]] && { echo "Warning: empty token raw -- skipping." >&2; continue; }
                pre_tok_h=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", $pre_tok_raw / $TOKEN_SCALE }")

                echo -e "${CYAN}  >>> speed swap -c $CHAIN --sell ${BASE_TOKEN} --buy $TOKEN -a $buy_eth -y${RESET}"
                if ! speed swap -c "$CHAIN" --sell "$BASE_TOKEN" --buy "$TOKEN" -a "$buy_eth" -y; then
                    echo "Warning: buy swap failed -- skipping." >&2
                    continue
                fi

                acc_token_human=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", $acc_token_human + $pre_tok_h }")
                total_eth_spent=$(awk "BEGIN { printf \"%.8f\", $total_eth_spent + $buy_eth }")
                (( total_buys++ )) || true
            fi
        fi

    # e) Sell if above target and AllowSell
    elif awk_lt "$deficit_eth" "0" && [[ "$ALLOW_SELL" == "1" ]]; then
        surplus_eth=$(awk "BEGIN { printf \"%.8f\", -1 * $deficit_eth }")

        if ! awk_gt "$acc_token_human" "0" || ! awk_gt "$current_value_eth" "0"; then
            echo -e "${GRAY}  Action          : SKIP SELL (no position to sell)${RESET}"
        else
            sell_ratio=$(awk "BEGIN { r = $surplus_eth / $current_value_eth; print (r > 1) ? 1 : r }")
            sell_human=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", $acc_token_human * $sell_ratio }")
            sell_str=$(format_token "$sell_human" "$TOKEN_DECIMALS")
            sell_pct=$(awk "BEGIN { printf \"%.2f\", $sell_ratio * 100 }")

            if ! awk_gt "$sell_str" "0"; then
                echo -e "${GRAY}  Action          : SKIP SELL (amount too small)${RESET}"
            else
                echo -e "${MAGENTA}  Action          : SELL $sell_str $TOKEN_LABEL  (surplus: $surplus_eth $BASE_LABEL, ${sell_pct}% of position)${RESET}"

                if [[ "$DRY_RUN" == "1" ]]; then
                    dry_sell_json=$(get_quote "$TOKEN" "$BASE_TOKEN" "$sell_str" 2>&1) || true
                    if [[ -n "${dry_sell_json:-}" ]]; then
                        dry_eth2_raw=$(extract_buy_amount "$dry_sell_json" || echo "0")
                        dry_eth2=$(to_human_base "${dry_eth2_raw:-0}")
                        echo -e "${YELLOW}  [DRY-RUN] Would sell $sell_str $TOKEN_LABEL for approx $dry_eth2 $BASE_LABEL${RESET}"
                        acc_token_human=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", $acc_token_human - $sell_human }")
                        total_eth_received=$(awk "BEGIN { printf \"%.8f\", $total_eth_received + $dry_eth2 }")
                        (( total_sells++ )) || true
                    fi
                else
                    check_json=$(get_quote "$TOKEN" "$BASE_TOKEN" "$sell_str" 2>&1) || true
                    eth_rec_raw=$(extract_buy_amount "$check_json" || echo "0")
                    eth_rec=$(to_human_base "${eth_rec_raw:-0}")
                    echo -e "${CYAN}  >>> speed swap -c $CHAIN --sell $TOKEN --buy ${BASE_TOKEN} -a $sell_str -y${RESET}"
                    if ! speed swap -c "$CHAIN" --sell "$TOKEN" --buy "$BASE_TOKEN" -a "$sell_str" -y; then
                        echo "Warning: sell swap failed -- skipping." >&2
                        continue
                    fi
                    total_eth_received=$(awk "BEGIN { printf \"%.8f\", $total_eth_received + $eth_rec }")

                    acc_token_human=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", $acc_token_human - $sell_human }")
                    (( total_sells++ )) || true
                fi
            fi
        fi

    else
        echo -e "${GRAY}  Action          : HOLD (value at target)${RESET}"
    fi
done

# --- final summary ------------------------------------------------------------

echo ""
echo -e "${YELLOW}=== Value Averaging Complete ===${RESET}"
echo "  Intervals run      : $INTERVALS"
echo "  Total buys         : $total_buys"
echo "  Total sells        : $total_sells"
echo "  Dust skips         : $skipped_dust"
spent_fmt=$(awk -v x="$total_eth_spent" 'BEGIN { printf "%.8f", x }')
recv_fmt=$(awk -v x="$total_eth_received" 'BEGIN { printf "%.8f", x }')
echo "  Base spent         : $spent_fmt $BASE_LABEL"
echo "  Base received      : $recv_fmt $BASE_LABEL"

net_deployed=$(awk "BEGIN { printf \"%.8f\", $total_eth_spent - $total_eth_received }")
net_fmt=$(awk -v n="$net_deployed" 'BEGIN { printf "%.8f", n }')
echo "  Net base deployed  : $net_fmt $BASE_LABEL"

if awk_gt "$acc_token_human" "0"; then
    acc_str=$(format_token "$acc_token_human" "$TOKEN_DECIMALS")
    echo "  Final position     : $acc_str $TOKEN_LABEL"
    if awk_gt "$total_eth_spent" "0"; then
        avg_cost=$(awk "BEGIN { printf \"%.8f\", $total_eth_spent / $acc_token_human }")
        echo "  Avg entry cost     : $avg_cost $BASE_LABEL per $TOKEN_LABEL"
    fi
    echo ""
    echo -e "${GRAY}  Position remains open. Use trailing-stop-any.sh or limit-order-any.sh to exit.${RESET}"
else
    echo -e "${GRAY}  Final position     : 0 (fully sold or nothing accumulated)${RESET}"
fi
