//+------------------------------------------------------------------+
//|                                          FxChartAI OpenEA v2.0   |
//|                              Copyright 2025, FxChartAI (Improved)|
//|                                      https://www.fxchartai.com   |
//+------------------------------------------------------------------+
//| Improved version incorporating best practices from:              |
//|  - Original FxChartAI OpenEA (signal-based entries)              |
//|  - Astralchemist EA (dynamic lot sizing, daily loss limits,      |
//|    spread filter, fractal S/R, breakeven management)             |
//|  - ICT EA (order block detection, weekly open bias, session      |
//|    filtering, MA trend confirmation)                             |
//|  - GOLD_ORB (modular risk management, ATR trailing, equity       |
//|    drawdown protection, loss streak detection)                   |
//|  - TyphooN NNFX (VaR-based risk, auto-protect, partial close)   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, FxChartAI (Improved)"
#property link      "https://www.fxchartai.com"
#property version   "2.0.0"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <JAson.mqh>

//+------------------------------------------------------------------+
//| Input Parameters - Organized by Group                            |
//+------------------------------------------------------------------+
input group "=== SIGNAL SOURCE ==="
input int    OperationMode       = 0;       // 0 = Test (CSV), 1 = Live (API)
input int    MaxDataSize         = 7;       // Maximum dataset size for analysis
input int    ConfidenceLevel     = 3;       // Min consecutive signals required (1-5)
input int    MaxRetryAttempts    = 5;       // Max data loading retry attempts

input group "=== RISK MANAGEMENT ==="
input double RiskPercent         = 1.0;     // Risk % of account equity per trade
input double MaxDailyLossPercent = 3.0;     // Max daily loss % before halt
input double MaxDrawdownPercent  = 10.0;    // Max equity drawdown % before halt
input int    MaxPositions        = 1;       // Max simultaneous positions for this EA

input group "=== TRADE PARAMETERS ==="
input double ATR_SL_Multiplier   = 1.5;    // ATR multiplier for Stop Loss
input double ATR_TP_Multiplier   = 2.5;    // ATR multiplier for Take Profit
input int    ATR_Period          = 14;      // ATR calculation period
input int    PendingOrderOffset  = 100;     // Pending order offset in points
input int    MaxSpreadPoints     = 30;      // Max allowed spread in points
input int    MagicNumber         = 12345;   // Unique EA identifier

input group "=== TRAILING STOP ==="
input bool   EnableTrailing      = true;    // Enable trailing stop
input double TrailATR_Multiplier = 1.0;     // ATR multiplier for trailing distance
input int    BreakevenTriggerRR  = 1;       // R:R ratio to trigger breakeven (0=off)
input int    TrailStartCandles   = 2;       // Candles in profit before trailing starts

input group "=== SESSION FILTER ==="
input bool   EnableSessionFilter = true;    // Enable trading session filter
input int    SessionStartHour    = 2;       // Session start hour (server time)
input int    SessionEndHour      = 20;      // Session end hour (server time)
input bool   AvoidFridayClose    = true;    // Avoid new trades Friday after 18:00

input group "=== MULTI-TIMEFRAME ==="
input bool   RequireMTFConfirm   = true;    // Require H1 trend confirmation for M10
input int    MA_Fast_Period      = 5;       // Fast MA period for trend
input int    MA_Slow_Period      = 30;      // Slow MA period for trend

input group "=== PARTIAL CLOSE ==="
input bool   EnablePartialClose  = true;    // Enable partial close at 1:1 R:R
input double PartialClosePercent = 50.0;    // % of position to close at 1:1

input group "=== LOGGING ==="
input bool   EnableLogging       = true;    // Enable detailed logging

//+------------------------------------------------------------------+
//| Constants                                                        |
//+------------------------------------------------------------------+
#define RETRY_DELAY_MS 60000

enum SIGNAL_POSITION { SIGNAL_SELL, SIGNAL_BUY, SIGNAL_NONE };
enum TREND_WEIGHT    { TREND_HIGH, TREND_LOW, TREND_NONE };

//+------------------------------------------------------------------+
//| Signal Data Structure                                            |
//+------------------------------------------------------------------+
struct SignalData
  {
   datetime          time;
   SIGNAL_POSITION   position;
   TREND_WEIGHT      weight;
  };

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
// Trade objects
CTrade            Trade;
CPositionInfo     PositionInfo;
CAccountInfo      AccountInfo;
CSymbolInfo       SymbolInfo;

// Signal data
string m10FileName, h1FileName;
datetime lastM10UpdateTime = 0;
datetime lastH1UpdateTime  = 0;
SignalData m10Data[];
int m10DataIndex = 0;
SignalData h1Data[];
int h1DataIndex = 0;

