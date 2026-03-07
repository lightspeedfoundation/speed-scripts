#!/usr/bin/env bash
# grid-trade-any.sh
#
# Grid trading bot: place N buy levels below current price, sell each when
# price recovers one grid step. Profits from price oscillation.
#
# DESCRIPTION
#   1. Auto-detects token decimals via on-chain RPC call.
#   2. Quotes --eth-per-grid ETH -> TOKEN to get refTokenAmount and basePrice.
#   3. Builds --levels grid cells below current price, spaced --grid-pct % apart.
#        Cell i:  buy_level  = basePrice * (1 - (i+1) * grid_pct/100)
#                 sell_level = basePrice * (1 - i     * grid_pct/100)
#   4. Polls every --poll-seconds seconds:
#        - Processes sells first  (cells where currentPrice >= sell_level)
#        - Then processes buys    (pending cells where currentPrice <= buy_level)
#        - Highest buy levels fill first (closest to current price)
#   5. Prints live grid status table and running P/L after each poll.
#   6. On --max-iterations: sells all filled cells and exits.
#
# USAGE
#   ./grid-trade-any.sh --chain base --token speed \
#     --eth-per-grid 0.001 --levels 5 --grid-pct 2
#
#   ./grid-trade-any.sh --chain base \
#     --token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
#     --token-symbol cbBTC --eth-per-grid 0.002 --levels 3 --grid-pct 1.5 \
#     --poll-seconds 30 --dry-run
#
# REQUIREMENTS
#   speed CLI on PATH, curl, awk, bc

set -euo pipefail

# -- defaults -----------------------------------------------------------------
CHAIN=""
TOKEN=""
ETH_PER_GRID=""
LEVELS=""
GRID_PCT=""
TOKEN_SYMBOL=""
POLL_SECONDS=60
MAX_ITERATIONS=2880
DRY_RUN=0

# -- argument parsing ---------------------------------------------------------
usage() {
    grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -40
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chain)          CHAIN="$2";          shift 2 ;;
        --token)          TOKEN="$2";          shift 2 ;;
        --eth-per-grid)   ETH_PER_GRID="$2";   shift 2 ;;
        --levels)         LEVELS="$2";         shift 2 ;;
        --grid-pct)       GRID_PCT="$2";       shift 2 ;;
        --token-symbol)   TOKEN_SYMBOL="$2";   shift 2 ;;
        --poll-seconds)   POLL_SECONDS="$2";   shift 2 ;;
        --max-iterations) MAX_ITERATIONS="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=1;           shift   ;;
        --help|-h)        usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

for req in CHAIN TOKEN ETH_PER_GRID LEVELS GRID_PCT; do
    [[ -z "${!req}" ]] && { echo "Error: --${req//_/-} is required." >&2; exit 1; }
done

TOKEN_LABEL="${TOKEN_SYMBOL:-$TOKEN}"

# -- RPC endpoints ------------------------------------------------------------
get_rpc() {
    case "${1,,}" in
        base|8453)               echo "https://mainnet.base.org" ;;
        ethereum|mainnet|eth|1)  echo "https://eth.llamarpc.com" ;;
        optimism|op|10)          echo "https://mainnet.optimism.io" ;;
        arbitrum|arb|42161)      echo "https://arb1.arbitrum.io/rpc" ;;
        polygon|matic|137)       echo "https://polygon.llamarpc.com" ;;
        bnb|bsc|56)              echo "https://bsc-dataseed.binance.org" ;;
        *) echo "" ;;
    esac
}

# -- P/L accumulators ---------------------------------------------------------
total_eth_spent=0
total_eth_received=0
total_buys=0
total_sells=0

# -- grid state (parallel indexed arrays, 0-based) ----------------------------
grid_buy_level=()    # raw wei-scale integer strings
grid_sell_level=()
grid_status=()       # "pending_buy" | "filled"
grid_token_held=()   # human-unit string
grid_eth_spent_cell=() # human ETH string per cell

# -- helpers ------------------------------------------------------------------

