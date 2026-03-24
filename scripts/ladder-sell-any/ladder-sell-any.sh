#!/usr/bin/env bash
# ladder-sell-any.sh
# Buy any token with ETH, then sell in N equal tranches at predefined profit
# levels. Exits the position incrementally rather than all-at-once.
#
# Usage:
#   ./ladder-sell-any.sh --chain base --token speed --amount 0.002
#   ./ladder-sell-any.sh --chain base --token speed --amount 0.002 --rungs 4 --first-rung-pct 25 --rung-spacing-pct 25
#   ./ladder-sell-any.sh --chain base --token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf --tokensymbol cbBTC --amount 0.005 --rungs 3 --first-rung-pct 10 --rung-spacing-pct 15
#
# Steps:
#   1. Auto-detects token decimals via on-chain RPC call.
#   2. Quotes ETH -> Token to show what you will get.
#   3. Executes the buy (ETH -> Token).
#   4. Baseline sell quote anchors rung targets.
#   5. Polls every --pollseconds. When full-position quote reaches a rung target,
#      that tranche (1/N of original position) is sold.
#   6. Exits when all rungs sold or --maxiterations reached.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_common.sh
source "$SCRIPT_DIR/../_common.sh"


# --- defaults -----------------------------------------------------------------

CHAIN=""
TOKEN=""
AMOUNT=""
TOKEN_SYMBOL=""
RUNGS=4
FIRST_RUNG_PCT=25
RUNG_SPACING_PCT=25
POLL_SECONDS=60
MAX_ITERATIONS=1440
DRY_RUN=0
BASE_TOKEN="speed"
BASE_TOKEN_SYMBOL=""

# --- arg parsing --------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chain)            CHAIN="$2";            shift 2 ;;
        --token)            TOKEN="$2";            shift 2 ;;
        --amount)           AMOUNT="$2";           shift 2 ;;
        --tokensymbol)      TOKEN_SYMBOL="$2";     shift 2 ;;
        --rungs)            RUNGS="$2";            shift 2 ;;
        --first-rung-pct)   FIRST_RUNG_PCT="$2";   shift 2 ;;
        --rung-spacing-pct) RUNG_SPACING_PCT="$2"; shift 2 ;;
        --pollseconds)      POLL_SECONDS="$2";     shift 2 ;;
        --maxiterations)    MAX_ITERATIONS="$2";   shift 2 ;;
        --dry-run)          DRY_RUN=1;             shift ;;
        --base-token)         BASE_TOKEN="$2";       shift 2 ;;
        --base-token-symbol) BASE_TOKEN_SYMBOL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$CHAIN" || -z "$TOKEN" || -z "$AMOUNT" ]]; then
    echo "Usage: $0 --chain <chain> --token <addr|alias> --amount <base> [--rungs <n>] [--first-rung-pct <pct>] [--rung-spacing-pct <pct>] [--tokensymbol <name>] [--pollseconds <s>] [--maxiterations <n>] [--dry-run] [--base-token ...] [--base-token-symbol ...]" >&2
    exit 1
fi

BASE_TOKEN="$(speed_v2_resolve_base_token "$TOKEN" "$BASE_TOKEN")"
BASE_DECIMALS=$(speed_v2_get_token_decimals "$BASE_TOKEN" "$CHAIN")
BASE_SCALE=$(awk "BEGIN { printf \"%.0f\", 10 ^ $BASE_DECIMALS }")
BASE_LABEL="$(speed_v2_base_label "$BASE_TOKEN_SYMBOL" "$BASE_TOKEN")"

# --- colours ------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
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

awk_gte() { awk "BEGIN { exit ($1 >= $2) ? 0 : 1 }"; }
awk_gt()  { awk "BEGIN { exit ($1 > $2)  ? 0 : 1 }"; }

# --- setup --------------------------------------------------------------------

TOKEN_LABEL="${TOKEN_SYMBOL:-$TOKEN}"

