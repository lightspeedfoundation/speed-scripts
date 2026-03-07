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
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$CHAIN" || -z "$TOKEN" || -z "$TARGET_INCREMENT" ]]; then
    echo "Usage: $0 --chain <chain> --token <addr|alias> --target-increment <eth> [--intervals <n>] [--interval-seconds <s>] [--max-buy-per-interval <eth>] [--allow-sell] [--tokensymbol <name>] [--dry-run]" >&2
    exit 1
fi

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

awk_gt()  { awk "BEGIN { exit ($1 > $2)  ? 0 : 1 }"; }
awk_lt()  { awk "BEGIN { exit ($1 < $2)  ? 0 : 1 }"; }
awk_gte() { awk "BEGIN { exit ($1 >= $2) ? 0 : 1 }"; }

# --- setup --------------------------------------------------------------------

TOKEN_LABEL="${TOKEN_SYMBOL:-$TOKEN}"
TOKEN_DECIMALS=$(get_token_decimals "$TOKEN" "$CHAIN")
TOKEN_SCALE=$(awk "BEGIN { printf \"%.0f\", 10 ^ $TOKEN_DECIMALS }")

total_target_eth=$(awk "BEGIN { printf \"%.8f\", $TARGET_INCREMENT * $INTERVALS }")

echo ""
echo -e "${YELLOW}=== Speed Value Averaging ===${RESET}"
[[ "$DRY_RUN" == "1" ]] && echo -e "${YELLOW}  *** DRY-RUN MODE -- no swaps will execute ***${RESET}"
echo "  Chain              : $CHAIN"
echo "  Token              : $TOKEN_LABEL  (decimals: $TOKEN_DECIMALS)"
echo "  Target increment   : $TARGET_INCREMENT ETH per interval"
echo "  Max buy/interval   : $MAX_BUY_PER_INTERVAL ETH"
echo "  Intervals          : $INTERVALS"
echo "  Interval length    : $INTERVAL_SECONDS s"
echo "  Final target value : $total_target_eth ETH  (after all intervals)"
echo "  Allow sell         : $ALLOW_SELL"
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
        val_json=$(get_quote "$TOKEN" "eth" "$acc_str" 2>&1) || {
            echo "Warning: could not get position value on interval $interval -- using 0." >&2
        }
        if [[ -n "$val_json" ]]; then
            current_value_raw=$(extract_buy_amount "$val_json" || echo "0")
            current_value_eth=$(to_human_eth "${current_value_raw:-0}")
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
    echo "  Target value    : $target_value_eth ETH"
    printf "  Current value   : %s ETH  (%.4f %s held)\n" "$current_value_eth" "$acc_token_human" "$TOKEN_LABEL"
    printf "  Deficit/Surplus : %+.8f ETH\n" "$deficit_eth"
    echo "  Avg entry cost  : $avg_cost ETH per $TOKEN_LABEL"

    # d) Buy if below target
    if awk_gt "$deficit_eth" "0"; then
        buy_eth=$(awk "BEGIN { printf \"%.8f\", ($deficit_eth < $MAX_BUY_PER_INTERVAL) ? $deficit_eth : $MAX_BUY_PER_INTERVAL }")

        if awk_lt "$buy_eth" "0.0001"; then
            echo -e "${GRAY}  Action          : SKIP (buy amount $buy_eth ETH below 0.0001 ETH dust limit)${RESET}"
            (( skipped_dust++ )) || true
        else
            echo -e "${CYAN}  Action          : BUY $buy_eth ETH of $TOKEN_LABEL${RESET}"

            if [[ "$DRY_RUN" == "1" ]]; then
                dry_buy_json=$(get_quote "eth" "$TOKEN" "$buy_eth" 2>&1) || true
                if [[ -n "${dry_buy_json:-}" ]]; then
                    dry_tok_raw=$(extract_buy_amount "$dry_buy_json" || echo "0")
                    dry_tok_h=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", ${dry_tok_raw:-0} / $TOKEN_SCALE }")
                    echo -e "${YELLOW}  [DRY-RUN] Would buy $dry_tok_h $TOKEN_LABEL for $buy_eth ETH${RESET}"
                    acc_token_human=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", $acc_token_human + $dry_tok_h }")
                    total_eth_spent=$(awk "BEGIN { printf \"%.8f\", $total_eth_spent + $buy_eth }")
                    (( total_buys++ )) || true
                fi
            else
                pre_buy_json=$(get_quote "eth" "$TOKEN" "$buy_eth" 2>&1) || {
                    echo "Warning: pre-buy quote failed on interval $interval -- skipping." >&2
                    continue
                }
                pre_tok_raw=$(extract_buy_amount "$pre_buy_json")
                [[ -z "$pre_tok_raw" ]] && { echo "Warning: empty token raw -- skipping." >&2; continue; }
                pre_tok_h=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", $pre_tok_raw / $TOKEN_SCALE }")

                echo -e "${CYAN}  >>> speed swap -c $CHAIN --sell eth --buy $TOKEN -a $buy_eth -y${RESET}"
                swap_out=$(speed --json --yes swap -c "$CHAIN" --sell eth --buy "$TOKEN" -a "$buy_eth" 2>&1)
                swap_json=$(echo "$swap_out" | grep -m1 '^{' || echo "")
                if echo "$swap_json" | grep -q '"error"'; then
                    err=$(echo "$swap_json" | grep -oP '"error"\s*:\s*"\K[^"]+' || echo "unknown")
                    echo "Warning: buy swap failed: $err -- skipping." >&2
                    continue
                fi
                tx_hash=$(echo "$swap_json" | grep -oP '"txHash"\s*:\s*"\K[^"]+' || echo "")
                [[ -n "$tx_hash" ]] && echo -e "${GRAY}  TX: $tx_hash${RESET}"

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
                echo -e "${MAGENTA}  Action          : SELL $sell_str $TOKEN_LABEL  (surplus: $surplus_eth ETH, ${sell_pct}% of position)${RESET}"

                if [[ "$DRY_RUN" == "1" ]]; then
                    dry_sell_json=$(get_quote "$TOKEN" "eth" "$sell_str" 2>&1) || true
                    if [[ -n "${dry_sell_json:-}" ]]; then
                        dry_eth2_raw=$(extract_buy_amount "$dry_sell_json" || echo "0")
                        dry_eth2=$(to_human_eth "${dry_eth2_raw:-0}")
                        echo -e "${YELLOW}  [DRY-RUN] Would sell $sell_str $TOKEN_LABEL for approx $dry_eth2 ETH${RESET}"
                        acc_token_human=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", $acc_token_human - $sell_human }")
                        total_eth_received=$(awk "BEGIN { printf \"%.8f\", $total_eth_received + $dry_eth2 }")
                        (( total_sells++ )) || true
                    fi
                else
                    echo -e "${CYAN}  >>> speed swap -c $CHAIN --sell $TOKEN --buy eth -a $sell_str -y${RESET}"
                    sell_out=$(speed --json --yes swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$sell_str" 2>&1)
                    sell_json=$(echo "$sell_out" | grep -m1 '^{' || echo "")
                    if echo "$sell_json" | grep -q '"error"'; then
                        err=$(echo "$sell_json" | grep -oP '"error"\s*:\s*"\K[^"]+' || echo "unknown")
                        echo "Warning: sell swap failed: $err -- skipping." >&2
                        continue
                    fi
                    tx_hash=$(echo "$sell_json" | grep -oP '"txHash"\s*:\s*"\K[^"]+' || echo "")
                    [[ -n "$tx_hash" ]] && echo -e "${GRAY}  TX: $tx_hash${RESET}"

                    # Estimate ETH received
                    check_json=$(get_quote "$TOKEN" "eth" "$sell_str" 2>&1) || true
                    if [[ -n "${check_json:-}" ]]; then
                        eth_rec_raw=$(extract_buy_amount "$check_json" || echo "0")
                        eth_rec=$(to_human_eth "${eth_rec_raw:-0}")
                        total_eth_received=$(awk "BEGIN { printf \"%.8f\", $total_eth_received + $eth_rec }")
                    fi

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
echo "  ETH spent          : $total_eth_spent ETH"
echo "  ETH received       : $total_eth_received ETH"

net_deployed=$(awk "BEGIN { printf \"%.8f\", $total_eth_spent - $total_eth_received }")
echo "  Net ETH deployed   : $net_deployed ETH"

if awk_gt "$acc_token_human" "0"; then
    acc_str=$(format_token "$acc_token_human" "$TOKEN_DECIMALS")
    echo "  Final position     : $acc_str $TOKEN_LABEL"
    if awk_gt "$total_eth_spent" "0"; then
        avg_cost=$(awk "BEGIN { printf \"%.8f\", $total_eth_spent / $acc_token_human }")
        echo "  Avg entry cost     : $avg_cost ETH per $TOKEN_LABEL"
    fi
    echo ""
    echo -e "${GRAY}  Position remains open. Use trailing-stop-any.sh or limit-order-any.sh to exit.${RESET}"
else
    echo -e "${GRAY}  Final position     : 0 (fully sold or nothing accumulated)${RESET}"
fi