get_token_decimals() {
    local token="$1" chain="$2"
    local lower="${token,,}"
    [[ "$lower" =~ ^(speed|eth|ether|native)$ ]] && echo 18 && return
    [[ "$lower" != 0x* ]] && echo 18 && return

    local rpc
    rpc=$(get_rpc "$chain")
    [[ -z "$rpc" ]] && echo 18 && return

    local body="{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$token\",\"data\":\"0x313ce567\"},\"latest\"],\"id\":1}"
    local resp hex
    resp=$(curl -sf -X POST "$rpc" -H "Content-Type: application/json" -d "$body" 2>/dev/null) || { echo 18; return; }
    hex=$(echo "$resp" | grep -oP '"result"\s*:\s*"\K[^"]+' | sed 's/^0x//' | sed 's/^0*//')
    [[ -z "$hex" ]] && echo 18 && return
    echo "obase=10; ibase=16; ${hex^^}" | bc 2>/dev/null || echo 18
}

get_quote() {
    local sell_tok="$1" buy_tok="$2" sell_amt="$3"
    local output json
    output=$(speed quote --json -c "$CHAIN" --sell "$sell_tok" --buy "$buy_tok" -a "$sell_amt" 2>&1)
    json=$(echo "$output" | grep -m1 '^{')
    [[ -z "$json" ]] && { echo "No JSON from quote. Output: $output" >&2; return 1; }
    echo "$json" | grep -q '"error"' && {
        local err; err=$(echo "$json" | grep -oP '"error"\s*:\s*"\K[^"]+')
        echo "Quote error: $err" >&2; return 1
    }
    echo "$json"
}

extract_field() {
    local json="$1" field="$2"
    echo "$json" | grep -oP "\"$field\"\s*:\s*\"\K[^\"]+|\"$field\"\s*:\s*\K[0-9.]+" | head -1
}

# awk-based float comparison: returns 0 (true) if $1 >= $2
awk_gte() { awk "BEGIN { exit ($1 >= $2) ? 0 : 1 }"; }
# awk-based float comparison: returns 0 (true) if $1 <= $2
awk_lte() { awk "BEGIN { exit ($1 <= $2) ? 0 : 1 }"; }

# Format a raw integer (as float string) divided by scale to F{decimals} plain decimal
fmt_token() {
    local raw="$1" scale="$2" decimals="$3"
    awk "BEGIN { printf \"%.*f\", $decimals, $raw / $scale }"
}

fmt_eth() {
    local raw="$1"
    awk "BEGIN { printf \"%.8f\", $raw / 1e18 }"
}

invoke_buy() {
    local eth_amount="$1" cell_idx="$2"

    local q_json buy_raw token_human token_str
    q_json=$(get_quote "eth" "$TOKEN" "$eth_amount") || { echo "Quote failed for buy cell $cell_idx" >&2; return 1; }
    buy_raw=$(extract_field "$q_json" "buyAmount")
    token_human=$(awk "BEGIN { printf \"%.*f\", $TOKEN_DECIMALS, $buy_raw / $TOKEN_SCALE }")
    token_str="$token_human"

    if awk "BEGIN { exit ($token_str > 0) ? 0 : 1 }" 2>/dev/null; then
        :
    else
        echo "Token amount resolved to 0 for cell $cell_idx" >&2; return 1
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  [DRY-RUN] Cell $cell_idx: would BUY $token_str $TOKEN_LABEL for $eth_amount ETH" >&2
    else
        echo "  >>> Cell $cell_idx BUY: speed swap -c $CHAIN --sell eth --buy $TOKEN -a $eth_amount -y" >&2
        local raw_out json_out tx_hash
        raw_out=$(speed --json --yes swap -c "$CHAIN" --sell eth --buy "$TOKEN" -a "$eth_amount" 2>&1)
        json_out=$(echo "$raw_out" | grep -m1 '^{')
        if echo "$json_out" | grep -q '"error"'; then
            local err; err=$(extract_field "$json_out" "error")
            echo "Buy swap failed: $err" >&2; return 1
        fi
        tx_hash=$(extract_field "$json_out" "txHash")
        echo "  TX: $tx_hash" >&2
    fi

    total_eth_spent=$(awk "BEGIN { printf \"%.8f\", $total_eth_spent + $eth_amount }")
    (( total_buys++ )) || true
    echo "$token_str"
}