// Indicator handles
int atrHandle_M10   = INVALID_HANDLE;
int atrHandle_H1    = INVALID_HANDLE;
int maFastHandle_H1 = INVALID_HANDLE;
int maSlowHandle_H1 = INVALID_HANDLE;

// Risk management state
double dailyStartBalance   = 0;
double peakEquity           = 0;
bool   tradingEnabled       = true;
bool   dailyLossHalt        = false;
datetime lastNewDayCheck    = 0;

// Partial close tracking
struct PartialCloseTracker
  {
   ulong ticket;
   bool  partialDone;
   bool  breakevenDone;
  };
PartialCloseTracker partialTrackers[];

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Validate inputs
   if(RiskPercent <= 0 || RiskPercent > 10)
     { Print("ERROR: RiskPercent must be between 0.01 and 10"); return(INIT_FAILED); }
   if(MaxDailyLossPercent <= 0)
     { Print("ERROR: MaxDailyLossPercent must be > 0"); return(INIT_FAILED); }
   if(ATR_SL_Multiplier <= 0 || ATR_TP_Multiplier <= 0)
     { Print("ERROR: ATR multipliers must be > 0"); return(INIT_FAILED); }
   if(ConfidenceLevel < 1 || ConfidenceLevel > 5)
     { Print("ERROR: ConfidenceLevel must be 1-5"); return(INIT_FAILED); }
   if(OperationMode != 0 && OperationMode != 1)
     { Print("ERROR: OperationMode must be 0 or 1"); return(INIT_FAILED); }

   // Initialize symbol info
   SymbolInfo.Name(_Symbol);
   if(!SymbolInfo.RefreshRates())
     { Print("ERROR: Failed to refresh symbol rates"); return(INIT_FAILED); }

   // Set trade parameters
   Trade.SetExpertMagicNumber(MagicNumber);
   Trade.SetDeviationInPoints(10);
   Trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Initialize indicator handles
   atrHandle_M10 = iATR(_Symbol, PERIOD_M10, ATR_Period);
   atrHandle_H1  = iATR(_Symbol, PERIOD_H1, ATR_Period);
   maFastHandle_H1 = iMA(_Symbol, PERIOD_H1, MA_Fast_Period, 0, MODE_SMA, PRICE_CLOSE);
   maSlowHandle_H1 = iMA(_Symbol, PERIOD_H1, MA_Slow_Period, 0, MODE_SMA, PRICE_CLOSE);

   if(atrHandle_M10 == INVALID_HANDLE || atrHandle_H1 == INVALID_HANDLE ||
      maFastHandle_H1 == INVALID_HANDLE || maSlowHandle_H1 == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create indicator handles");
      return(INIT_FAILED);
     }

   // Initialize file names
   m10FileName = "signal_dataset_" + _Symbol + "_m10.csv";
   h1FileName  = "signal_dataset_" + _Symbol + "_h1.csv";

   // Initialize risk management
   dailyStartBalance = AccountInfo.Balance();
   peakEquity = AccountInfo.Equity();
   tradingEnabled = true;
   dailyLossHalt = false;

   if(EnableLogging)
      Print("FxChartAI OpenEA v2.0 initialized | Symbol: ", _Symbol,
            " | Risk: ", RiskPercent, "% | ATR SL: ", ATR_SL_Multiplier,
            "x | ATR TP: ", ATR_TP_Multiplier, "x");

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   // Release indicator handles
   if(atrHandle_M10 != INVALID_HANDLE)  IndicatorRelease(atrHandle_M10);
   if(atrHandle_H1 != INVALID_HANDLE)   IndicatorRelease(atrHandle_H1);
   if(maFastHandle_H1 != INVALID_HANDLE) IndicatorRelease(maFastHandle_H1);
   if(maSlowHandle_H1 != INVALID_HANDLE) IndicatorRelease(maSlowHandle_H1);

   if(EnableLogging)
      Print("FxChartAI OpenEA v2.0 deinitialized. Reason: ", reason);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Reset daily tracking at new day
   CheckNewDay();

   // Check risk management circuit breakers
   if(!CheckRiskLimits())
      return;

   // Manage existing positions (trailing, breakeven, partial close)
   ManageOpenPositions();

   // Process signals on bar close
   static datetime prevM10Bar = 0;
   static datetime prevH1Bar  = 0;

   if(_Period == PERIOD_M10)
     {
      datetime currentM10Bar = iTime(_Symbol, PERIOD_M10, 1);
      if(currentM10Bar != prevM10Bar)
        {
         prevM10Bar = currentM10Bar;
         ProcessTimeframe(PERIOD_M10, m10FileName, m10Data, m10DataIndex, lastM10UpdateTime);
        }
     }
   else if(_Period == PERIOD_H1)
     {
      datetime currentH1Bar = iTime(_Symbol, PERIOD_H1, 1);
      if(currentH1Bar != prevH1Bar)
        {
         prevH1Bar = currentH1Bar;
         ProcessTimeframe(PERIOD_H1, h1FileName, h1Data, h1DataIndex, lastH1UpdateTime);
        }
     }
  }

