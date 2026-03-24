#!/usr/bin/env bash
# twap-sell-any.sh (v2) — parity with twap-sell-any.ps1
# TWAP sell: sell a token in N equal slices; proceeds in -BaseToken (default: speed).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_common.sh
source "$SCRIPT_DIR/../_common.sh"

CHAIN=""
TOKEN=""
TOKEN_AMOUNT=""
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
        --token-amount)       TOKEN_AMOUNT="$2";     shift 2 ;;
        --tokensymbol)        TOKEN_SYMBOL="$2";     shift 2 ;;
        --slices)             SLICES="$2";           shift 2 ;;
        --interval-seconds)   INTERVAL_SECONDS="$2"; shift 2 ;;
        --dry-run)            DRY_RUN=1;             shift ;;
        --base-token)         BASE_TOKEN="$2";       shift 2 ;;
        --base-token-symbol)  BASE_TOKEN_SYMBOL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$CHAIN" || -z "$TOKEN" || -z "$TOKEN_AMOUNT" ]]; then
    echo "Usage: $0 --chain <chain> --token <addr|alias> --token-amount <amt> [--slices <n>] [--interval-seconds <s>] [--tokensymbol <name>] [--base-token speed|eth|0x...] [--base-token-symbol <sym>] [--dry-run]" >&2
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
slice_amount=$(awk "BEGIN { printf \"%.*f\", $TOKEN_DECIMALS, $TOKEN_AMOUNT / $SLICES }")

if awk -v s="$slice_amount" 'BEGIN { exit (s + 0 <= 0) ? 0 : 1 }'; then
    echo "Slice amount resolved to 0. Check --token-amount and --slices." >&2
    exit 1
fi

if (( SLICES < 1 )); then echo "-Slices must be >= 1." >&2; exit 1; fi
if (( INTERVAL_SECONDS < 0 )); then echo "-IntervalSeconds must be >= 0." >&2; exit 1; fi

total_duration=$(( (SLICES - 1) * INTERVAL_SECONDS ))

echo ""
echo -e "${YELLOW}=== Speed TWAP Sell ===${RESET}"
[[ "$DRY_RUN" == "1" ]] && echo -e "${YELLOW}  *** DRY-RUN MODE -- no sells will execute ***${RESET}"
echo "  Chain          : $CHAIN"
echo "  Token          : $TOKEN_LABEL  (decimals: $TOKEN_DECIMALS)"
echo "  Total to sell  : $TOKEN_AMOUNT $TOKEN_LABEL"
echo "  Slices         : $SLICES  ($slice_amount $TOKEN_LABEL each)"
echo "  Interval       : $INTERVAL_SECONDS s between slices"
echo "  Total duration : $(( total_duration / 60 )) min  ($total_duration s)"
echo ""

prices=()
failed_slices=0
total_base_raw=0

for (( i=1; i<=SLICES; i++ )); do
    ts=$(date +"%H:%M:%S")
    echo -e "${CYAN}[$ts] Slice $i/$SLICES - quoting $slice_amount $TOKEN_LABEL -> $BASE_LABEL...${RESET}"

    if ! slice_json=$(speed_v2_get_quote "$CHAIN" "$TOKEN" "$BASE_TOKEN" "$slice_amount"); then
        echo "Warning: quote failed for slice $i — skipping." >&2
        (( failed_slices++ )) || true
        if (( i < SLICES && INTERVAL_SECONDS > 0 )); then sleep "$INTERVAL_SECONDS"; fi
        continue
    fi

    raw=$(speed_v2_extract_buy_amount "$slice_json")
    if [[ -z "$raw" ]]; then
        echo "Warning: empty buyAmount for slice $i — skipping." >&2
        (( failed_slices++ )) || true
        if (( i < SLICES && INTERVAL_SECONDS > 0 )); then sleep "$INTERVAL_SECONDS"; fi
        continue
    fi

    base_back=$(awk "BEGIN { printf \"%.8f\", $raw / $BASE_SCALE }")
    price=$(awk "BEGIN { if ($slice_amount > 0) printf \"%.8f\", $base_back / $slice_amount; else print 0 }")

    echo -e "${GRAY}         Quote: $base_back $BASE_LABEL  (price: $price $BASE_LABEL/token)${RESET}"

    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "${YELLOW}         [DRY-RUN] Would SELL $slice_amount $TOKEN_LABEL -> $base_back $BASE_LABEL${RESET}"
        prices+=("$price")
        total_base_raw=$(awk "BEGIN { printf \"%.0f\", $total_base_raw + $raw }")
    else
        echo -e "${CYAN}         >>> speed swap -c $CHAIN --sell $TOKEN --buy $BASE_TOKEN -a $slice_amount -y${RESET}"
        if speed swap -c "$CHAIN" --sell "$TOKEN" --buy "$BASE_TOKEN" -a "$slice_amount" -y; then
            prices+=("$price")
            total_base_raw=$(awk "BEGIN { printf \"%.0f\", $total_base_raw + $raw }")
            echo -e "${GREEN}         Slice $i complete. Got $base_back $BASE_LABEL.${RESET}"
        else
            echo "Warning: slice $i sell failed — skipping." >&2
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
echo -e "${YELLOW}=== TWAP Sell Complete ===${RESET}"

success_slices=$(( SLICES - failed_slices ))
total_base_received=$(awk "BEGIN { printf \"%.8f\", $total_base_raw / $BASE_SCALE }")
# Match PS1: successSlices * (TokenAmount / Slices)
total_tok_sold=$(awk -v t="$TOKEN_AMOUNT" -v ss="$success_slices" -v sl="$SLICES" -v d="$TOKEN_DECIMALS" \
    'BEGIN { printf "%.*f", d, t * ss / sl }')

echo "  Slices completed  : $success_slices / $SLICES"
echo "  Total tokens sold : $total_tok_sold $TOKEN_LABEL"
echo "  Total base received: $total_base_received $BASE_LABEL"

if (( ${#prices[@]} > 0 )); then
    avg_price=$(printf '%s\n' "${prices[@]}" | awk '{sum+=$1; count++} END {printf "%.8f", sum/count}')
    min_price=$(printf '%s\n' "${prices[@]}" | sort -n | head -1)
    max_price=$(printf '%s\n' "${prices[@]}" | sort -n | tail -1)

    # Sell: higher base/token = better slice (match PS1 Sort-Object P -Descending / ascending)
    first_p="${prices[0]}"
    best_p="$first_p" worst_p="$first_p" best_idx=1 worst_idx=1 idx=0
    for p in "${prices[@]}"; do
        (( idx++ )) || true
        awk -v p="$p" -v bp="$best_p" 'BEGIN { exit (p > bp) ? 0 : 1 }' && { best_p="$p"; best_idx=$idx; }
        awk -v p="$p" -v wp="$worst_p" 'BEGIN { exit (p < wp) ? 0 : 1 }' && { worst_p="$p"; worst_idx=$idx; }
    done

    echo "  Average price     : $avg_price $BASE_LABEL/token"
    echo "  Price range       : $min_price to $max_price $BASE_LABEL/token"
    echo "  Best slice        : Slice $best_idx  ($best_p $BASE_LABEL/token)"
    echo "  Worst slice       : Slice $worst_idx  ($worst_p $BASE_LABEL/token)"
fi

if (( failed_slices > 0 )); then
    echo -e "${YELLOW}  WARNING: $failed_slices slice(s) failed — check wallet balance for unsold tokens.${RESET}"
fi