invoke_sell() {
    local token_amount="$1" cell_idx="$2"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  [DRY-RUN] Cell $cell_idx: would SELL $token_amount $TOKEN_LABEL -> ETH" >&2
        local q_json eth_back
        q_json=$(get_quote "$TOKEN" "eth" "$token_amount" 2>/dev/null) || true
        if [[ -n "$q_json" ]]; then
            local eth_raw; eth_raw=$(extract_field "$q_json" "buyAmount")
            eth_back=$(awk "BEGIN { printf \"%.8f\", $eth_raw / 1e18 }")
            total_eth_received=$(awk "BEGIN { printf \"%.8f\", $total_eth_received + $eth_back }")
        fi
    else
        echo "  >>> Cell $cell_idx SELL: speed swap -c $CHAIN --sell $TOKEN --buy eth -a $token_amount -y" >&2
        local raw_out json_out tx_hash
        raw_out=$(speed --json --yes swap -c "$CHAIN" --sell "$TOKEN" --buy eth -a "$token_amount" 2>&1)
        json_out=$(echo "$raw_out" | grep -m1 '^{')
        if echo "$json_out" | grep -q '"error"'; then
            local err; err=$(extract_field "$json_out" "error")
            echo "Sell swap failed: $err" >&2; return 1
        fi
        tx_hash=$(extract_field "$json_out" "txHash")
        echo "  TX: $tx_hash" >&2

        # Estimate ETH received via quote for P/L display
        local q_json2 eth_raw eth_back
        q_json2=$(get_quote "$TOKEN" "eth" "$token_amount" 2>/dev/null) || true
        if [[ -n "$q_json2" ]]; then
            eth_raw=$(extract_field "$q_json2" "buyAmount")
            eth_back=$(awk "BEGIN { printf \"%.8f\", $eth_raw / 1e18 }")
            total_eth_received=$(awk "BEGIN { printf \"%.8f\", $total_eth_received + $eth_back }")
        fi
    fi

    (( total_sells++ )) || true
}

show_grid() {
    local current_eth="$1" base_eth="$2"
    local ts pl pl_sign pct_from_base

    ts=$(date +"%H:%M:%S")
    pct_from_base=$(awk "BEGIN { printf \"%+.2f\", (($current_eth - $base_eth) / $base_eth) * 100 }")
    pl=$(awk "BEGIN { printf \"%.8f\", $total_eth_received - $total_eth_spent }")
    pl_sign=$(awk "BEGIN { print ($pl >= 0) ? \"+\" : \"\" }")

    echo ""
    echo "[$ts] Price: ${current_eth} ETH  (base: ${base_eth}, ${pct_from_base}%)  Buys: $total_buys  Sells: $total_sells"
    echo "          P/L: ${pl_sign}${pl} ETH   Spent: ${total_eth_spent} ETH   Received: ${total_eth_received} ETH"
    echo ""
    printf "  %-3s  %-14s  %-14s  %-12s  %-22s  %s\n" \
        "#" "Buy Level ETH" "Sell Level ETH" "Status" "Token Held" "ETH Spent"
    printf "  %-3s  %-14s  %-14s  %-12s  %-22s  %s\n" \
        "-" "--------------" "--------------" "------------" "----------------------" "---------"

    local i
    for (( i=0; i<LEVELS; i++ )); do
        local buy_eth sell_eth status_str held_str spent_str dist_pct
        buy_eth=$(fmt_eth "${grid_buy_level[$i]}")
        sell_eth=$(fmt_eth "${grid_sell_level[$i]}")

        if [[ "${grid_status[$i]}" == "filled" ]]; then
            status_str="FILLED  *"
            held_str="${grid_token_held[$i]} $TOKEN_LABEL"
            spent_str="${grid_eth_spent_cell[$i]}"
        else
            status_str="waiting"
            held_str="-"
            spent_str="-"
        fi

        printf "  %-3s  %-14s  %-14s  %-12s  %-22s  %s\n" \
            "$i" "$buy_eth" "$sell_eth" "$status_str" "$held_str" "$spent_str"
    done
    echo ""
}