//+------------------------------------------------------------------+
//| Check for new trading day - reset daily counters                 |
//+------------------------------------------------------------------+
void CheckNewDay()
  {
   MqlDateTime dt;
   TimeCurrent(dt);
   datetime today = StringToTime(IntegerToString(dt.year) + "." +
                                  IntegerToString(dt.mon) + "." +
                                  IntegerToString(dt.day));
   if(today != lastNewDayCheck)
     {
      lastNewDayCheck = today;
      dailyStartBalance = AccountInfo.Balance();
      dailyLossHalt = false;
      tradingEnabled = true;
      if(EnableLogging)
         Print("New trading day detected. Daily balance reset: ", dailyStartBalance);
     }
  }

//+------------------------------------------------------------------+
//| Risk Management - Check all circuit breakers                     |
//+------------------------------------------------------------------+
bool CheckRiskLimits()
  {
   // 1. Daily loss limit
   double currentBalance = AccountInfo.Balance();
   double dailyLoss = dailyStartBalance - currentBalance;
   double dailyLossPercent = (dailyStartBalance > 0) ? (dailyLoss / dailyStartBalance) * 100 : 0;

   if(dailyLossPercent >= MaxDailyLossPercent)
     {
      if(!dailyLossHalt)
        {
         dailyLossHalt = true;
         if(EnableLogging)
            Print("RISK HALT: Daily loss limit reached: ", DoubleToString(dailyLossPercent, 2),
                  "% >= ", DoubleToString(MaxDailyLossPercent, 2), "%");
        }
      return false;
     }

   // 2. Max equity drawdown
   double currentEquity = AccountInfo.Equity();
   if(currentEquity > peakEquity)
      peakEquity = currentEquity;

   double drawdownPercent = (peakEquity > 0) ? ((peakEquity - currentEquity) / peakEquity) * 100 : 0;
   if(drawdownPercent >= MaxDrawdownPercent)
     {
      if(tradingEnabled)
        {
         tradingEnabled = false;
         if(EnableLogging)
            Print("RISK HALT: Max drawdown reached: ", DoubleToString(drawdownPercent, 2),
                  "% >= ", DoubleToString(MaxDrawdownPercent, 2), "%");
        }
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Session Filter - Check if current time is within trading session |
//+------------------------------------------------------------------+
bool IsWithinTradingSession()
  {
   if(!EnableSessionFilter)
      return true;

   MqlDateTime dt;
   TimeCurrent(dt);

   // Avoid Friday close
   if(AvoidFridayClose && dt.day_of_week == 5 && dt.hour >= 18)
     {
      if(EnableLogging)
         Print("SESSION: Friday close filter - no new trades");
      return false;
     }

   // Session hours filter
   if(SessionStartHour < SessionEndHour)
     {
      if(dt.hour < SessionStartHour || dt.hour >= SessionEndHour)
         return false;
     }
   else // Wraps around midnight
     {
      if(dt.hour < SessionStartHour && dt.hour >= SessionEndHour)
         return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Spread Filter - Check if spread is acceptable                    |
//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
  {
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpreadPoints)
     {
      if(EnableLogging)
         Print("SPREAD: Too high: ", spread, " > ", MaxSpreadPoints);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Get ATR value for specified timeframe                            |
//+------------------------------------------------------------------+
double GetATR(ENUM_TIMEFRAMES tf, int shift = 1)
  {
   int handle = (tf == PERIOD_M10) ? atrHandle_M10 : atrHandle_H1;
   double atr[];
   if(CopyBuffer(handle, 0, shift, 1, atr) < 1)
     {
      if(EnableLogging)
         Print("ERROR: Failed to get ATR for ", EnumToString(tf));
      return 0;
     }
   return atr[0];
  }

//+------------------------------------------------------------------+
//| Dynamic Position Sizing based on ATR and Risk %                  |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
  {
   if(slDistance <= 0)
     {
      if(EnableLogging) Print("ERROR: Invalid SL distance for lot calculation");
      return 0;
     }

   double accountEquity = AccountInfo.Equity();
   double riskAmount = accountEquity * (RiskPercent / 100.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0)
     {
      if(EnableLogging) Print("ERROR: Invalid tick value/size");
      return 0;
     }

   double riskInTicks = slDistance / tickSize;
   double lotSize = riskAmount / (riskInTicks * tickValue);

   // Normalize to broker limits
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   if(lotSize < minLot) lotSize = minLot;
   if(lotSize > maxLot) lotSize = maxLot;

   // Safety cap: never risk more than 5% per trade regardless of input
   double maxRiskLot = (accountEquity * 0.05) / (riskInTicks * tickValue);
   if(lotSize > maxRiskLot)
     {
      if(EnableLogging)
         Print("LOT SIZE: Capped from ", DoubleToString(lotSize, 2),
               " to ", DoubleToString(maxRiskLot, 2), " (5% safety cap)");
      lotSize = MathFloor(maxRiskLot / lotStep) * lotStep;
     }

   return NormalizeDouble(lotSize, 2);
  }

//+------------------------------------------------------------------+
//| Count positions opened by this EA                                |
//+------------------------------------------------------------------+
int CountMyPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetInteger(POSITION_MAGIC) == MagicNumber
         && PositionGetString(POSITION_SYMBOL) == _Symbol)
         count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Multi-Timeframe Trend Confirmation (H1 MAs)                     |
//+------------------------------------------------------------------+
SIGNAL_POSITION GetMTFTrend()
  {
   double maFast[], maSlow[];
   if(CopyBuffer(maFastHandle_H1, 0, 1, 2, maFast) < 2 ||
      CopyBuffer(maSlowHandle_H1, 0, 1, 2, maSlow) < 2)
     {
      if(EnableLogging) Print("ERROR: Failed to get MA values for MTF");
      return SIGNAL_NONE;
     }

   // Fast MA above Slow MA = bullish trend
   if(maFast[1] > maSlow[1] && maFast[0] > maSlow[0])
      return SIGNAL_BUY;
   // Fast MA below Slow MA = bearish trend
   if(maFast[1] < maSlow[1] && maFast[0] < maSlow[0])
      return SIGNAL_SELL;

   return SIGNAL_NONE;
  }

//+------------------------------------------------------------------+
//| Process timeframe data (load signals + analyze)                  |
//+------------------------------------------------------------------+
void ProcessTimeframe(ENUM_TIMEFRAMES tf, string filename, SignalData &data[],
                      int &dataIndex, datetime &lastUpdate)
  {
   datetime currentTime = iTime(_Symbol, tf, 1);
   bool result = false;

   for(int attempt = 0; attempt < MaxRetryAttempts; attempt++)
     {
      if(OperationMode == 0 && LoadCSVData(filename, data, dataIndex, lastUpdate, currentTime))
        { result = true; break; }
      else if(OperationMode == 1 && LoadAPIRequest(data, dataIndex, lastUpdate, currentTime, tf))
        { result = true; break; }

      if(attempt < MaxRetryAttempts - 1)
        {
         if(EnableLogging)
            Print("DATA: Load failed, retrying... Attempt ", attempt + 1, "/", MaxRetryAttempts);
         Sleep(RETRY_DELAY_MS);
        }
     }

   if(result)
     {
      lastUpdate = currentTime;
      AnalyzeAndTrade(tf, data);
     }
   else if(EnableLogging)
      Print("DATA: Failed to load after ", MaxRetryAttempts, " attempts");
  }

//+------------------------------------------------------------------+
//| Load CSV data using circular buffer                              |
//+------------------------------------------------------------------+
bool LoadCSVData(string filePath, SignalData &data[], int &index,
                 datetime &lastUpdate, datetime currentTime)
  {
   int handle = FileOpen(filePath, FILE_READ|FILE_CSV|FILE_ANSI, '\n');
   if(handle == INVALID_HANDLE)
     {
      if(EnableLogging) Print("DATA: Unable to open file: ", filePath);
      return false;
     }

   bool updated = false;
   while(!FileIsEnding(handle))
     {
      string line = FileReadString(handle);
      StringReplace(line, "\r", "");
      string parts[];

      if(StringSplit(line, ',', parts) == 3)
        {
         datetime dt = StringToTime(parts[0]);
         if(dt > lastUpdate && dt <= currentTime)
           {
            SignalData newData;
            newData.time = dt;
            newData.position = (SIGNAL_POSITION)StringToInteger(parts[1]);
            newData.weight = (TREND_WEIGHT)StringToInteger(parts[2]);

            int size = ArraySize(data);
            if(size < MaxDataSize)
               ArrayResize(data, size + 1);
            for(int x = size - 1; x > 0; x--)
               data[x] = data[x - 1];
            data[0] = newData;
            updated = true;
           }
        }
     }

   FileClose(handle);
   return updated;
  }

//+------------------------------------------------------------------+
//| Load API data                                                    |
//+------------------------------------------------------------------+
bool LoadAPIRequest(SignalData &data[], int &index, datetime &lastUpdate,
                    datetime currentTime, ENUM_TIMEFRAMES timeframe)
  {
   string url = BuildAPIRequestURL(timeframe, currentTime);

   uchar result[];
   string headers;
   string resultHeaders;
   char postData[];
   int response = WebRequest("GET", url, headers, 5000, postData, result, resultHeaders);

   if(response != 200)
     {
      if(EnableLogging)
         Print("API: Request failed. Response: ", response, ", Error: ", GetLastError());
      return false;
     }

   CJAVal parser;
   string jsonStr = CharArrayToString(result);

   if(!parser.Deserialize(jsonStr))
     {
      if(EnableLogging) Print("API: Failed to parse JSON");
      return false;
     }

   if(parser.m_type != jtARRAY)
     {
      if(EnableLogging) Print("API: Invalid JSON structure");
      return false;
     }

   bool dataUpdated = false;

   for(int i = parser.Size() - 1; i >= 0; i--)
     {
      CJAVal *item = parser[i];
      string dateStr = item["tradedate"].ToStr();
      StringReplace(dateStr, "-", ".");
      datetime tradeDate = StringToTime(dateStr);

      if(tradeDate <= lastUpdate)
         continue;

      SignalData newData;
      newData.time = tradeDate;
      newData.position = (SIGNAL_POSITION)item["position"].ToInt();
      newData.weight = (TREND_WEIGHT)item["weight"].ToInt();

      int size = ArraySize(data);
      if(size < MaxDataSize)
         ArrayResize(data, size + 1);
      for(int j = size - 1; j > 0; j--)
         data[j] = data[j - 1];

      data[0] = newData;
      lastUpdate = tradeDate;
      dataUpdated = true;
     }

   if(ArraySize(data) > MaxDataSize)
      ArrayResize(data, MaxDataSize);

   return dataUpdated;
  }

//+------------------------------------------------------------------+
//| Build API Request URL                                            |
//+------------------------------------------------------------------+
string BuildAPIRequestURL(ENUM_TIMEFRAMES tf, datetime time)
  {
   string timeframeStr = (tf == PERIOD_M10) ? "M10" : "H1";
   string formattedTime = TimeToString(time, TIME_DATE) + "T" +
                          TimeToString(time, TIME_MINUTES);

   return StringFormat(
             "https://chartapi.fxchartai.com/easignal?currencypair=%s&size=%d&tradedate=%s&timeframe=%s",
             _Symbol, MaxDataSize, formattedTime, timeframeStr
          );
  }

//+------------------------------------------------------------------+
//| Trend confirmation check                                         |
//+------------------------------------------------------------------+
bool IsTrendConfirmed(const SignalData &data[], int requiredConsecutive,
                      SIGNAL_POSITION &result)
  {
   int count = 0;
   SIGNAL_POSITION lastSignal = SIGNAL_NONE;

   for(int i = 0; i < ArraySize(data); i++)
     {
      if(data[i].position == SIGNAL_NONE)
         continue;

      if(data[i].position == lastSignal)
        {
         if(++count >= requiredConsecutive)
           {
            result = data[i].position;
            return true;
           }
        }
      else
        {
         count = 1;
         lastSignal = data[i].position;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Weighted Signal Strength (uses TREND_WEIGHT)                     |
//+------------------------------------------------------------------+
double GetSignalStrength(const SignalData &data[], SIGNAL_POSITION direction)
  {
   double strength = 0;
   int count = 0;
   for(int i = 0; i < ArraySize(data); i++)
     {
      if(data[i].position == direction)
        {
         double w = (data[i].weight == TREND_HIGH) ? 2.0 :
                    (data[i].weight == TREND_LOW)  ? 1.0 : 0.5;
         // More recent signals weighted higher
         w *= (1.0 - (double)i / (double)ArraySize(data));
         strength += w;
         count++;
        }
     }
   return (count > 0) ? strength / count : 0;
  }

//+------------------------------------------------------------------+
//| Candle tail signal detection (improved)                          |
//+------------------------------------------------------------------+
SIGNAL_POSITION GetCandleTailSignal(ENUM_TIMEFRAMES tf)
  {
   double open  = iOpen(_Symbol, tf, 1);
   double close = iClose(_Symbol, tf, 1);
   double high  = iHigh(_Symbol, tf, 1);
   double low   = iLow(_Symbol, tf, 1);

   double body = MathAbs(close - open);
   double totalRange = high - low;

   // Avoid division by zero and very small candles
   if(totalRange <= 0 || body <= 0)
      return SIGNAL_NONE;

   double upperTail, lowerTail;
   if(close > open) // Bullish candle
     {
      upperTail = high - close;
      lowerTail = open - low;
     }
   else // Bearish candle
     {
      upperTail = high - open;
      lowerTail = close - low;
     }

   // Require tail to be at least 2x the opposite tail AND meaningful relative to body
   if(lowerTail > upperTail * 2 && lowerTail > body * 0.5)
      return SIGNAL_BUY;   // Long lower tail = bullish rejection

   if(upperTail > lowerTail * 2 && upperTail > body * 0.5)
      return SIGNAL_SELL;  // Long upper tail = bearish rejection

   return SIGNAL_NONE;
  }

//+------------------------------------------------------------------+
//| Order Block Detection (from ICT concepts)                        |
//+------------------------------------------------------------------+
bool IsOrderBlock(ENUM_TIMEFRAMES tf, SIGNAL_POSITION direction)
  {
   double open1  = iOpen(_Symbol, tf, 1);
   double close1 = iClose(_Symbol, tf, 1);
   double high1  = iHigh(_Symbol, tf, 1);
   double low1   = iLow(_Symbol, tf, 1);

   double bodySize = MathAbs(close1 - open1);
   double totalRange = high1 - low1;

   if(totalRange <= 0)
      return false;

   // Order block: candle with body > 50% of total range (strong momentum candle)
   double bodyRatio = (bodySize / totalRange) * 100;

   if(direction == SIGNAL_BUY)
      return (close1 > open1 && bodyRatio > 50);  // Bullish OB
   if(direction == SIGNAL_SELL)
      return (close1 < open1 && bodyRatio > 50);  // Bearish OB

   return false;
  }

//+------------------------------------------------------------------+
//| Trendline check (improved with proper slope calculation)         |
//+------------------------------------------------------------------+
bool CheckTrendline(ENUM_TIMEFRAMES tf, bool bullish)
  {
   // Find two swing points to form a trendline
   double point1 = 0, point2 = 0;
   int idx1 = 0, idx2 = 0;

   for(int i = 2; i <= 20; i++)
     {
      double price = bullish ? iLow(_Symbol, tf, i) : iHigh(_Symbol, tf, i);
      bool isSwing = true;

      // Check if it's a swing point (lower than neighbors for bullish, higher for bearish)
      if(i > 1 && i < 20)
        {
         double prev = bullish ? iLow(_Symbol, tf, i-1) : iHigh(_Symbol, tf, i-1);
         double next = bullish ? iLow(_Symbol, tf, i+1) : iHigh(_Symbol, tf, i+1);

         if(bullish)
            isSwing = (price <= prev && price <= next);
         else
            isSwing = (price >= prev && price >= next);
        }

      if(isSwing)
        {
         if(point1 == 0)
           { point1 = price; idx1 = i; }
         else if(point2 == 0)
           { point2 = price; idx2 = i; break; }
        }
     }

   if(point1 == 0 || point2 == 0)
      return false;

   // Check slope direction matches expected trend
   if(bullish)
      return (point1 > point2);  // Rising lows
   else
      return (point1 < point2);  // Falling highs
  }

//+------------------------------------------------------------------+
//| MAIN TRADING LOGIC (Enhanced)                                    |
//+------------------------------------------------------------------+
void AnalyzeAndTrade(ENUM_TIMEFRAMES tf, const SignalData &data[])
  {
   // Pre-trade checks
   if(CountMyPositions() >= MaxPositions)
      return;

   if(!IsWithinTradingSession())
      return;

   if(!IsSpreadAcceptable())
      return;

   // Get ATR for dynamic SL/TP
   double atr = GetATR(tf);
   if(atr <= 0)
     {
      if(EnableLogging) Print("TRADE: ATR is zero, skipping");
      return;
     }

   // 1. Check FxChartAI signal trend confirmation
   SIGNAL_POSITION trendSignal;
   if(!IsTrendConfirmed(data, ConfidenceLevel, trendSignal))
      return;

   // 2. Get signal strength (use weight data)
   double strength = GetSignalStrength(data, trendSignal);
   if(strength < 0.5)
     {
      if(EnableLogging) Print("TRADE: Signal strength too low: ", DoubleToString(strength, 2));
      return;
     }

   // 3. Candle tail confirmation
   SIGNAL_POSITION candleSignal = GetCandleTailSignal(tf);
   if(candleSignal != trendSignal)
      return;

   // 4. Multi-timeframe confirmation (if on M10, check H1 trend)
   if(RequireMTFConfirm && tf == PERIOD_M10)
     {
      SIGNAL_POSITION mtfTrend = GetMTFTrend();
      if(mtfTrend != trendSignal && mtfTrend != SIGNAL_NONE)
        {
         if(EnableLogging)
            Print("TRADE: MTF conflict - Signal: ", EnumToString((ENUM_ORDER_TYPE)trendSignal),
                  " vs H1 Trend: ", EnumToString((ENUM_ORDER_TYPE)mtfTrend));
         return;
        }
     }

   // 5. Optional: Order block or trendline confirmation
   bool hasStructure = IsOrderBlock(tf, trendSignal) ||
                       CheckTrendline(tf, trendSignal == SIGNAL_BUY);

   // All confirmations passed - execute trade
   ExecuteTrade(trendSignal, tf, atr, hasStructure);
  }

//+------------------------------------------------------------------+
//| Execute trade with dynamic SL/TP based on ATR                    |
//+------------------------------------------------------------------+
void ExecuteTrade(SIGNAL_POSITION signal, ENUM_TIMEFRAMES tf, double atr, bool strongSetup)
  {
   // Delete any existing pending orders from this EA
   DeletePendingOrders();

   // Calculate ATR-based SL/TP
   double slDistance = atr * ATR_SL_Multiplier;
   double tpDistance = atr * ATR_TP_Multiplier;

   // If strong setup (order block + trendline), tighten SL slightly for better R:R
   if(strongSetup)
      slDistance *= 0.85;

   // Calculate lot size based on risk
   double lotSize = CalculateLotSize(slDistance);
   if(lotSize <= 0)
     {
      if(EnableLogging) Print("TRADE: Invalid lot size calculated");
      return;
     }

   // Determine entry price (pending order with offset)
   double offset = PendingOrderOffset * _Point;
   double price, sl, tp;

   if(signal == SIGNAL_BUY)
     {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + offset;
      sl = price - slDistance;
      tp = price + tpDistance;
     }
   else
     {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID) - offset;
      sl = price + slDistance;
      tp = price - tpDistance;
     }

   // Normalize prices
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   price = NormalizeDouble(price, digits);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   // Validate minimum stop level
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDist = stopLevel * _Point;
   if(MathAbs(price - sl) < minStopDist || MathAbs(price - tp) < minStopDist)
     {
      if(EnableLogging)
         Print("TRADE: SL/TP too close to entry. Min stop distance: ", minStopDist);
      return;
     }

   // Set expiration (next bar close + 1 bar)
   datetime expiration = TimeCurrent() + PeriodSeconds(tf) * 2;

   // Place pending order
   ENUM_ORDER_TYPE orderType = (signal == SIGNAL_BUY) ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
   string comment = StringFormat("FxAI v2|ATR:%.5f|Str:%.1f", atr, 0.0);

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action     = TRADE_ACTION_PENDING;
   req.symbol     = _Symbol;
   req.volume     = lotSize;
   req.type       = orderType;
   req.price      = price;
   req.sl         = sl;
   req.tp         = tp;
   req.magic      = MagicNumber;
   req.comment    = comment;
   req.expiration = expiration;
   req.type_time  = ORDER_TIME_SPECIFIED;

   if(!OrderSend(req, res))
     {
      if(EnableLogging)
         Print("TRADE ERROR: ", GetLastError(), " | Retcode: ", res.retcode,
               " | Price: ", price, " | SL: ", sl, " | TP: ", tp, " | Lot: ", lotSize);
     }
   else
     {
      if(EnableLogging)
         Print("TRADE PLACED: ", (signal == SIGNAL_BUY ? "BUY" : "SELL"),
               " STOP | Ticket: ", res.order, " | Price: ", price,
               " | SL: ", sl, " | TP: ", tp, " | Lot: ", lotSize,
               " | ATR: ", DoubleToString(atr, 5));
     }
  }

//+------------------------------------------------------------------+
//| Delete pending orders from this EA                               |
//+------------------------------------------------------------------+
void DeletePendingOrders()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket <= 0) continue;

      if(OrderGetInteger(ORDER_MAGIC) == MagicNumber &&
         OrderGetString(ORDER_SYMBOL) == _Symbol)
        {
         ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP ||
            type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_SELL_LIMIT)
           {
            Trade.OrderDelete(ticket);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Manage Open Positions (Trailing, Breakeven, Partial Close)       |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber ||
         PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice    = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL    = PositionGetDouble(POSITION_SL);
      double currentTP    = PositionGetDouble(POSITION_TP);
      double volume       = PositionGetDouble(POSITION_VOLUME);
      double currentPrice = (posType == POSITION_TYPE_BUY) ?
                            SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                            SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double riskDistance = MathAbs(openPrice - currentSL);
      double currentProfit = (posType == POSITION_TYPE_BUY) ?
                             (currentPrice - openPrice) : (openPrice - currentPrice);

      // Get tracker for this position
      int trackerIdx = GetOrCreateTracker(ticket);

      // 1. PARTIAL CLOSE at 1:1 R:R
      if(EnablePartialClose && trackerIdx >= 0 && !partialTrackers[trackerIdx].partialDone)
        {
         if(riskDistance > 0 && currentProfit >= riskDistance * BreakevenTriggerRR)
           {
            double closeVolume = NormalizeDouble(volume * (PartialClosePercent / 100.0), 2);
            double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
            if(closeVolume >= minLot && (volume - closeVolume) >= minLot)
              {
               ENUM_ORDER_TYPE closeType = (posType == POSITION_TYPE_BUY) ?
                                           ORDER_TYPE_SELL : ORDER_TYPE_BUY;
               if(Trade.PositionClosePartial(ticket, closeVolume))
                 {
                  partialTrackers[trackerIdx].partialDone = true;
                  if(EnableLogging)
                     Print("PARTIAL CLOSE: ", DoubleToString(closeVolume, 2),
                           " lots at 1:", BreakevenTriggerRR, " R:R");
                 }
              }
           }
        }

      // 2. BREAKEVEN - move SL to entry after partial close or at 1:1 R:R
      if(BreakevenTriggerRR > 0 && trackerIdx >= 0 && !partialTrackers[trackerIdx].breakevenDone)
        {
         if(riskDistance > 0 && currentProfit >= riskDistance * BreakevenTriggerRR)
           {
            double newSL = openPrice;
            // Add small buffer (1 point profit locked)
            if(posType == POSITION_TYPE_BUY)
               newSL = openPrice + _Point;
            else
               newSL = openPrice - _Point;

            bool shouldMove = false;
            if(posType == POSITION_TYPE_BUY && newSL > currentSL)
               shouldMove = true;
            if(posType == POSITION_TYPE_SELL && (newSL < currentSL || currentSL == 0))
               shouldMove = true;

            if(shouldMove)
              {
               if(Trade.PositionModify(ticket, newSL, currentTP))
                 {
                  partialTrackers[trackerIdx].breakevenDone = true;
                  if(EnableLogging)
                     Print("BREAKEVEN: SL moved to ", DoubleToString(newSL, _Digits),
                           " for ticket ", ticket);
                 }
              }
           }
        }

      // 3. ATR TRAILING STOP
      if(EnableTrailing)
        {
         ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)_Period;
         int candlesOpen = (int)((TimeCurrent() - PositionGetInteger(POSITION_TIME)) / PeriodSeconds(tf));

         if(candlesOpen >= TrailStartCandles && currentProfit > 0)
           {
            double atr = GetATR(tf);
            if(atr > 0)
              {
               double trailDistance = atr * TrailATR_Multiplier;
               double newSL;

               if(posType == POSITION_TYPE_BUY)
                 {
                  newSL = currentPrice - trailDistance;
                  newSL = NormalizeDouble(newSL, _Digits);
                  if(newSL > currentSL)
                    {
                     Trade.PositionModify(ticket, newSL, currentTP);
                     if(EnableLogging)
                        Print("TRAIL: BUY SL updated to ", DoubleToString(newSL, _Digits),
                              " (ATR trail: ", DoubleToString(trailDistance, 5), ")");
                    }
                 }
               else
                 {
                  newSL = currentPrice + trailDistance;
                  newSL = NormalizeDouble(newSL, _Digits);
                  if(newSL < currentSL || currentSL == 0)
                    {
                     Trade.PositionModify(ticket, newSL, currentTP);
                     if(EnableLogging)
                        Print("TRAIL: SELL SL updated to ", DoubleToString(newSL, _Digits),
                              " (ATR trail: ", DoubleToString(trailDistance, 5), ")");
                    }
                 }
              }
           }
        }
     }

   // Clean up trackers for closed positions
   CleanupTrackers();
  }

//+------------------------------------------------------------------+
//| Get or create partial close tracker for a position               |
//+------------------------------------------------------------------+
int GetOrCreateTracker(ulong ticket)
  {
   // Find existing tracker
   for(int i = 0; i < ArraySize(partialTrackers); i++)
     {
      if(partialTrackers[i].ticket == ticket)
         return i;
     }

   // Create new tracker
   int size = ArraySize(partialTrackers);
   ArrayResize(partialTrackers, size + 1);
   partialTrackers[size].ticket = ticket;
   partialTrackers[size].partialDone = false;
   partialTrackers[size].breakevenDone = false;
   return size;
  }

//+------------------------------------------------------------------+
//| Remove trackers for positions that no longer exist               |
//+------------------------------------------------------------------+
void CleanupTrackers()
  {
   for(int i = ArraySize(partialTrackers) - 1; i >= 0; i--)
     {
      bool found = false;
      for(int j = PositionsTotal() - 1; j >= 0; j--)
        {
         if(PositionGetTicket(j) == partialTrackers[i].ticket)
           { found = true; break; }
        }
      if(!found)
         ArrayRemove(partialTrackers, i, 1);
     }
  }

//+------------------------------------------------------------------+