echo -e "${GRAY}Detecting token decimals...${RESET}"
TOKEN_DECIMALS=$(get_token_decimals "$TOKEN" "$CHAIN")
TOKEN_SCALE=$(awk "BEGIN { printf \"%.0f\", 10 ^ $TOKEN_DECIMALS }")

targets_str=""
for (( i=0; i<RUNGS; i++ )); do
    pct=$(awk -v f="$FIRST_RUNG_PCT" -v s="$RUNG_SPACING_PCT" -v i="$i" 'BEGIN { printf "%.4f", f + i * s }')
    [[ -n "$targets_str" ]] && targets_str+=", "
    targets_str+="+${pct}%"
done

echo ""
echo -e "${YELLOW}=== Speed Ladder Sell ===${RESET}"
echo "  Chain         : $CHAIN"
echo "  Token         : $TOKEN_LABEL  (decimals: $TOKEN_DECIMALS)"
echo "  Base spent    : $AMOUNT $BASE_LABEL"
echo "  Rungs         : $RUNGS  (sell 1/$RUNGS of position per rung)"
echo "  Rung targets  : $targets_str"
echo "  Poll interval : $POLL_SECONDS s"
echo "  Max polls     : $MAX_ITERATIONS"
[[ "$DRY_RUN" == "1" ]] && echo "  *** DRY-RUN MODE -- no swaps will execute ***"
echo ""

# --- step 1: quote the buy ----------------------------------------------------

echo -e "${CYAN}Step 1 - Quoting $BASE_LABEL -> $TOKEN_LABEL for $AMOUNT $BASE_LABEL...${RESET}"

buy_json=$(get_quote "$BASE_TOKEN" "$TOKEN" "$AMOUNT")
token_raw=$(extract_buy_amount "$buy_json")

if [[ -z "$token_raw" ]]; then
    echo "Failed to parse buyAmount from: $buy_json" >&2; exit 1
fi

token_human=$(awk "BEGIN { printf \"%.${TOKEN_DECIMALS}f\", $token_raw / $TOKEN_SCALE }")
token_str=$(format_token "$token_human" "$TOKEN_DECIMALS")

awk_gt "$token_str" "0" || { echo "Token amount resolved to 0. Aborting." >&2; exit 1; }

echo "  You will get : $token_str $TOKEN_LABEL for $AMOUNT $BASE_LABEL"
echo ""

# --- step 2: execute the buy --------------------------------------------------

if [[ "$DRY_RUN" == "1" ]]; then
    echo -e "${CYAN}Step 2 - [DRY-RUN] Skipping buy; using Step 1 quote buy amount.${RESET}"
    echo ""
else
    echo -e "${CYAN}Step 2 - Buying $TOKEN_LABEL...${RESET}"
    echo -e "${CYAN}>>> Executing: speed swap -c $CHAIN --sell ${BASE_TOKEN} --buy $TOKEN -a $AMOUNT -y${RESET}"
    speed swap -c "$CHAIN" --sell "$BASE_TOKEN" --buy "$TOKEN" -a "$AMOUNT" -y || {
        echo "Buy swap failed. Aborting." >&2; exit 1
    }
    echo ""
fi

# --- step 3: baseline sell quote ----------------------------------------------

echo -e "${CYAN}Step 3 - Baseline sell quote ($TOKEN_LABEL -> $BASE_LABEL)...${RESET}"

sell_json=$(get_quote "$TOKEN" "$BASE_TOKEN" "$token_str")
baseline_raw=$(extract_buy_amount "$sell_json")

if [[ -z "$baseline_raw" ]]; then
    echo "Failed to parse baseline buyAmount. Aborting." >&2; exit 1
fi

baseline_eth=$(to_human_base "$baseline_raw")
echo "  Baseline $BASE_LABEL back : $baseline_eth $BASE_LABEL"
echo ""

# --- build rung targets -------------------------------------------------------