# -- setup --------------------------------------------------------------------

echo ""
echo "Detecting token decimals..." >&2
TOKEN_DECIMALS=$(get_token_decimals "$TOKEN" "$CHAIN")
TOKEN_SCALE=$(awk "BEGIN { printf \"%.0f\", 10^$TOKEN_DECIMALS }")

echo ""
echo "=== Speed Grid Trading Bot ==="
[[ "$DRY_RUN" -eq 1 ]] && echo "  *** DRY-RUN MODE -- no swaps will execute ***"
echo "  Chain         : $CHAIN"
echo "  Token         : $TOKEN_LABEL  (decimals: $TOKEN_DECIMALS)"
echo "  ETH per grid  : $ETH_PER_GRID ETH"
echo "  Grid levels   : $LEVELS"
echo "  Grid spacing  : $GRID_PCT %"
max_outlay=$(awk "BEGIN { printf \"%.8f\", $ETH_PER_GRID * $LEVELS }")
echo "  Max ETH outlay: $max_outlay ETH (if all levels fill)"
echo "  Poll interval : $POLL_SECONDS s"
echo "  Max polls     : $MAX_ITERATIONS"
echo ""

# Step 1: quote ETH_PER_GRID ETH -> TOKEN to get reference amount
echo "Step 1 - Quoting $ETH_PER_GRID ETH -> $TOKEN_LABEL to get reference amount..."
buy_q=$(get_quote "eth" "$TOKEN" "$ETH_PER_GRID") || { echo "Initial buy quote failed." >&2; exit 1; }
ref_token_raw=$(extract_field "$buy_q" "buyAmount")
ref_token_str=$(awk "BEGIN { printf \"%.*f\", $TOKEN_DECIMALS, $ref_token_raw / $TOKEN_SCALE }")

if awk "BEGIN { exit ($ref_token_str > 0) ? 0 : 1 }" 2>/dev/null; then
    :
else
    echo "Reference token amount resolved to 0. Aborting." >&2; exit 1
fi
echo "  Reference amount : $ref_token_str $TOKEN_LABEL (per $ETH_PER_GRID ETH grid)"

# Step 2: quote refTokenAmount TOKEN -> ETH to establish basePrice
echo ""
echo "Step 2 - Quoting $TOKEN_LABEL -> ETH to establish base price..."
sell_q=$(get_quote "$TOKEN" "eth" "$ref_token_str") || { echo "Initial sell quote failed." >&2; exit 1; }
base_raw=$(extract_field "$sell_q" "buyAmount")
base_eth=$(fmt_eth "$base_raw")
echo "  Base price : $base_eth ETH (for $ref_token_str $TOKEN_LABEL)"
echo ""

# Step 3: build grid arrays
echo "Step 3 - Building grid..."
for (( i=0; i<LEVELS; i++ )); do
    buy_raw_f=$(awk  "BEGIN { printf \"%.0f\", $base_raw * (1 - ($i + 1) * $GRID_PCT / 100) }")
    sell_raw_f=$(awk "BEGIN { printf \"%.0f\", $base_raw * (1 - $i       * $GRID_PCT / 100) }")
    grid_buy_level+=("$buy_raw_f")
    grid_sell_level+=("$sell_raw_f")
    grid_status+=("pending_buy")
    grid_token_held+=("")
    grid_eth_spent_cell+=("0")

    buy_eth_disp=$(fmt_eth "$buy_raw_f")
    sell_eth_disp=$(fmt_eth "$sell_raw_f")
    echo "  Cell $i: buy at or below $buy_eth_disp ETH  |  sell at or above $sell_eth_disp ETH"
done
echo ""

show_grid "$base_eth" "$base_eth"

# -- poll loop ----------------------------------------------------------------

