<#
.SYNOPSIS
    Ladder buy: accumulate any token at N price levels below the current price.
    Each time price dips to a rung trigger, buy -EthPerRung ETH worth of tokens.
    Optionally, when all rungs are filled, start a trailing stop on the full
    accumulated position.

.DESCRIPTION
    1. Auto-detects token decimals via on-chain RPC call.
    2. Quotes -EthPerRung ETH -> <Token> to derive a reference token amount.
    3. Quotes that reference amount back to ETH to establish the baseline price.
    4. Builds -Rungs buy trigger levels below baseline, spaced -RungSpacingPct apart.
    5. Polls every -PollSeconds seconds. When price drops to a rung's trigger
       level, buys -EthPerRung ETH worth of tokens.
    6. Tracks the accumulated token position.
    7. If -TrailAfterN > 0, switches into trailing stop mode on the accumulated
       position once that many rungs have filled (does not require all rungs).
       -TrailAfterFilled is kept as a backward-compatible alias for -TrailAfterN = Rungs.
    8. On -MaxIterations, sells all accumulated tokens at market.

    Use -DryRun to simulate without executing any swaps.

.PARAMETER Token
    Token contract address or shorthand alias ('speed').
    ETH / native is always the quote currency.

.PARAMETER EthPerRung
    ETH to spend at each buy trigger (min ~0.0001 ETH).

.PARAMETER Rungs
    Number of buy levels to set below current price. Default: 4.

.PARAMETER RungSpacingPct
    Percentage price drop between adjacent rung triggers. Default: 5.
    Rung i fires when price drops (i+1) * RungSpacingPct% from baseline.

.PARAMETER TrailPct
    Trailing stop % applied to accumulated position once trail is active. Default: 5.

.PARAMETER TrailAfterN
    Start trailing stop once this many rungs have filled. Does not require all rungs.
    Default: 0 (disabled). TrailAfterN=2 on a 4-rung ladder activates trail after
    the second buy, regardless of whether rungs 3 and 4 ever fire.

.PARAMETER TrailAfterFilled
    Backward-compatible alias. Equivalent to -TrailAfterN $Rungs (trail only after ALL rungs fill).

.PARAMETER DryRun
    Print what would happen without executing any swaps. Quotes still run.

.EXAMPLE
    .\ladder-buy-any.ps1 -Chain base -Token speed -EthPerRung 0.001 -Rungs 4 -RungSpacingPct 5
    .\ladder-buy-any.ps1 -Chain base -Token speed -EthPerRung 0.001 -Rungs 4 -RungSpacingPct 5 -TrailAfterFilled -TrailPct 4
    .\ladder-buy-any.ps1 -Chain base -Token speed -EthPerRung 0.001 -Rungs 4 -RungSpacingPct 5 -TrailAfterN 2 -TrailPct 4
    .\ladder-buy-any.ps1 -Chain base -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf -TokenSymbol cbBTC -EthPerRung 0.002 -Rungs 3 -RungSpacingPct 3 -TrailAfterFilled -TrailPct 4 -PollSeconds 30
    .\ladder-buy-any.ps1 -Chain base -Token speed -EthPerRung 0.001 -Rungs 5 -RungSpacingPct 3 -DryRun
#>

