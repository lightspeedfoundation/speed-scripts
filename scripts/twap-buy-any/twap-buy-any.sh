#!/usr/bin/env bash
# twap-buy-any.sh
# TWAP buy: split a total ETH amount into N equal slices and execute one buy
# per --interval-seconds, regardless of price.
#
# Usage:
#   ./twap-buy-any.sh --chain base --token speed --total-amount 0.01 --slices 5 --interval-seconds 300
#   ./twap-buy-any.sh --chain base --token 0xcbB7... --tokensymbol cbBTC --total-amount 0.05 --slices 10 --interval-seconds 600
#   ./twap-buy-any.sh --chain base --token speed --total-amount 0.01 --slices 5 --dry-run

set -euo pipefail

# --- defaults -----------------------------------------------------------------

CHAIN=""
TOKEN=""
TOTAL_AMOUNT=""
TOKEN_SYMBOL=""
SLICES=5
INTERVAL_SECONDS=300
DRY_RUN=0

# --- arg parsing --------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chain)            CHAIN="$2";            shift 2 ;;
        --token)            TOKEN="$2";            shift 2 ;;
        --total-amount)     TOTAL_AMOUNT="$2";     shift 2 ;;
        --tokensymbol)      TOKEN_SYMBOL="$2";     shift 2 ;;
        --slices)           SLICES="$2";           shift 2 ;;
        --interval-seconds) INTERVAL_SECONDS="$2"; shift 2 ;;
        --dry-run)          DRY_RUN=1;             shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$CHAIN" || -z "$TOKEN" || -z "$TOTAL_AMOUNT" ]]; then
    echo "Usage: $0 --chain <chain> --token <addr|alias> --total-amount <eth> [--slices <n>] [--interval-seconds <s>] [--tokensymbol <name>] [--dry-run]" >&2
    exit 1
fi

# --- colours ------------------------------------------------------------------

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GRAY='\033[0;90m'
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

awk_gt() { awk "BEGIN { exit ($1 > $2) ? 0 : 1 }"; }

# --- setup --------------------------------------------------------------------

TOKEN_LABEL="${TOKEN_SYMBOL:-$TOKEN}"

echo -e "${GRAY}Detecting token decimals...${RESET}"
TOKEN_DECIMALS=$(get_token_decimals "$TOKEN" "$CHAIN")
TOKEN_SCALE=$(awk "BEGIN { printf \"%.0f\", 10 ^ $TOKEN_DECIMALS }")

slice_eth=$(awk "BEGIN { printf \"%.8f\", $TOTAL_AMOUNT / $SLICES }")
total_duration=$(( (SLICES - 1) * INTERVAL_SECONDS ))

echo ""
echo -e "${YELLOW}=== Speed TWAP Buy ===${RESET}"
[[ "$DRY_RUN" == "1" ]] && echo -e "${YELLOW}  *** DRY-RUN MODE -- no buys will execute ***${RESET}"
echo "  Chain          : $CHAIN"
echo "  Token          : $TOKEN_LABEL  (decimals: $TOKEN_DECIMALS)"
echo "  Total ETH      : $TOTAL_AMOUNT ETH"
echo "  Slices         : $SLICES  ($slice_eth ETH each)"
echo "  Interval       : $INTERVAL_SECONDS s between slices"
echo "  Total duration : $(( total_duration / 60 )) min  ($total_duration s)"
echo ""

# --- execution loop -----------------------------------------------------------

prices=()
token_totals=()
total_token_raw=0
failed_slices=0
success_slices=0

