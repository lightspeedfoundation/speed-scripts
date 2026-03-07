#!/usr/bin/env bash
# twap-sell-any.sh
# TWAP sell: sell an existing token position in N equal slices over time.
# Pure exit tool — no initial buy required.
#
# Usage:
#   ./twap-sell-any.sh --chain base --token speed --token-amount 98000 --slices 5 --interval-seconds 300
#   ./twap-sell-any.sh --chain base --token 0xcbB7... --tokensymbol cbBTC --token-amount 0.00002287 --slices 5 --interval-seconds 600
#   ./twap-sell-any.sh --chain base --token speed --token-amount 50000 --slices 5 --dry-run

set -euo pipefail

# --- defaults -----------------------------------------------------------------

CHAIN=""
TOKEN=""
TOKEN_AMOUNT=""
TOKEN_SYMBOL=""
SLICES=5
INTERVAL_SECONDS=300
DRY_RUN=0

# --- arg parsing --------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chain)            CHAIN="$2";            shift 2 ;;
        --token)            TOKEN="$2";            shift 2 ;;
        --token-amount)     TOKEN_AMOUNT="$2";     shift 2 ;;
        --tokensymbol)      TOKEN_SYMBOL="$2";     shift 2 ;;
        --slices)           SLICES="$2";           shift 2 ;;
        --interval-seconds) INTERVAL_SECONDS="$2"; shift 2 ;;
        --dry-run)          DRY_RUN=1;             shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$CHAIN" || -z "$TOKEN" || -z "$TOKEN_AMOUNT" ]]; then
    echo "Usage: $0 --chain <chain> --token <addr|alias> --token-amount <amount> [--slices <n>] [--interval-seconds <s>] [--tokensymbol <name>] [--dry-run]" >&2
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

# --- setup --------------------------------------------------------------------

TOKEN_LABEL="${TOKEN_SYMBOL:-$TOKEN}"

echo -e "${GRAY}Detecting token decimals...${RESET}"
TOKEN_DECIMALS=$(get_token_decimals "$TOKEN" "$CHAIN")
TOKEN_SCALE=$(awk "BEGIN { printf \"%.0f\", 10 ^ $TOKEN_DECIMALS }")

slice_amount=$(awk "BEGIN { printf \"%.*f\", $TOKEN_DECIMALS, $TOKEN_AMOUNT / $SLICES }")
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

# --- execution loop -----------------------------------------------------------

prices=()
eth_totals=()
total_eth_raw=0
failed_slices=0
success_slices=0

for (( i=1; i<=SLICES; i++ )); do
    ts=$(date +"%H:%M:%S")
    echo -e "${CYAN}[$ts] Slice $i/$SLICES — quoting $slice_amount $TOKEN_LABEL -> ETH...${RESET}"

    slice_json=$(get_quote "$TOKEN" "eth" "$slice_amount" 2>&1) || {
        echo "Warning: quote failed for slice $i — skipping."
        (( failed_slices++ )) || true
        if (( i < SLICES && INTERVAL_SECONDS > 0 )); then sleep "$INTERVAL_SECONDS"; fi
        continue
    }

    eth_raw=$(extract_buy_amount "$slice_json")
    if [[ -z "$eth_raw" ]]; then
        echo "Warning: empty buyAmount for slice $i — skipping."
        (( failed_slices++ )) || true
        if (( i < SLICES && INTERVAL_SECONDS > 0 )); then sleep "$INTERVAL_SECONDS"; fi
        continue
    fi

    eth_back=$(awk "BEGIN { printf \"%.8f\", $eth_raw / $ETH_SCALE }")
    price=$(awk "BEGIN { if ($slice_amount > 0) printf \"%.8f\", $eth_back / $slice_amount; else print 0 }")

    echo -e "${GRAY}         Quote: $eth_back ETH  (price: $price ETH/token)${RESET}"

    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "${YELLOW}         [DRY-RUN] Would SELL $slice_amount $TOKEN_LABEL -> $eth_back ETH${RESET}"
        prices+=("$price")
        eth_totals+=("$eth_back")
        total_eth_raw=$(awk "BEGIN { printf \"%.0f\", $total_eth_raw + $eth_raw }")
        (( success_slices++ )) || true
    else
        echo -e "${CYAN}         >>> speed swap -c $CHAIN --sell $TOKEN --buy eth -a $slice_amount -y${RESET}"
        if speed swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$slice_amount" -y; then
            prices+=("$price")
            eth_totals+=("$eth_back")
            total_eth_raw=$(awk "BEGIN { printf \"%.0f\", $total_eth_raw + $eth_raw }")
            (( success_slices++ )) || true
            echo -e "${GREEN}         Slice $i complete. Got $eth_back ETH.${RESET}"
        else
            echo "Warning: slice $i sell failed — skipping."
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
echo -e "${YELLOW}=== TWAP Sell Complete ===${RESET}"

total_eth_received=$(awk "BEGIN { printf \"%.8f\", $total_eth_raw / $ETH_SCALE }")
total_tok_sold=$(awk "BEGIN { printf \"%.*f\", $TOKEN_DECIMALS, $success_slices * $slice_amount }")

echo "  Slices completed  : $success_slices / $SLICES"
echo "  Total tokens sold : $total_tok_sold $TOKEN_LABEL"
echo "  Total ETH received: $total_eth_received ETH"

if (( ${#prices[@]} > 0 )); then
    avg_price=$(printf '%s\n' "${prices[@]}" | awk '{sum+=$1; count++} END {printf "%.8f", sum/count}')
    min_price=$(printf '%s\n' "${prices[@]}" | sort -n | head -1)
    max_price=$(printf '%s\n' "${prices[@]}" | sort -n | tail -1)

    best_idx=1; worst_idx=1; idx=0
    best_p="$min_price"; worst_p="$max_price"
    for p in "${prices[@]}"; do
        (( idx++ )) || true
        if awk "BEGIN { exit ($p >= $max_price) ? 0 : 1 }"; then best_p="$p"; best_idx=$idx; fi
        if awk "BEGIN { exit ($p <= $min_price) ? 0 : 1 }"; then worst_p="$p"; worst_idx=$idx; fi
    done

    echo "  Average price     : $avg_price ETH/token"
    echo "  Price range       : $min_price – $max_price ETH/token"
    echo "  Best slice        : Slice $best_idx  ($best_p ETH/token)"
    echo "  Worst slice       : Slice $worst_idx  ($worst_p ETH/token)"
fi

if (( failed_slices > 0 )); then
    echo -e "${YELLOW}  WARNING: $failed_slices slice(s) failed — check wallet balance for unsold tokens.${RESET}"
fi
