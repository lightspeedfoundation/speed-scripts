<#
.SYNOPSIS
    Grid trading bot: place N buy levels below current price, sell each when price
    recovers one grid step. Profits from price oscillation in a ranging market.

.DESCRIPTION
    1. Auto-detects token decimals via on-chain RPC call.
    2. Quotes -EthPerGrid ETH -> <Token> to determine refTokenAmount and establish
       basePrice (Token -> ETH quote for that reference amount).
    3. Builds -Levels grid cells below current price, spaced -GridPct % apart.
       Cell i:  BuyLevel  = basePrice * (1 - (i+1) * GridPct/100)
                SellLevel = basePrice * (1 - i     * GridPct/100)
    4. Polls every -PollSeconds seconds:
         - Processes sells first  (fills where currentPrice >= SellLevel)
         - Then processes buys    (pending cells where currentPrice <= BuyLevel)
         - Highest-priced buy levels fill first (closest to current price)
    5. Prints a live grid status table and running P&L after every poll.
    6. On -MaxIterations: sells all filled cells and exits.

    Use -DryRun to simulate without executing any swaps.

.PARAMETER Chain
    Chain name or ID (base, ethereum, arbitrum, optimism, polygon, bnb).

.PARAMETER Token
    Token contract address or shorthand alias ('speed').
    ETH is always the quote currency.

.PARAMETER EthPerGrid
    ETH to spend at each buy level (min ~0.0001 ETH to avoid 0x dust rejection).

.PARAMETER Levels
    Number of grid cells to create below current price.

.PARAMETER GridPct
    Percentage spacing between grid levels (e.g. 2 = 2% between each level).

.PARAMETER TokenSymbol
    Optional display label for the token. Defaults to the address.

.PARAMETER PollSeconds
    Seconds between price polls. Default 60.

.PARAMETER MaxIterations
    Maximum number of polls before forcing an exit sell. Default 2880 (~48 h at 60 s).

.PARAMETER DryRun
    Print what would happen without executing any swaps.

.EXAMPLE
    .\grid-trade-any.ps1 -Chain base -Token speed -EthPerGrid 0.001 -Levels 5 -GridPct 2
    .\grid-trade-any.ps1 -Chain base -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf -TokenSymbol cbBTC -EthPerGrid 0.002 -Levels 3 -GridPct 1.5 -PollSeconds 30
    .\grid-trade-any.ps1 -Chain base -Token speed -EthPerGrid 0.001 -Levels 4 -GridPct 2 -DryRun
#>