# Per-rung tranche: floor(token_raw/Rungs) wei; last rung gets remainder (parity with .ps1)
rung_token_raw=$(awk -v t="$token_raw" -v n="$RUNGS" 'BEGIN { printf "%.0f", int(t/n) }')
last_rung_token_raw=$(awk -v t="$token_raw" -v r="$rung_token_raw" -v n="$RUNGS" 'BEGIN { printf "%.0f", t - r*(n-1) }')

declare -a RUNG_SELL_STRS=()
for (( i=0; i<RUNGS; i++ )); do
    if (( i == RUNGS - 1 )); then
        tr_raw="$last_rung_token_raw"
    else
        tr_raw="$rung_token_raw"
    fi
    tr_h=$(awk -v r="$tr_raw" -v ts="$TOKEN_SCALE" -v d="$TOKEN_DECIMALS" 'BEGIN { printf "%.*f", d, r/ts }')
    RUNG_SELL_STRS[i]=$(format_token "$tr_h" "$TOKEN_DECIMALS")
done

awk_gt "${RUNG_SELL_STRS[0]}" "0" || { echo "Rung token amount resolved to 0. Aborting." >&2; exit 1; }

declare -a RUNG_TARGET_RAWS=()
declare -a RUNG_TARGET_PCTS=()
declare -a RUNG_SOLD=()

for (( i=0; i<RUNGS; i++ )); do
    pct=$(awk -v f="$FIRST_RUNG_PCT" -v s="$RUNG_SPACING_PCT" -v i="$i" 'BEGIN { printf "%.4f", f + i * s }')
    target_raw=$(awk "BEGIN { printf \"%.0f\", $baseline_raw * (1 + $pct / 100) }")
    target_eth=$(to_human_base "$target_raw")
    RUNG_TARGET_RAWS+=("$target_raw")
    RUNG_TARGET_PCTS+=("$pct")
    RUNG_SOLD+=("0")
    echo -e "${GRAY}  Rung $i: sell tranche (${RUNG_SELL_STRS[$i]} $TOKEN_LABEL) at +${pct}%  (target: $target_eth $BASE_LABEL for full position)${RESET}"
done
echo ""

# --- step 4: poll for rung targets --------------------------------------------

echo -e "${CYAN}Step 4 - Monitoring. Waiting for rung targets...${RESET}"
echo ""

iteration=0
sold_rungs=0

