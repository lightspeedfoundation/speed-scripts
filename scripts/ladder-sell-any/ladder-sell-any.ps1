<#
.SYNOPSIS
    Ladder sell: buy any token with ETH, then sell in N equal tranches at
    predefined profit levels. Exits the position incrementally rather than
    all-at-once.

.DESCRIPTION
    1. Auto-detects token decimals via on-chain RPC call.
    2. Quotes ETH -> <Token> to show what you will get.
    3. Executes the buy (ETH -> <Token>).
    4. Gets a baseline sell quote to anchor rung targets.
    5. Builds -Rungs sell levels spaced -RungSpacingPct% apart, starting at
       -FirstRungPct% gain. Each rung sells 1/Rungs of the original position.
    6. Polls every -PollSeconds seconds. When the full-position sell quote
       reaches a rung's target, that tranche is sold immediately.
    7. Exits when all rungs are sold OR -MaxIterations polls are reached
       (remaining tokens are sold at market on timeout).

    Rung targets are % gain on the FULL baseline position value. Each rung
    sells an equal fraction (1/N) of the original token amount.

.PARAMETER Token
    Token contract address or shorthand alias ('speed').
    ETH / native is always the quote currency.

.PARAMETER Amount
    ETH to spend on the initial buy.

.PARAMETER Rungs
    Number of sell levels. Each fires at an equal slice of the position.
    Default: 4.

.PARAMETER FirstRungPct
    % gain above baseline to trigger the first sell. Default: 25.

.PARAMETER RungSpacingPct
    Additional % gain between each subsequent rung. Default: 25.
    With defaults and 4 rungs: sell 25% at +25%, +50%, +75%, +100%.

.EXAMPLE
    .\ladder-sell-any.ps1 -Chain base -Token speed -Amount 0.002
    .\ladder-sell-any.ps1 -Chain base -Token speed -Amount 0.002 -Rungs 4 -FirstRungPct 25 -RungSpacingPct 25
    .\ladder-sell-any.ps1 -Chain base -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf -TokenSymbol cbBTC -Amount 0.005 -Rungs 3 -FirstRungPct 10 -RungSpacingPct 15
#>