for (( i=1; i<=SLICES; i++ )); do
    ts=$(date +"%H:%M:%S")
    echo -e "${CYAN}[$ts] Slice $i/$SLICES — quoting $slice_eth ETH -> $TOKEN_LABEL...${RESET}"

    slice_json=$(get_quote "eth" "$TOKEN" "$slice_eth" 2>&1) || {
        echo "Warning: quote failed for slice $i — skipping."
        (( failed_slices++ )) || true
        if (( i < SLICES && INTERVAL_SECONDS > 0 )); then sleep "$INTERVAL_SECONDS"; fi
        continue
    }

    tok_raw=$(extract_buy_amount "$slice_json")
    if [[ -z "$tok_raw" ]]; then
        echo "Warning: empty buyAmount for slice $i — skipping."
        (( failed_slices++ )) || true
        if (( i < SLICES && INTERVAL_SECONDS > 0 )); then sleep "$INTERVAL_SECONDS"; fi
        continue
    fi

    tok_human=$(awk "BEGIN { printf \"%.*f\", $TOKEN_DECIMALS, $tok_raw / $TOKEN_SCALE }")
    price=$(awk "BEGIN { if ($tok_human > 0) printf \"%.8f\", $slice_eth / $tok_human; else print 0 }")

    echo -e "${GRAY}         Quote: $tok_human $TOKEN_LABEL  (price: $price ETH/token)${RESET}"

    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "${YELLOW}         [DRY-RUN] Would BUY $slice_eth ETH -> $tok_human $TOKEN_LABEL${RESET}"
        prices+=("$price")
        token_totals+=("$tok_raw")
        total_token_raw=$(awk "BEGIN { printf \"%.0f\", $total_token_raw + $tok_raw }")
        (( success_slices++ )) || true
    else
        echo -e "${CYAN}         >>> speed swap -c $CHAIN --sell eth --buy $TOKEN -a $slice_eth -y${RESET}"
        if speed swap -c "$CHAIN" --sell eth --buy "$TOKEN" -a "$slice_eth" -y; then
            prices+=("$price")
            token_totals+=("$tok_raw")
            total_token_raw=$(awk "BEGIN { printf \"%.0f\", $total_token_raw + $tok_raw }")
            (( success_slices++ )) || true
            echo -e "${GREEN}         Slice $i complete. Got ~$tok_human $TOKEN_LABEL.${RESET}"
        else
            echo "Warning: slice $i buy failed — skipping."
            (( failed_slices++ )) || true
        fi
    fi

    if (( i < SLICES && INTERVAL_SECONDS > 0 )); then
        ts2=$(date +"%H:%M:%S")
        echo -e "${GRAY}[$ts2] Waiting $INTERVAL_SECONDS s before slice $(( i+1 ))...${RESET}"
        sleep "$INTERVAL_SECONDS"
    fi
done

# --- summary ------------------------------------------------------------------

echo ""
echo -e "${YELLOW}=== TWAP Buy Complete ===${RESET}"

eth_spent=$(awk "BEGIN { printf \"%.8f\", $success_slices * $slice_eth }")
total_tok_human=$(awk "BEGIN { printf \"%.*f\", $TOKEN_DECIMALS, $total_token_raw / $TOKEN_SCALE }")

echo "  Slices completed : $success_slices / $SLICES"
echo "  Total ETH spent  : $eth_spent ETH"
echo "  Total received   : $total_tok_human $TOKEN_LABEL"

if (( ${#prices[@]} > 0 )); then
    avg_price=$(printf '%s\n' "${prices[@]}" | awk '{sum+=$1; count++} END {printf "%.8f", sum/count}')
    min_price=$(printf '%s\n' "${prices[@]}" | sort -n | head -1)
    max_price=$(printf '%s\n' "${prices[@]}" | sort -n | tail -1)
    variance=$(awk "BEGIN { if ($avg_price > 0) printf \"%.2f\", ($max_price - $min_price) / $avg_price * 100 / 2; else print 0 }")

    echo "  Average price    : $avg_price ETH/token"
    echo "  Price range      : $min_price – $max_price ETH/token"
    echo "  Variance         : ±${variance}%"
fi

if (( failed_slices > 0 )); then
    echo -e "${YELLOW}  WARNING: $failed_slices slice(s) failed — manual review required.${RESET}"
fi