while (( iteration < MAX_ITERATIONS )); do
    (( iteration++ )) || true
    ts=$(date +"%H:%M:%S")
    echo -e "${GRAY}[$ts] Poll $iteration / $MAX_ITERATIONS - waiting $POLL_SECONDS s...${RESET}"
    sleep "$POLL_SECONDS"

    poll_json=$(get_quote "$TOKEN" "$BASE_TOKEN" "$token_str" 2>&1) || {
        echo "Warning: quote failed on poll $iteration - retrying next interval."
        continue
    }

    current_raw=$(extract_buy_amount "$poll_json")
    if [[ -z "$current_raw" ]]; then
        echo "Warning: could not parse buyAmount on poll $iteration - retrying."
        continue
    fi

    current_eth=$(to_human_base "$current_raw")
    pct_vs_base=$(awk "BEGIN { printf \"%+.4f\", ($current_raw - $baseline_raw) / $baseline_raw * 100 }")
    ts2=$(date +"%H:%M:%S")

    next_target_raw=""
    for (( j=0; j<RUNGS; j++ )); do
        [[ "${RUNG_SOLD[$j]}" == "1" ]] && continue
        next_target_raw="${RUNG_TARGET_RAWS[$j]}"
        break
    done
    if [[ -n "$next_target_raw" ]] && awk_gte "$current_raw" "$next_target_raw"; then
        color="$GREEN"
    elif awk_gt "$current_raw" "$baseline_raw"; then
        color="$WHITE"
    else
        color="$RED"
    fi

    echo -e "${color}[$ts2] Full pos: $current_eth $BASE_LABEL  (${pct_vs_base}% vs baseline)  ($sold_rungs/$RUNGS sold)${RESET}"

    # Process rungs in order of increasing target (lowest first — parity with .ps1 Sort-Object TargetRaw)
    for (( i=0; i<RUNGS; i++ )); do
        [[ "${RUNG_SOLD[$i]}" == "1" ]] && continue
        if awk_gte "$current_raw" "${RUNG_TARGET_RAWS[$i]}"; then
            gain_pct=$(awk "BEGIN { printf \"%.4f\", ($current_raw - $baseline_raw) / $baseline_raw * 100 }")
            echo ""
            echo -e "${GREEN}Rung $i target hit! +${gain_pct}% gain. Selling tranche (${RUNG_SELL_STRS[$i]} $TOKEN_LABEL)...${RESET}"
            if [[ "$DRY_RUN" == "1" ]]; then
                echo -e "${YELLOW}>>> [DRY-RUN] Rung $i SELL (+${RUNG_TARGET_PCTS[$i]}%): would run speed swap -c $CHAIN --sell $TOKEN --buy ${BASE_TOKEN} -a ${RUNG_SELL_STRS[$i]} -y${RESET}"
                RUNG_SOLD[$i]="1"
                (( sold_rungs++ )) || true
                echo -e "${GRAY}  Rung $i sold. $sold_rungs/$RUNGS rungs complete.${RESET}"
                echo ""
            else
                echo -e "${CYAN}>>> Rung $i SELL (+${RUNG_TARGET_PCTS[$i]}%): speed swap -c $CHAIN --sell $TOKEN --buy ${BASE_TOKEN} -a ${RUNG_SELL_STRS[$i]} -y${RESET}"
                if speed swap -c "$CHAIN" --sell "$TOKEN" --buy "$BASE_TOKEN" -a "${RUNG_SELL_STRS[$i]}" -y; then
                    RUNG_SOLD[$i]="1"
                    (( sold_rungs++ )) || true
                    echo -e "${GRAY}  Rung $i sold. $sold_rungs/$RUNGS rungs complete.${RESET}"
                    echo ""
                else
                    echo "Warning: rung $i sell failed -- will retry next poll." >&2
                fi
            fi
        fi
    done

    # All rungs fired — exit
    if (( sold_rungs >= RUNGS )); then
        echo ""
        echo -e "${GREEN}All $RUNGS rungs sold. Ladder complete.${RESET}"
        exit 0
    fi
done

# --- max iterations: sell remaining -------------------------------------------

echo ""
echo -e "${YELLOW}Max iterations ($MAX_ITERATIONS) reached. Selling remaining rungs...${RESET}"

for (( i=0; i<RUNGS; i++ )); do
    [[ "${RUNG_SOLD[$i]}" == "1" ]] && continue
    echo -e "${CYAN}  Selling rung $i: ${RUNG_SELL_STRS[$i]} $TOKEN_LABEL${RESET}"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "${YELLOW}  [DRY-RUN] Would rung $i SELL: speed swap -c $CHAIN --sell $TOKEN --buy ${BASE_TOKEN} -a ${RUNG_SELL_STRS[$i]} -y${RESET}"
        RUNG_SOLD[$i]="1"
        (( sold_rungs++ )) || true
    elif speed swap -c "$CHAIN" --sell "$TOKEN" --buy "$BASE_TOKEN" -a "${RUNG_SELL_STRS[$i]}" -y; then
        RUNG_SOLD[$i]="1"
        (( sold_rungs++ )) || true
    else
        echo "Warning: final sell failed for rung $i -- manual sell required." >&2
    fi
done

echo ""
echo -e "${YELLOW}=== Ladder Sell Session Complete ===${RESET}"
echo "  Rungs sold : $sold_rungs / $RUNGS"