iteration=0
while (( iteration < MAX_ITERATIONS )); do
    (( iteration++ )) || true
    ts=$(date +"%H:%M:%S")
    echo "[$ts] Poll $iteration / $MAX_ITERATIONS  - waiting $POLL_SECONDS s..."
    sleep "$POLL_SECONDS"

    q_json=$(get_quote "$TOKEN" "eth" "$ref_token_str" 2>&1) || {
        echo "Warning: poll $iteration quote failed -- retrying next interval." >&2
        continue
    }
    current_raw=$(extract_field "$q_json" "buyAmount")
    [[ -z "$current_raw" ]] && {
        echo "Warning: empty buyAmount on poll $iteration -- retrying." >&2
        continue
    }
    current_eth=$(fmt_eth "$current_raw")

    # -- process sells first (recoup ETH before spending on new buys) ---------
    for (( i=0; i<LEVELS; i++ )); do
        [[ "${grid_status[$i]}" != "filled" ]] && continue
        if awk_gte "$current_raw" "${grid_sell_level[$i]}"; then
            sell_eth_disp=$(fmt_eth "${grid_sell_level[$i]}")
            echo "  Cell $i: SELL triggered  (price $current_eth / sell level $sell_eth_disp)"
            if invoke_sell "${grid_token_held[$i]}" "$i"; then
                grid_status[$i]="pending_buy"
                grid_token_held[$i]=""
                grid_eth_spent_cell[$i]="0"
            else
                echo "  Warning: sell failed for cell $i -- keeping as filled." >&2
            fi
        fi
    done

    # -- process buys: highest buy level first (closest to current price) -----
    # Build a list of pending indices sorted by buy_level descending
    sorted_pending=()
    for (( i=0; i<LEVELS; i++ )); do
        [[ "${grid_status[$i]}" == "pending_buy" ]] && sorted_pending+=("$i")
    done
    # Sort descending by buy_level (highest first = closest to current price)
    IFS=$'\n' sorted_pending=($(
        for idx in "${sorted_pending[@]}"; do
            echo "${grid_buy_level[$idx]} $idx"
        done | sort -rn | awk '{print $2}'
    ))
    unset IFS

    for i in "${sorted_pending[@]}"; do
        if awk_lte "$current_raw" "${grid_buy_level[$i]}"; then
            buy_eth_disp=$(fmt_eth "${grid_buy_level[$i]}")
            echo "  Cell $i: BUY triggered  (price $current_eth / buy level $buy_eth_disp)"
            token_str=$(invoke_buy "$ETH_PER_GRID" "$i") || {
                echo "  Warning: buy failed for cell $i -- skipping." >&2
                continue
            }
            grid_status[$i]="filled"
            grid_token_held[$i]="$token_str"
            grid_eth_spent_cell[$i]="$ETH_PER_GRID"
        fi
    done

    show_grid "$current_eth" "$base_eth"
done

# -- max iterations: sell all filled cells ------------------------------------

echo ""
echo "Max iterations ($MAX_ITERATIONS) reached. Selling all filled positions..."

for (( i=0; i<LEVELS; i++ )); do
    [[ "${grid_status[$i]}" != "filled" ]] && continue
    echo "  Selling cell $i: ${grid_token_held[$i]} $TOKEN_LABEL"
    if invoke_sell "${grid_token_held[$i]}" "$i"; then
        grid_status[$i]="pending_buy"
        grid_token_held[$i]=""
        grid_eth_spent_cell[$i]="0"
    else
        echo "  Warning: final sell failed for cell $i -- manual sell required." >&2
    fi
done

pl=$(awk "BEGIN { printf \"%.8f\", $total_eth_received - $total_eth_spent }")
pl_sign=$(awk "BEGIN { print ($pl >= 0) ? \"+\" : \"\" }")

echo ""
echo "=== Grid Session Complete ==="
echo "  Total buys      : $total_buys"
echo "  Total sells     : $total_sells"
echo "  ETH spent       : $total_eth_spent ETH"
echo "  ETH received    : $total_eth_received ETH"
echo "  Net P/L         : ${pl_sign}${pl} ETH"