param(
    [Parameter(Mandatory)][string] $Chain,
    [Parameter(Mandatory)][string] $Token,
    [Parameter(Mandatory)][string] $EthPerGrid,
    [Parameter(Mandatory)][int]    $Levels,
    [Parameter(Mandatory)][double] $GridPct,
    [string]                       $TokenSymbol   = "",
    [int]                          $PollSeconds   = 60,
    [int]                          $MaxIterations = 2880,
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

# P&L accumulators (script-scope so helpers can update them)
$script:totalEthSpent    = 0.0
$script:totalEthReceived = 0.0
$script:totalBuys        = 0
$script:totalSells       = 0

# -- helpers ------------------------------------------------------------------

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

function Invoke-Buy {
    # Quotes first to get expected token amount, then executes the swap.
    # Returns the quoted token amount string (used as cell's held balance).
    param([string]$ethAmount, [int]$cellIndex)

    $q          = Get-Quote -sellTok 'eth' -buyTok $Token -sellAmt $ethAmount
    $tokenRaw   = [double]$q.buyAmount
    $tokenHuman = $tokenRaw / $script:TOKEN_DECIMALS_SCALE
    $tokenStr   = $tokenHuman.ToString("F$script:tokenDecimals")

    if ([double]$tokenStr -le 0) { throw "Token amount resolved to 0 for cell $cellIndex." }

    if ($DryRun) {
        Write-Host ("  [DRY-RUN] Cell {0}: would BUY {1} {2} for {3} ETH" -f $cellIndex, $tokenStr, $script:TokenLabel, $ethAmount) -ForegroundColor DarkYellow
    } else {
        Write-Host ("  >>> Cell {0} BUY: speed swap -c {1} --sell eth --buy {2} -a {3} -y" -f $cellIndex, $Chain, $Token, $ethAmount) -ForegroundColor Cyan
        $raw  = speed --json --yes swap -c $Chain --sell eth --buy $Token -a $ethAmount 2>&1
        $line = $raw | Where-Object { $_ -match '^\{' } | Select-Object -First 1
        $res  = $line | ConvertFrom-Json
        if ($res.PSObject.Properties.Name -contains 'error') { throw "Buy swap failed: $($res.error)" }
        Write-Host ("  TX: {0}" -f $res.txHash) -ForegroundColor DarkGray
    }

    $script:totalEthSpent += [double]$ethAmount
    $script:totalBuys++
    return $tokenStr
}

function Invoke-Sell {
    # Executes a sell swap and accumulates received ETH.
    # Does NOT call exit -- grid continues after each sell.
    param([string]$tokenAmount, [int]$cellIndex)

    if ($DryRun) {
        Write-Host ("  [DRY-RUN] Cell {0}: would SELL {1} {2} -> ETH" -f $cellIndex, $tokenAmount, $script:TokenLabel) -ForegroundColor DarkYellow
        # Estimate received ETH for P&L display in dry-run
        try {
            $q   = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $tokenAmount
            $eth = [double]$q.buyAmount / $ETH_DECIMALS
            $script:totalEthReceived += $eth
        } catch { }
    } else {
        Write-Host ("  >>> Cell {0} SELL: speed swap -c {1} --sell {2} --buy eth -a {3} -y" -f $cellIndex, $Chain, $Token, $tokenAmount) -ForegroundColor Cyan
        $raw  = speed --json --yes swap -c $Chain --sell $Token --buy eth -a $tokenAmount 2>&1
        $line = $raw | Where-Object { $_ -match '^\{' } | Select-Object -First 1
        $res  = $line | ConvertFrom-Json
        if ($res.PSObject.Properties.Name -contains 'error') { throw "Sell swap failed: $($res.error)" }
        Write-Host ("  TX: {0}" -f $res.txHash) -ForegroundColor DarkGray

        # Quote to estimate ETH received for P&L (actual amount varies by slippage)
        try {
            $qCheck = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $tokenAmount
            $script:totalEthReceived += [double]$qCheck.buyAmount / $ETH_DECIMALS
        } catch {
            # Fallback: assume sell level ETH
        }
    }

    $script:totalSells++
}

function Show-Grid {
    param([double]$currentETH, [double]$baseETH, [array]$cells)

    $pctFromBase = if ($baseETH -gt 0) { (($currentETH - $baseETH) / $baseETH) * 100.0 } else { 0.0 }
    $pl          = $script:totalEthReceived - $script:totalEthSpent
    $plSign      = if ($pl -ge 0) { "+" } else { "" }
    $plColor     = if ($pl -ge 0) { "Green" } elseif ($pl -gt -0.0001) { "White" } else { "DarkRed" }

    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host ""
    Write-Host ("[{0}] Price: {1:F8} ETH  (base: {2:F8}, {3:+0.00}%)  Buys: {4}  Sells: {5}" -f `
        $ts, $currentETH, $baseETH, $pctFromBase, $script:totalBuys, $script:totalSells) -ForegroundColor White
    Write-Host ("          P/L: {0}{1:F8} ETH   Spent: {2:F8} ETH   Received: {3:F8} ETH" -f `
        $plSign, $pl, $script:totalEthSpent, $script:totalEthReceived) -ForegroundColor $plColor
    Write-Host ""
    Write-Host ("  {0,-3}  {1,-14}  {2,-14}  {3,-12}  {4,-20}  {5}" -f `
        "#", "Buy Level ETH", "Sell Level ETH", "Status", "Token Held", "ETH Spent") -ForegroundColor DarkGray
    Write-Host ("  {0,-3}  {1,-14}  {2,-14}  {3,-12}  {4,-20}  {5}" -f `
        "-", "--------------", "--------------", "------------", "--------------------", "---------") -ForegroundColor DarkGray

    foreach ($cell in $cells) {
        $buyETH  = $cell.BuyLevelRaw / $ETH_DECIMALS
        $sellETH = $cell.SellLevelRaw / $ETH_DECIMALS

        if ($cell.Status -eq "filled") {
            $statusStr = "FILLED  *"
            $heldStr   = "$($cell.TokenHeldStr) $script:TokenLabel"
            $spentStr  = $cell.EthSpent.ToString("F8")
            $color     = "Cyan"
        } else {
            # Warn if price is within one grid step of triggering
            $distancePct = if ($buyETH -gt 0) { (($currentETH - $buyETH) / $buyETH) * 100.0 } else { 999.0 }
            $statusStr = "waiting"
            $heldStr   = "-"
            $spentStr  = "-"
            $color     = if ($distancePct -le $GridPct) { "DarkYellow" } else { "White" }
        }

        Write-Host ("  {0,-3}  {1,-14}  {2,-14}  {3,-12}  {4,-20}  {5}" -f `
            $cell.Index, $buyETH.ToString("F8"), $sellETH.ToString("F8"), `
            $statusStr, $heldStr, $spentStr) -ForegroundColor $color
    }
    Write-Host ""
}

# -- setup --------------------------------------------------------------------

Write-Host ""
Write-Host "Detecting token decimals..." -ForegroundColor DarkGray
$tokenDecimals             = Get-TokenDecimals -tokenAddr $Token -chainName $Chain
$script:tokenDecimals      = $tokenDecimals
$script:TOKEN_DECIMALS_SCALE = [Math]::Pow(10, $tokenDecimals)
$script:TokenLabel         = if ($TokenSymbol -ne "") { $TokenSymbol } else { $Token }

Write-Host ""
Write-Host "=== Speed Grid Trading Bot ===" -ForegroundColor Yellow
if ($DryRun) { Write-Host "  *** DRY-RUN MODE -- no swaps will execute ***" -ForegroundColor DarkYellow }
Write-Host "  Chain         : $Chain"
Write-Host "  Token         : $script:TokenLabel  (decimals: $tokenDecimals)"
Write-Host "  ETH per grid  : $EthPerGrid ETH"
Write-Host "  Grid levels   : $Levels  (buy levels below current price)"
Write-Host "  Grid spacing  : $GridPct %"
Write-Host "  Max ETH outlay: $(([double]$EthPerGrid * $Levels).ToString("F8")) ETH (if all levels fill)"
Write-Host "  Poll interval : $PollSeconds s"
Write-Host "  Max polls     : $MaxIterations"
Write-Host ""

# Step 1: quote EthPerGrid ETH -> Token to get refTokenAmount
Write-Host "Step 1 - Quoting $EthPerGrid ETH -> $script:TokenLabel to get reference amount..." -ForegroundColor DarkCyan
$buyQuote      = Get-Quote -sellTok 'eth' -buyTok $Token -sellAmt $EthPerGrid
$refTokenRaw   = [double]$buyQuote.buyAmount
$refTokenHuman = $refTokenRaw / $script:TOKEN_DECIMALS_SCALE
$refTokenStr   = $refTokenHuman.ToString("F$tokenDecimals")

if ([double]$refTokenStr -le 0) {
    Write-Error "Reference token amount resolved to 0. Aborting."
    exit 1
}
Write-Host ("  Reference amount : {0} {1} (per {2} ETH grid)" -f $refTokenStr, $script:TokenLabel, $EthPerGrid)

# Step 2: quote refTokenAmount Token -> ETH to establish basePrice
Write-Host ""
Write-Host "Step 2 - Quoting $script:TokenLabel -> ETH to establish base price..." -ForegroundColor DarkCyan
$sellQuote = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $refTokenStr
$baseRaw   = [double]$sellQuote.buyAmount
$baseETH   = $baseRaw / $ETH_DECIMALS

Write-Host ("  Base price : {0:F8} ETH (for {1} {2})" -f $baseETH, $refTokenStr, $script:TokenLabel)
Write-Host ""

# Step 3: build grid cells
Write-Host "Step 3 - Building grid..." -ForegroundColor DarkCyan

$gridCells = @()
for ($i = 0; $i -lt $Levels; $i++) {
    $buyRaw  = $baseRaw * (1.0 - ($i + 1) * $GridPct / 100.0)
    $sellRaw = $baseRaw * (1.0 - $i       * $GridPct / 100.0)
    $gridCells += [PSCustomObject]@{
        Index        = $i
        BuyLevelRaw  = $buyRaw
        SellLevelRaw = $sellRaw
        Status       = "pending_buy"
        TokenHeldStr = ""
        EthSpent     = 0.0
    }
    Write-Host ("  Cell {0}: buy at or below {1:F8} ETH  |  sell at or above {2:F8} ETH" -f `
        $i, ($buyRaw / $ETH_DECIMALS), ($sellRaw / $ETH_DECIMALS)) -ForegroundColor DarkGray
}
Write-Host ""

# Show initial grid
Show-Grid -currentETH $baseETH -baseETH $baseETH -cells $gridCells

# -- poll loop ----------------------------------------------------------------

$iteration = 0

while ($iteration -lt $MaxIterations) {
    $iteration++
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] Poll $iteration / $MaxIterations  - waiting $PollSeconds s..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $PollSeconds

    try {
        $q          = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $refTokenStr
        $currentRaw = [double]$q.buyAmount
        $currentETH = $currentRaw / $ETH_DECIMALS

        # -- process sells first (recoup ETH before spending on new buys) ------
        foreach ($cell in ($gridCells | Where-Object { $_.Status -eq "filled" })) {
            if ($currentRaw -ge $cell.SellLevelRaw) {
                $sellETH = $cell.SellLevelRaw / $ETH_DECIMALS
                Write-Host ("  Cell {0}: SELL triggered  (price {1:F8} / sell level {2:F8})" -f `
                    $cell.Index, $currentETH, $sellETH) -ForegroundColor Green
                try {
                    Invoke-Sell -tokenAmount $cell.TokenHeldStr -cellIndex $cell.Index
                    $cell.Status       = "pending_buy"
                    $cell.TokenHeldStr = ""
                    $cell.EthSpent     = 0.0
                } catch {
                    Write-Warning "Sell failed for cell $($cell.Index): $_ -- keeping as filled."
                }
            }
        }

        # -- process buys: highest buy level first (closest to current price) --
        $pendingCells = $gridCells | Where-Object { $_.Status -eq "pending_buy" } |
                        Sort-Object BuyLevelRaw -Descending

        foreach ($cell in $pendingCells) {
            if ($currentRaw -le $cell.BuyLevelRaw) {
                $buyETH = $cell.BuyLevelRaw / $ETH_DECIMALS
                Write-Host ("  Cell {0}: BUY triggered  (price {1:F8} / buy level {2:F8})" -f `
                    $cell.Index, $currentETH, $buyETH) -ForegroundColor Magenta
                try {
                    $tokenStr            = Invoke-Buy -ethAmount $EthPerGrid -cellIndex $cell.Index
                    $cell.Status         = "filled"
                    $cell.TokenHeldStr   = $tokenStr
                    $cell.EthSpent       = [double]$EthPerGrid
                } catch {
                    Write-Warning "Buy failed for cell $($cell.Index): $_ -- skipping."
                }
            }
        }

        Show-Grid -currentETH $currentETH -baseETH $baseETH -cells $gridCells

    } catch {
        Write-Warning "Poll $iteration failed: $_ -- retrying next interval."
    }
}

# -- max iterations: sell all filled cells ------------------------------------

Write-Host ""
Write-Host "Max iterations ($MaxIterations) reached. Selling all filled positions..." -ForegroundColor Yellow

foreach ($cell in ($gridCells | Where-Object { $_.Status -eq "filled" })) {
    Write-Host ("  Selling cell {0}: {1} {2}" -f $cell.Index, $cell.TokenHeldStr, $script:TokenLabel) -ForegroundColor Cyan
    try {
        Invoke-Sell -tokenAmount $cell.TokenHeldStr -cellIndex $cell.Index
        $cell.Status       = "pending_buy"
        $cell.TokenHeldStr = ""
        $cell.EthSpent     = 0.0
    } catch {
        Write-Warning "Final sell failed for cell $($cell.Index): $_ -- manual sell required."
    }
}

$pl     = $script:totalEthReceived - $script:totalEthSpent
$plSign = if ($pl -ge 0) { "+" } else { "" }
Write-Host ""
Write-Host "=== Grid Session Complete ===" -ForegroundColor Yellow
Write-Host ("  Total buys      : {0}" -f $script:totalBuys)
Write-Host ("  Total sells     : {0}" -f $script:totalSells)
Write-Host ("  ETH spent       : {0:F8} ETH" -f $script:totalEthSpent)
Write-Host ("  ETH received    : {0:F8} ETH" -f $script:totalEthReceived)
$plColor2 = if ($pl -ge 0) { "Green" } else { "DarkRed" }
Write-Host ("  Net P/L         : {0}{1:F8} ETH" -f $plSign, $pl) -ForegroundColor $plColor2