param(
    [Parameter(Mandatory)][string] $Chain,
    [Parameter(Mandatory)][string] $Token,
    [Parameter(Mandatory)][string] $EthPerRung,
    [string]                       $TokenSymbol     = "",
    [int]                          $Rungs           = 4,
    [double]                       $RungSpacingPct  = 5.0,
    [double]                       $TrailPct        = 5.0,
    [int]                          $TrailAfterN     = 0,
    [switch]                       $TrailAfterFilled,
    [int]                          $PollSeconds     = 60,
    [int]                          $MaxIterations   = 2880,
    [switch]                       $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ETH_DECIMALS = [double]1e18

$RPC_URLS = @{
    "base"     = "https://mainnet.base.org"
    "8453"     = "https://mainnet.base.org"
    "mainnet"  = "https://eth.llamarpc.com"
    "ethereum" = "https://eth.llamarpc.com"
    "1"        = "https://eth.llamarpc.com"
    "optimism" = "https://mainnet.optimism.io"
    "op"       = "https://mainnet.optimism.io"
    "10"       = "https://mainnet.optimism.io"
    "arbitrum" = "https://arb1.arbitrum.io/rpc"
    "arb"      = "https://arb1.arbitrum.io/rpc"
    "42161"    = "https://arb1.arbitrum.io/rpc"
    "polygon"  = "https://polygon.llamarpc.com"
    "matic"    = "https://polygon.llamarpc.com"
    "137"      = "https://polygon.llamarpc.com"
    "bsc"      = "https://bsc-dataseed.binance.org"
    "bnb"      = "https://bsc-dataseed.binance.org"
    "56"       = "https://bsc-dataseed.binance.org"
}

# P&L accumulators
$script:totalEthSpent    = 0.0
$script:totalEthReceived = 0.0
$script:totalBuys        = 0
$script:accTokenHuman    = 0.0   # accumulated token balance in human units

# -- helpers -------------------------------------------------------------------

function Get-TokenDecimals {
    param([string]$tokenAddr, [string]$chainName)
    $lower = $tokenAddr.ToLower()
    if ($lower -in @('speed', 'eth', 'native', 'ether')) { return 18 }
    if (-not $tokenAddr.StartsWith("0x")) { return 18 }

    $rpc = $RPC_URLS[$chainName.ToLower()]
    if (-not $rpc) {
        Write-Warning "Unknown chain '$chainName' for RPC decimals lookup, assuming 18."
        return 18
    }

    $body = '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"' + $tokenAddr + '","data":"0x313ce567"},"latest"],"id":1}'
    try {
        $resp = Invoke-RestMethod -Uri $rpc -Method Post -Body $body -ContentType "application/json"
        $hex  = $resp.result -replace '^0x', ''
        return [Convert]::ToInt32($hex.TrimStart('0'), 16)
    } catch {
        Write-Warning "Could not fetch decimals from RPC: $_  Assuming 18."
        return 18
    }
}

function Get-Quote {
    param([string]$sellTok, [string]$buyTok, [string]$sellAmt)
    $raw  = speed quote --json -c $Chain --sell $sellTok --buy $buyTok -a $sellAmt 2>&1
    $line = $raw | Where-Object { $_ -match '^\{' } | Select-Object -First 1
    if (-not $line) { throw "No JSON from quote. Output:`n$($raw -join "`n")" }
    $obj = $line | ConvertFrom-Json
    if (-not ($obj.PSObject.Properties.Name -contains 'buyAmount')) {
        throw "Quote error: $($obj.error)"
    }
    return $obj
}

function Invoke-RungBuy {
    param([int]$rungIndex, [double]$triggerETH)
    $q          = Get-Quote -sellTok 'eth' -buyTok $Token -sellAmt $EthPerRung
    $tokenRaw   = [double]$q.buyAmount
    $tokenHuman = $tokenRaw / $script:TOKEN_SCALE
    $tokenStr   = $tokenHuman.ToString("F$script:tokenDecimals")

    if ([double]$tokenStr -le 0) { throw "Token amount resolved to 0 for rung $rungIndex." }

    if ($DryRun) {
        Write-Host ("  [DRY-RUN] Rung {0}: would BUY {1} {2} for {3} ETH  (trigger: {4:F8} ETH)" -f `
            $rungIndex, $tokenStr, $script:TokenLabel, $EthPerRung, $triggerETH) -ForegroundColor DarkYellow
    } else {
        Write-Host ("  >>> Rung {0} BUY: speed swap -c {1} --sell eth --buy {2} -a {3} -y  (price: {4:F8} ETH)" -f `
            $rungIndex, $Chain, $Token, $EthPerRung, $triggerETH) -ForegroundColor Cyan
        $raw2  = speed --json --yes swap -c $Chain --sell eth --buy $Token -a $EthPerRung 2>&1
        $line2 = $raw2 | Where-Object { $_ -match '^\{' } | Select-Object -First 1
        $res   = $line2 | ConvertFrom-Json
        if ($res.PSObject.Properties.Name -contains 'error') { throw "Buy swap failed: $($res.error)" }
        Write-Host ("  TX: {0}" -f $res.txHash) -ForegroundColor DarkGray
    }

    $script:totalEthSpent  += [double]$EthPerRung
    $script:totalBuys++
    $script:accTokenHuman  += $tokenHuman
    return $tokenStr
}

function Run-SellAll {
    param([string]$accTokenStr)
    Write-Host ""
    if ($DryRun) {
        Write-Host ("  [DRY-RUN] Would SELL all accumulated {0} {1} -> ETH" -f $accTokenStr, $script:TokenLabel) -ForegroundColor DarkYellow
        return
    }
    Write-Host (">>> Selling all accumulated tokens: speed swap -c {0} --sell {1} --buy eth -a {2} -y" -f `
        $Chain, $Token, $accTokenStr) -ForegroundColor Cyan
    speed swap -c $Chain --sell $Token --buy eth -a $accTokenStr -y
    exit $LASTEXITCODE
}

# -- setup ---------------------------------------------------------------------

Write-Host ""
Write-Host "Detecting token decimals..." -ForegroundColor DarkGray
$tokenDecimals       = Get-TokenDecimals -tokenAddr $Token -chainName $Chain
$script:tokenDecimals = $tokenDecimals
$script:TOKEN_SCALE  = [Math]::Pow(10, $tokenDecimals)
$script:TokenLabel   = if ($TokenSymbol -ne "") { $TokenSymbol } else { $Token }

$totalEthRequired = [double]$EthPerRung * $Rungs

# Backward-compat: -TrailAfterFilled is an alias for -TrailAfterN $Rungs
if ($TrailAfterFilled -and $TrailAfterN -eq 0) { $TrailAfterN = $Rungs }

Write-Host ""
Write-Host "=== Speed Ladder Buy ===" -ForegroundColor Yellow
if ($DryRun) { Write-Host "  *** DRY-RUN MODE -- no swaps will execute ***" -ForegroundColor DarkYellow }
Write-Host "  Chain            : $Chain"
Write-Host "  Token            : $script:TokenLabel  (decimals: $tokenDecimals)"
Write-Host "  ETH per rung     : $EthPerRung ETH"
Write-Host "  Rungs            : $Rungs"
Write-Host "  Rung spacing     : $RungSpacingPct % drop per level"
Write-Host ("  Max ETH outlay   : {0:F8} ETH (if all rungs fill)" -f $totalEthRequired)
if ($TrailAfterN -gt 0) {
    $trailLabel = if ($TrailAfterN -eq $Rungs) { "all $Rungs rungs" } else { "$TrailAfterN of $Rungs rungs" }
    Write-Host "  Trail after      : $TrailPct % trailing stop after $trailLabel fill"
}
Write-Host "  Poll interval    : $PollSeconds s"
Write-Host "  Max polls        : $MaxIterations"
Write-Host ""

# -- step 1: reference quote ---------------------------------------------------

Write-Host "Step 1 - Quoting $EthPerRung ETH -> $script:TokenLabel to establish reference..." -ForegroundColor DarkCyan

$refBuyQuote   = Get-Quote -sellTok 'eth' -buyTok $Token -sellAmt $EthPerRung
$refTokenRaw   = [double]$refBuyQuote.buyAmount
$refTokenHuman = $refTokenRaw / $script:TOKEN_SCALE
$refTokenStr   = $refTokenHuman.ToString("F$tokenDecimals")

if ([double]$refTokenStr -le 0) {
    Write-Error "Reference token amount resolved to 0. Aborting."
    exit 1
}
Write-Host ("  Reference amount : {0} {1} per {2} ETH grid" -f $refTokenStr, $script:TokenLabel, $EthPerRung)

# -- step 2: baseline price ----------------------------------------------------

Write-Host ""
Write-Host "Step 2 - Quoting $script:TokenLabel -> ETH to establish baseline price..." -ForegroundColor DarkCyan

$baseSellQuote = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $refTokenStr
$baseRaw       = [double]$baseSellQuote.buyAmount
$baseETH       = $baseRaw / $ETH_DECIMALS

Write-Host ("  Baseline price : {0:F8} ETH (for {1} {2})" -f $baseETH, $refTokenStr, $script:TokenLabel)
Write-Host ""

# -- step 3: build rung triggers -----------------------------------------------

Write-Host "Step 3 - Building buy ladder..." -ForegroundColor DarkCyan

$rungCells = @()
for ($i = 0; $i -lt $Rungs; $i++) {
    $dropPct     = ($i + 1) * $RungSpacingPct
    $triggerRaw  = $baseRaw * (1.0 - $dropPct / 100.0)
    $triggerETH  = $triggerRaw / $ETH_DECIMALS
    $rungCells  += [PSCustomObject]@{
        Index       = $i
        DropPct     = $dropPct
        TriggerRaw  = $triggerRaw
        TriggerETH  = $triggerETH
        Status      = "waiting"   # "waiting" | "filled"
        TokenStr    = ""
    }
    Write-Host ("  Rung {0}: buy {1} ETH when price drops {2}%  (trigger: {3:F8} ETH)" -f `
        $i, $EthPerRung, $dropPct, $triggerETH) -ForegroundColor DarkGray
}
Write-Host ""

# -- step 4: poll loop ---------------------------------------------------------

$iteration    = 0
$inTrailMode  = $false
$trailPeakRaw = [double]0
$trailFloorRaw= [double]0

while ($iteration -lt $MaxIterations) {
    $iteration++
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] Poll $iteration / $MaxIterations - waiting $PollSeconds s..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $PollSeconds

    try {
        $q          = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $refTokenStr
        $currentRaw = [double]$q.buyAmount
        $currentETH = $currentRaw / $ETH_DECIMALS
        $pctFromBase= (($currentRaw - $baseRaw) / $baseRaw) * 100.0
        $ts2        = Get-Date -Format "HH:mm:ss"

        $filledCount  = ($rungCells | Where-Object { $_.Status -eq "filled" } | Measure-Object).Count
        $pendingCount = $Rungs - $filledCount

        # -- trailing stop mode ------------------------------------------------
        if ($inTrailMode) {
            $accStr = $script:accTokenHuman.ToString("F$tokenDecimals")

            # Re-quote actual accumulated amount for trail tracking
            $accQuote  = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $accStr
            $accRaw    = [double]$accQuote.buyAmount
            $accETH    = $accRaw / $ETH_DECIMALS

            if ($accRaw -gt $trailPeakRaw) {
                $trailPeakRaw  = $accRaw
                $trailFloorRaw = $trailPeakRaw * (1.0 - $TrailPct / 100.0)
            }
            $trailPeakETH  = $trailPeakRaw  / $ETH_DECIMALS
            $trailFloorETH = $trailFloorRaw / $ETH_DECIMALS
            $pctFromPeak   = (($accRaw - $trailPeakRaw) / $trailPeakRaw) * 100.0

            $trailDist     = $trailPeakRaw - $trailFloorRaw
            $distToFloor   = $accRaw - $trailFloorRaw
            if ($accRaw -ge $trailPeakRaw) {
                $color = "Green"
            } elseif ($trailDist -gt 0 -and ($distToFloor / $trailDist) -lt 0.25) {
                $color = "DarkRed"
            } else {
                $color = "Cyan"
            }

            Write-Host ("[$ts2] TRAIL MODE  - acc pos: {0:F8} ETH  peak: {1:F8}  floor: {2:F8}  ({3:F4}% from peak)" -f `
                $accETH, $trailPeakETH, $trailFloorETH, $pctFromPeak) -ForegroundColor $color

            if ($accRaw -le $trailFloorRaw) {
                $gainPct = (($accRaw - ($script:totalEthSpent * $ETH_DECIMALS)) / ($script:totalEthSpent * $ETH_DECIMALS)) * 100.0
                Write-Host ""
                Write-Host ("Trail floor breached! {0:F8} ETH back  ({1:F4}% vs cost basis)" -f $accETH, $gainPct) -ForegroundColor Red
                Run-SellAll -accTokenStr $accStr
            }
            continue
        }

        # -- accumulation mode -------------------------------------------------
        # Color: price dropping toward rungs = progressively red
        $lowestTrigger = ($rungCells | Where-Object { $_.Status -eq "waiting" } | Measure-Object TriggerRaw -Minimum).Minimum
        if ($null -ne $lowestTrigger -and $currentRaw -le $lowestTrigger) {
            $color = "DarkRed"
        } elseif ($pctFromBase -lt -($RungSpacingPct / 2)) {
            $color = "DarkYellow"
        } else {
            $color = "White"
        }

        Write-Host ("[$ts2] Price: {0:F8} ETH  ({1:+0.0000}% from base)  Filled: {2}/{3}" -f `
            $currentETH, $pctFromBase, $filledCount, $Rungs) -ForegroundColor $color

        # Process buys  - closest rung first (highest trigger raw = least drop required)
        $pendingCells = $rungCells | Where-Object { $_.Status -eq "waiting" } | Sort-Object TriggerRaw -Descending
        foreach ($cell in $pendingCells) {
            if ($currentRaw -le $cell.TriggerRaw) {
                Write-Host ("  Rung {0}: BUY triggered (price {1:F8} <= trigger {2:F8}, -{3}%)" -f `
                    $cell.Index, $currentETH, $cell.TriggerETH, $cell.DropPct) -ForegroundColor Magenta
                try {
                    $tokenStr       = Invoke-RungBuy -rungIndex $cell.Index -triggerETH $cell.TriggerETH
                    $cell.Status    = "filled"
                    $cell.TokenStr  = $tokenStr
                } catch {
                    Write-Warning "Buy failed for rung $($cell.Index): $_ -- skipping."
                }
            }
        }

        # Check if enough rungs have filled to activate trail
        $filledCount = ($rungCells | Where-Object { $_.Status -eq "filled" } | Measure-Object).Count
        if (-not $inTrailMode -and $TrailAfterN -gt 0 -and $filledCount -ge $TrailAfterN) {
            $accStr = $script:accTokenHuman.ToString("F$tokenDecimals")
            $trailLabel = if ($TrailAfterN -eq $Rungs) { "All $Rungs rungs" } else { "$filledCount/$Rungs rungs" }
            Write-Host ""
            Write-Host "$trailLabel filled! Switching to trailing stop mode..." -ForegroundColor Green
            Write-Host ("  Accumulated: {0} {1}  (cost: {2:F8} ETH)" -f $accStr, $script:TokenLabel, $script:totalEthSpent) -ForegroundColor DarkGray

            $accQ          = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $accStr
            $trailPeakRaw  = [double]$accQ.buyAmount
            $trailFloorRaw = $trailPeakRaw * (1.0 - $TrailPct / 100.0)
            $inTrailMode   = $true
            Write-Host ("  Trail peak    : {0:F8} ETH" -f ($trailPeakRaw / $ETH_DECIMALS)) -ForegroundColor DarkGray
            Write-Host ("  Trail floor   : {0:F8} ETH  (-{1}%)" -f ($trailFloorRaw / $ETH_DECIMALS), $TrailPct) -ForegroundColor DarkGray
            Write-Host ""
        } elseif ($filledCount -ge $Rungs -and $TrailAfterN -eq 0) {
            Write-Host ""
            Write-Host "All $Rungs rungs filled. No trailing stop set. Continuing to monitor (max iterations)." -ForegroundColor Green
        }

    } catch {
        Write-Warning "Poll $iteration failed: $_ -- retrying next interval."
    }
}

# -- max iterations: sell all accumulated tokens -------------------------------

Write-Host ""
Write-Host "Max iterations ($MaxIterations) reached." -ForegroundColor Yellow

if ($script:accTokenHuman -gt 0) {
    $accStr = $script:accTokenHuman.ToString("F$tokenDecimals")
    Write-Host ("Selling all accumulated tokens: {0} {1}" -f $accStr, $script:TokenLabel) -ForegroundColor Yellow
    Run-SellAll -accTokenStr $accStr
} else {
    Write-Host "No accumulated tokens to sell." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "=== Ladder Buy Session Complete ===" -ForegroundColor Yellow
Write-Host ("  Total buys   : {0}" -f $script:totalBuys)
Write-Host ("  ETH spent    : {0:F8} ETH" -f $script:totalEthSpent)
