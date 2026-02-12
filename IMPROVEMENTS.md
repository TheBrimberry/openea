# FxChartAI OpenEA v2.0 — Improvement Report

## Overview

This document details all improvements made to the FxChartAI OpenEA, incorporating best practices and logic patterns from five high-quality open-source trading EAs analyzed during this upgrade.

---

## Source EAs Analyzed

| EA Project | Key Logic Borrowed | GitHub |
|---|---|---|
| **Astralchemist EA** | Dynamic lot sizing, daily loss limits, spread filter, fractal S/R, breakeven at 1:1 R:R | Astralchemist/Expert-Advisor-trading-bot |
| **ICT EA** | Order block detection, weekly open bias, session filtering, MA trend confirmation | darula-hpp/ict-ea |
| **GOLD_ORB** | Modular risk management, ATR trailing stops, equity drawdown protection, loss streak detection, virtual trade environment | yulz008/GOLD_ORB |
| **TyphooN NNFX** | VaR-based risk modes, auto-protect, partial close, pyramid mode, comprehensive UI | TyphooN-/MQL5-NNFX-Risk_Management_System |
| **Daedalus ATM** | Advanced trade management, auto breakeven, auto partial exit | daedalusfx/advance-trade-management |

---

## Improvements Summary

### 1. Dynamic Position Sizing (was: Fixed Lot Size)

**Before:** `input double LotSize = 1;` — Fixed lot size regardless of account size or risk.

**After:** Risk-based lot calculation using account equity, ATR-based stop loss distance, tick value, and broker volume constraints. Includes a 5% safety cap per trade.

**Source:** Astralchemist EA `CalculateLotSize()` + GOLD_ORB `MoneyManagement()`

```
lotSize = riskAmount / (riskInTicks * tickValue)
```

### 2. ATR-Based Stop Loss & Take Profit (was: Fixed Pips)

**Before:** `input int StopLossPips = 400; input int TakeProfitPips = 500;` — Static values that don't adapt to volatility.

**After:** SL and TP calculated as multiples of ATR (default 1.5x ATR for SL, 2.5x ATR for TP). Automatically adapts to current market volatility.

**Source:** GOLD_ORB trailing stop concept + TyphooN ATR projection

### 3. Spread Filter (was: None)

**Before:** No spread check — could enter trades during high-spread conditions (news events, low liquidity).

**After:** Real-time spread check before every trade entry. Configurable maximum spread in points (default: 30 points).

**Source:** Astralchemist EA `IsSpreadAcceptable()`

### 4. Daily Loss Limit (was: None)

**Before:** No daily loss protection — could keep losing indefinitely.

**After:** Tracks daily starting balance and halts all new trades when daily loss exceeds configurable threshold (default: 3%). Resets automatically at start of each new trading day.

**Source:** Astralchemist EA `CheckDailyLossLimit()`

### 5. Maximum Drawdown Protection (was: None)

**Before:** No equity drawdown circuit breaker.

**After:** Tracks peak equity and halts trading when drawdown from peak exceeds threshold (default: 10%).

**Source:** GOLD_ORB `MaxEquityDrawdownPercent` + equity monitoring module

### 6. Session Filter (was: None)

**Before:** Traded at any time, including low-liquidity periods and Friday close.

**After:** Configurable trading session hours (default: 02:00-20:00 server time). Optional Friday close avoidance (no new trades after 18:00 Friday).

**Source:** ICT EA session-based trading logic

### 7. Multi-Timeframe Confirmation (was: Single Timeframe Only)

**Before:** Only traded on the chart timeframe with no cross-timeframe validation.

**After:** When trading on M10, optionally requires H1 trend confirmation via Fast/Slow MA crossover. Prevents trading against the higher-timeframe trend.

**Source:** ICT EA `isBullish()`/`isBearish()` MA confirmation

### 8. Breakeven Management (was: None)

**Before:** No breakeven logic — positions either hit SL or TP.

**After:** Automatically moves SL to entry price (+ 1 point buffer) when position reaches 1:1 R:R. Tracked per-position to avoid repeated modifications.

**Source:** Astralchemist EA `ManagePositions()` breakeven logic

### 9. Partial Close (was: None)

**Before:** All-or-nothing position management.

**After:** Closes configurable percentage (default: 50%) of position at 1:1 R:R, then moves remaining to breakeven. Locks in profit while letting winners run.

**Source:** TyphooN NNFX `ClosePartial` + Daedalus ATM `Auto Partial Exit`

### 10. ATR-Based Trailing Stop (was: Fixed Pip Trailing)

**Before:** Simple trailing based on candle count (minor trail at 1-3 candles, major trail at 4+) with fixed pip distance.

**After:** ATR-based trailing stop that adapts to current volatility. Trail distance = ATR × configurable multiplier. Only activates after configurable number of candles in profit.

