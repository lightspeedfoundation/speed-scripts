#!/usr/bin/env bash
# twap-buy-any.sh (v2) — parity with twap-buy-any.ps1
# TWAP buy: split -TotalAmount of -BaseToken (default speed) across N slices.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_common.sh
source "$SCRIPT_DIR/../_common.sh"

CHAIN=""
TOKEN=""
TOTAL_AMOUNT=""
TOKEN_SYMBOL=""
SLICES=5
INTERVAL_SECONDS=300
DRY_RUN=0
BASE_TOKEN="speed"
BASE_TOKEN_SYMBOL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chain)              CHAIN="$2";            shift 2 ;;
        --token)              TOKEN="$2";            shift 2 ;;
        --total-amount)       TOTAL_AMOUNT="$2";     shift 2 ;;
        --tokensymbol)        TOKEN_SYMBOL="$2";     shift 2 ;;
        --slices)             SLICES="$2";           shift 2 ;;
        --interval-seconds)   INTERVAL_SECONDS="$2"; shift 2 ;;
        --dry-run)            DRY_RUN=1;             shift ;;
        --base-token)         BASE_TOKEN="$2";       shift 2 ;;
        --base-token-symbol)  BASE_TOKEN_SYMBOL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$CHAIN" || -z "$TOKEN" || -z "$TOTAL_AMOUNT" ]]; then
    echo "Usage: $0 --chain <chain> --token <addr|alias> --total-amount <base> [--slices <n>] [--interval-seconds <s>] [--tokensymbol <name>] [--base-token speed|eth|0x...] [--base-token-symbol <sym>] [--dry-run]" >&2
    exit 1
fi

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GRAY='\033[0;90m'
RESET='\033[0m'

BASE_TOKEN="$(speed_v2_resolve_base_token "$TOKEN" "$BASE_TOKEN")"
BASE_DECIMALS=$(speed_v2_get_token_decimals "$BASE_TOKEN" "$CHAIN")
BASE_SCALE=$(awk "BEGIN { printf \"%.0f\", 10 ^ $BASE_DECIMALS }")
BASE_LABEL="$(speed_v2_base_label "$BASE_TOKEN_SYMBOL" "$BASE_TOKEN")"

TOKEN_LABEL="${TOKEN_SYMBOL:-$TOKEN}"

echo -e "${GRAY}Detecting token decimals...${RESET}"
TOKEN_DECIMALS=$(speed_v2_get_token_decimals "$TOKEN" "$CHAIN")
TOKEN_SCALE=$(awk "BEGIN { printf \"%.0f\", 10 ^ $TOKEN_DECIMALS }")