param(
    [Parameter(Mandatory)][string] $Chain,
    [Parameter(Mandatory)][string] $Token,
    [Parameter(Mandatory)][string] $Amount,
    [string]                       $TokenSymbol    = "",
    [int]                          $Rungs          = 4,
    [double]                       $FirstRungPct   = 25.0,
    [double]                       $RungSpacingPct = 25.0,
    [int]                          $PollSeconds    = 60,
    [int]                          $MaxIterations  = 1440
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

# ── helpers ───────────────────────────────────────────────────────────────────

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

function Invoke-RungSell {
    param([string]$tokenAmount, [int]$rungIndex, [double]$targetPct)
    Write-Host ""
    Write-Host (">>> Rung {0} SELL (+{1}%): speed swap -c {2} --sell {3} --buy eth -a {4} -y" -f `
        $rungIndex, $targetPct, $Chain, $Token, $tokenAmount) -ForegroundColor Cyan
    speed swap -c $Chain --sell $Token --buy eth -a $tokenAmount -y
    if ($LASTEXITCODE -ne 0) {
        throw "Sell swap failed (exit $LASTEXITCODE) for rung $rungIndex."
    }
}

# ── setup ─────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Detecting token decimals..." -ForegroundColor DarkGray
$tokenDecimals    = Get-TokenDecimals -tokenAddr $Token -chainName $Chain
$TOKEN_SCALE      = [Math]::Pow(10, $tokenDecimals)
$TokenLabel       = if ($TokenSymbol -ne "") { $TokenSymbol } else { $Token }

# Validate parameters
if ($Rungs -lt 1)          { Write-Error "-Rungs must be >= 1."; exit 1 }
if ($FirstRungPct -le 0)   { Write-Error "-FirstRungPct must be > 0."; exit 1 }
if ($RungSpacingPct -le 0) { Write-Error "-RungSpacingPct must be > 0."; exit 1 }

# Build rung target percentages
$rungTargetPcts = @()
for ($i = 0; $i -lt $Rungs; $i++) {
    $rungTargetPcts += $FirstRungPct + $i * $RungSpacingPct
}

Write-Host ""
Write-Host "=== Speed Ladder Sell ===" -ForegroundColor Yellow
Write-Host "  Chain         : $Chain"
Write-Host "  Token         : $TokenLabel  (decimals: $tokenDecimals)"
Write-Host "  ETH spent     : $Amount ETH"
Write-Host "  Rungs         : $Rungs  (sell 1/$Rungs of position per rung)"
Write-Host "  Rung targets  : $($rungTargetPcts | ForEach-Object { "+$_%" } | Join-String -Separator ', ')"
Write-Host "  Poll interval : $PollSeconds s"
Write-Host "  Max polls     : $MaxIterations"
Write-Host ""

# ── step 1: quote the buy ─────────────────────────────────────────────────────

Write-Host "Step 1 - Quoting ETH -> $TokenLabel for $Amount ETH..." -ForegroundColor DarkCyan

$buyQuote   = Get-Quote -sellTok 'eth' -buyTok $Token -sellAmt $Amount
$tokenRaw   = [double]$buyQuote.buyAmount
$tokenHuman = $tokenRaw / $TOKEN_SCALE
$tokenStr   = $tokenHuman.ToString("F$tokenDecimals")

if ([double]$tokenStr -le 0) {
    Write-Error "Token amount resolved to 0 (raw=$tokenRaw, decimals=$tokenDecimals). Aborting."
    exit 1
}

Write-Host ("  You will get : {0} {1} for {2} ETH" -f $tokenStr, $TokenLabel, $Amount)
Write-Host ""

# ── step 2: execute the buy ───────────────────────────────────────────────────

Write-Host "Step 2 - Buying $TokenLabel..." -ForegroundColor DarkCyan
Write-Host ">>> Executing: speed swap -c $Chain --sell eth --buy $Token -a $Amount -y" -ForegroundColor Cyan
speed swap -c $Chain --sell eth --buy $Token -a $Amount -y
if ($LASTEXITCODE -ne 0) {
    Write-Error "Buy swap failed (exit $LASTEXITCODE). Aborting."
    exit $LASTEXITCODE
}
Write-Host ""

# ── step 3: baseline sell quote — anchors rung targets ────────────────────────

Write-Host "Step 3 - Baseline sell quote ($TokenLabel -> ETH)..." -ForegroundColor DarkCyan

$sellQuote   = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $tokenStr
$baselineRaw = [double]$sellQuote.buyAmount
$baselineETH = $baselineRaw / $ETH_DECIMALS

Write-Host ("  Baseline ETH back : {0:F8} ETH" -f $baselineETH)
Write-Host ""

# ── build rung objects ────────────────────────────────────────────────────────

# Each rung sells an equal fraction of the original token amount
$rungTokenHuman = $tokenHuman / $Rungs
$rungTokenStr   = $rungTokenHuman.ToString("F$tokenDecimals")

if ([double]$rungTokenStr -le 0) {
    Write-Error "Rung token amount resolved to 0 (tokenStr=$tokenStr, Rungs=$Rungs). Aborting."
    exit 1
}

$rungs = @()
for ($i = 0; $i -lt $Rungs; $i++) {
    $pct        = $rungTargetPcts[$i]
    $targetRaw  = $baselineRaw * (1.0 + $pct / 100.0)
    $targetETH  = $targetRaw / $ETH_DECIMALS
    $rungs += [PSCustomObject]@{
        Index     = $i
        TargetPct = $pct
        TargetRaw = $targetRaw
        TargetETH = $targetETH
        Sold      = $false
    }
    Write-Host ("  Rung {0}: sell 1/{1} of position at +{2}%  (target: {3:F8} ETH for full position)" -f `
        $i, $Rungs, $pct, $targetETH) -ForegroundColor DarkGray
}
Write-Host ""

# Running tallies
$soldRungs     = 0
$totalEthBack  = 0.0

# ── step 4: poll for rung targets ─────────────────────────────────────────────

Write-Host "Step 4 - Monitoring. Waiting for rung targets..." -ForegroundColor DarkCyan
Write-Host ""

$iteration = 0

while ($iteration -lt $MaxIterations) {
    $iteration++
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] Poll $iteration / $MaxIterations - waiting $PollSeconds s..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $PollSeconds

    try {
        # Quote full position as price oracle
        $q          = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $tokenStr
        $currentRaw = [double]$q.buyAmount
        $currentETH = $currentRaw / $ETH_DECIMALS
        $pctVsBase  = (($currentRaw - $baselineRaw) / $baselineRaw) * 100.0
        $ts2        = Get-Date -Format "HH:mm:ss"

        # Determine color: above highest unfired rung target = green, near first target = yellow
        $nextRung = $rungs | Where-Object { -not $_.Sold } | Sort-Object TargetRaw | Select-Object -First 1
        if ($null -eq $nextRung) {
            $color = "Green"
        } elseif ($currentRaw -ge $nextRung.TargetRaw) {
            $color = "Green"
        } elseif ($pctVsBase -gt 0) {
            $color = "White"
        } else {
            $color = "DarkRed"
        }

        $soldStatus = "($soldRungs/$Rungs sold)"
        Write-Host ("[$ts2] Full pos: {0:F8} ETH  ({1:+0.0000}% vs baseline)  {2}" -f $currentETH, $pctVsBase, $soldStatus) -ForegroundColor $color

        # Process rungs in order (lowest target first)
        foreach ($rung in ($rungs | Sort-Object TargetRaw)) {
            if ($rung.Sold) { continue }
            if ($currentRaw -ge $rung.TargetRaw) {
                $gainPct = (($currentRaw - $baselineRaw) / $baselineRaw) * 100.0
                Write-Host ""
                Write-Host ("Rung {0} target hit! +{1:F4}% gain. Selling 1/{2} of position ({3} {4})..." -f `
                    $rung.Index, $gainPct, $Rungs, $rungTokenStr, $TokenLabel) -ForegroundColor Green
                try {
                    Invoke-RungSell -tokenAmount $rungTokenStr -rungIndex $rung.Index -targetPct $rung.TargetPct
                    $rung.Sold    = $true
                    $soldRungs++
                    $totalEthBack += $rungTokenStr * ($baselineRaw / $tokenHuman / $ETH_DECIMALS)  # approximate
                    Write-Host ("  Rung {0} sold. {1}/{2} rungs complete." -f $rung.Index, $soldRungs, $Rungs) -ForegroundColor DarkGray
                    Write-Host ""
                } catch {
                    Write-Warning "Rung $($rung.Index) sell failed: $_ -- will retry next poll."
                }
            }
        }

        # All rungs fired — exit
        if ($soldRungs -ge $Rungs) {
            Write-Host ""
            Write-Host "All $Rungs rungs sold. Ladder complete." -ForegroundColor Green
            exit 0
        }

    } catch {
        Write-Warning "Quote failed on poll $iteration : $_ - retrying next interval."
    }
}

# ── max iterations: sell remaining tokens ─────────────────────────────────────

$remainingRungs = $rungs | Where-Object { -not $_.Sold }
$remainingCount = ($remainingRungs | Measure-Object).Count

Write-Host ""
Write-Host "Max iterations ($MaxIterations) reached. Selling $remainingCount remaining rung(s)..." -ForegroundColor Yellow

foreach ($rung in $remainingRungs) {
    Write-Host ("  Selling rung {0}: {1} {2}" -f $rung.Index, $rungTokenStr, $TokenLabel) -ForegroundColor Cyan
    try {
        Invoke-RungSell -tokenAmount $rungTokenStr -rungIndex $rung.Index -targetPct $rung.TargetPct
        $rung.Sold = $true
        $soldRungs++
    } catch {
        Write-Warning "Final sell failed for rung $($rung.Index): $_ -- manual sell required."
    }
}

Write-Host ""
Write-Host "=== Ladder Sell Session Complete ===" -ForegroundColor Yellow
Write-Host ("  Rungs sold : {0} / {1}" -f $soldRungs, $Rungs)