**Source:** GOLD_ORB `CTrailing::TrailingStop()` + earnforex ATR trailing concept

### 11. Order Block Detection (was: None)

**Before:** No institutional/smart money concepts.

**After:** Detects order blocks (candles with body > 50% of total range) as additional confirmation for trade entries. When present, slightly tightens SL for better R:R.

**Source:** ICT EA `isOrderBlock()`

### 12. Signal Strength Weighting (was: Ignored Weight Data)

**Before:** The `TREND_WEIGHT` field from FxChartAI signals was stored but never used in trade decisions.

**After:** Calculates weighted signal strength using both the weight field (HIGH=2x, LOW=1x) and recency (more recent signals weighted higher). Requires minimum strength threshold.

### 13. Improved Trendline Check (was: Unused Function)

**Before:** `CheckTrendline()` existed but was never called in `AnalyzeAndTrade()`.

**After:** Trendline check now properly finds swing points and validates slope direction. Used as optional additional confirmation alongside order blocks.

### 14. Proper Position Counting (was: Global PositionsTotal)

**Before:** `if(PositionsTotal() > 0) return;` — blocked trading if ANY position existed, even from other EAs.

**After:** `CountMyPositions()` counts only positions matching this EA's MagicNumber AND symbol. Configurable max positions.

### 15. Order Expiration (was: No Expiration)

**Before:** Pending orders had no expiration — could remain indefinitely.

**After:** Pending orders automatically expire after 2 bars of the current timeframe.

### 16. Proper Indicator Handle Management (was: None)

**Before:** No indicator handles — used direct `iOpen/iClose/iHigh/iLow` calls only.

**After:** Proper ATR and MA indicator handles created in `OnInit()`, released in `OnDeinit()`. Prevents memory leaks.

### 17. CTrade Library Usage (was: Raw MqlTradeRequest)

**Before:** Manual `MqlTradeRequest`/`MqlTradeResult` construction for every operation.

**After:** Uses MQL5 `CTrade` library for cleaner, more reliable trade operations with built-in error handling and retry logic.

### 18. Comprehensive Logging (was: Minimal)

**Before:** Basic `Print()` statements.

**After:** Togglable detailed logging with categorized prefixes (TRADE, RISK, DATA, TRAIL, etc.) for easier debugging.

### 19. Bug Fixes

- **Line 529 operator precedence bug:** The original had `(ENUM_ORDER_TYPE)(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY` — the cast applied only to the boolean comparison, not the ternary result. Fixed.
- **Redundant TP/SL check removed:** The original `ManageOpenOrders` manually checked if price hit TP/SL, but MT5 handles this natively via the order's SL/TP levels.
- **Typo fixes:** "Perforrm" → "Perform", "orderrr" → "order"

---

## File Deliverables

| File | Platform | Description |
|---|---|---|
| `fxchartai_openea_v2.mq5` | MetaTrader 5 | Improved MQL5 Expert Advisor |
| `fxchartai_strategy_v2.pine` | TradingView | Pine Script v6 strategy port |
| `IMPROVEMENTS.md` | Documentation | This improvement report |

---

## Recommended Settings

### Conservative (Low Risk)
| Parameter | Value |
|---|---|
| RiskPercent | 0.5% |
| ATR_SL_Multiplier | 2.0 |
| ATR_TP_Multiplier | 3.0 |
| MaxDailyLossPercent | 2.0% |
| ConfidenceLevel | 4 |
| RequireMTFConfirm | true |

### Balanced (Default)
| Parameter | Value |
|---|---|
| RiskPercent | 1.0% |
| ATR_SL_Multiplier | 1.5 |
| ATR_TP_Multiplier | 2.5 |
| MaxDailyLossPercent | 3.0% |
| ConfidenceLevel | 3 |
| RequireMTFConfirm | true |

### Aggressive (Higher Risk)
| Parameter | Value |
|---|---|
| RiskPercent | 2.0% |
| ATR_SL_Multiplier | 1.0 |
| ATR_TP_Multiplier | 2.0 |
| MaxDailyLossPercent | 5.0% |
| ConfidenceLevel | 2 |
| RequireMTFConfirm | false |

---

## Installation

### MetaTrader 5
1. Copy `fxchartai_openea_v2.mq5` to `MQL5/Experts/` folder
2. Ensure `JAson.mqh` is in `MQL5/Include/` folder
3. Compile in MetaEditor
4. Attach to GBPUSD chart (M10 or H1 timeframe)
5. Enable "Allow Algo Trading" and add `chartapi.fxchartai.com` to allowed URLs

### TradingView
1. Open Pine Script Editor
2. Paste contents of `fxchartai_strategy_v2.pine`
3. Add to GBPUSD chart
4. Configure inputs as needed
5. Note: TradingView version simulates signal confirmation using candle streaks since external API signals are not available in Pine Script