slice_eth=$(awk "BEGIN { printf \"%.18f\", $TOTAL_AMOUNT / $SLICES }")
# trim trailing zeros (ps1: ToString F18 TrimEnd)
slice_str=$(awk "BEGIN {
  s=sprintf(\"%.18f\", $TOTAL_AMOUNT / $SLICES);
  sub(/0+$/,\"\",s); sub(/\.$/,\"\",s);
  if (s !~ /\\./) s=sprintf(\"%.8f\", $TOTAL_AMOUNT / $SLICES);
  print s
}")
total_duration=$(( (SLICES - 1) * INTERVAL_SECONDS ))

if (( SLICES < 1 )); then echo "-Slices must be >= 1." >&2; exit 1; fi
if (( INTERVAL_SECONDS < 0 )); then echo "-IntervalSeconds must be >= 0." >&2; exit 1; fi

echo ""
echo -e "${YELLOW}=== Speed TWAP Buy ===${RESET}"
[[ "$DRY_RUN" == "1" ]] && echo -e "${YELLOW}  *** DRY-RUN MODE -- no buys will execute ***${RESET}"
echo "  Chain          : $CHAIN"
echo "  Token          : $TOKEN_LABEL  (decimals: $TOKEN_DECIMALS)"
echo "  Total base     : $TOTAL_AMOUNT $BASE_LABEL"
echo "  Slices         : $SLICES  ($slice_str $BASE_LABEL each)"
echo "  Interval       : $INTERVAL_SECONDS s between slices"
echo "  Total duration : $(( total_duration / 60 )) min  ($total_duration s)"
echo ""

prices=()
total_token_raw=0
failed_slices=0

for (( i=1; i<=SLICES; i++ )); do
    ts=$(date +"%H:%M:%S")
    echo -e "${CYAN}[$ts] Slice $i/$SLICES - quoting $slice_str $BASE_LABEL -> $TOKEN_LABEL...${RESET}"

    if ! slice_json=$(speed_v2_get_quote "$CHAIN" "$BASE_TOKEN" "$TOKEN" "$slice_str"); then
        echo "Warning: quote failed for slice $i — skipping." >&2
        (( failed_slices++ )) || true
        if (( i < SLICES && INTERVAL_SECONDS > 0 )); then sleep "$INTERVAL_SECONDS"; fi
        continue
    fi

    tok_raw=$(speed_v2_extract_buy_amount "$slice_json")
    if [[ -z "$tok_raw" ]]; then
        echo "Warning: empty buyAmount for slice $i — skipping." >&2
        (( failed_slices++ )) || true
        if (( i < SLICES && INTERVAL_SECONDS > 0 )); then sleep "$INTERVAL_SECONDS"; fi
        continue
    fi

    tok_human=$(awk "BEGIN { printf \"%.*f\", $TOKEN_DECIMALS, $tok_raw / $TOKEN_SCALE }")
    price=$(awk "BEGIN { if ($tok_human > 0) printf \"%.8f\", $slice_eth / $tok_human; else print 0 }")

    echo -e "${GRAY}         Quote: $tok_human $TOKEN_LABEL  (price: $price $BASE_LABEL/token)${RESET}"

    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "${YELLOW}         [DRY-RUN] Would BUY $slice_str $BASE_LABEL -> $tok_human $TOKEN_LABEL${RESET}"
        prices+=("$price")
        total_token_raw=$(awk "BEGIN { printf \"%.0f\", $total_token_raw + $tok_raw }")
    else
        echo -e "${CYAN}         >>> speed swap -c $CHAIN --sell $BASE_TOKEN --buy $TOKEN -a $slice_str -y${RESET}"
        if speed swap -c "$CHAIN" --sell "$BASE_TOKEN" --buy "$TOKEN" -a "$slice_str" -y; then
            act_raw="$tok_raw"
            act_human=$(awk "BEGIN { printf \"%.*f\", $TOKEN_DECIMALS, $act_raw / $TOKEN_SCALE }")
            act_price=$(awk "BEGIN { if ($act_human > 0) printf \"%.8f\", $slice_eth / $act_human; else print 0 }")
            prices+=("$act_price")
            total_token_raw=$(awk "BEGIN { printf \"%.0f\", $total_token_raw + $act_raw }")
            echo -e "${GREEN}         Slice $i complete. Got $act_human $TOKEN_LABEL.${RESET}"
        else
            echo "Warning: slice $i buy failed — skipping." >&2
            (( failed_slices++ )) || true
        fi
    fi

    if (( i < SLICES && INTERVAL_SECONDS > 0 )); then
        ts2=$(date +"%H:%M:%S")
        echo -e "${GRAY}[$ts2] Waiting $INTERVAL_SECONDS s before slice $(( i+1 ))...${RESET}"
        sleep "$INTERVAL_SECONDS"
    fi
done

echo ""
echo -e "${YELLOW}=== TWAP Buy Complete ===${RESET}"

success_slices=$(( SLICES - failed_slices ))
eth_spent=$(awk "BEGIN { printf \"%.8f\", $success_slices * $slice_eth }")
total_tok_human=$(awk "BEGIN { printf \"%.*f\", $TOKEN_DECIMALS, $total_token_raw / $TOKEN_SCALE }")

echo "  Slices completed : $success_slices / $SLICES"
echo "  Total base spent : $eth_spent $BASE_LABEL"
echo "  Total received   : $total_tok_human $TOKEN_LABEL"

if (( ${#prices[@]} > 0 )); then
    avg_price=$(printf '%s\n' "${prices[@]}" | awk '{sum+=$1; count++} END {printf "%.8f", sum/count}')
    min_price=$(printf '%s\n' "${prices[@]}" | sort -n | head -1)
    max_price=$(printf '%s\n' "${prices[@]}" | sort -n | tail -1)
    # Match PS1: display half of (max-min)/avg as ±% (see twap-buy-any.ps1 summary)
    variance=$(awk "BEGIN { if ($avg_price > 0) printf \"%.2f\", ($max_price - $min_price) / $avg_price * 100 / 2; else print 0 }")

    # Buy: lower base/token price is better (cheaper tokens)
    best_idx=1 worst_idx=1 idx=0
    best_p="$max_price" worst_p="$min_price"
    for p in "${prices[@]}"; do
        (( idx++ )) || true
        awk -v p="$p" -v bp="$best_p" 'BEGIN { exit (p < bp) ? 0 : 1 }' && { best_p="$p"; best_idx=$idx; }
        awk -v p="$p" -v wp="$worst_p" 'BEGIN { exit (p > wp) ? 0 : 1 }' && { worst_p="$p"; worst_idx=$idx; }
    done

    echo "  Average price    : $avg_price $BASE_LABEL/token"
    echo "  Price range      : $min_price to $max_price $BASE_LABEL/token"
    echo "  Variance         : +/-${variance}%"
    echo "  Best slice       : Slice $best_idx  ($best_p $BASE_LABEL/token)"
    echo "  Worst slice      : Slice $worst_idx  ($worst_p $BASE_LABEL/token)"
fi

if (( failed_slices > 0 )); then
    echo -e "${YELLOW}  WARNING: $failed_slices slice(s) failed — manual review required.${RESET}"
fi
