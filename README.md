# multi-strategyea

MQL5 multi-strategy Expert Advisor for XAUUSD (MetaTrader 5).

## Strategy modules

1. Trend pullback (bull/bear regime)
2. Range mean reversion (neutral regime)
3. Asian-range breakout (London-session window)

The modules share a risk budget and use separate magic numbers. The EA includes daily-loss and loss-streak halts, an aggregate open-risk cap, a maximum open-position count, spread filters, volatility filtering, and Friday position management.

## v2.1 demo-test changes

- Indicator-data failures now block new entries instead of being treated as a neutral regime.
- Asian-range midnight is constructed from broker server calendar time rather than Unix-day division.
- Volume-step and volume-limit values are validated before lot sizing.
- Trade-server return codes are checked before an order is counted as accepted.
- Synchronous trade execution is explicitly enabled.
- Invalid risk/session/lookback inputs are rejected during initialization.

## Important testing status

**This is still an experimental EA. It is not established as profitable and has not been validated on Deriv live conditions.** These changes are a first safety and reliability pass, not proof of a trading edge.

### Deriv MT5 demo test plan

1. Confirm the exact XAUUSD symbol specification in the Deriv terminal.
2. Confirm whether the demo account is hedging or netting.
3. Compile in MetaEditor and resolve all compiler warnings/errors.
4. In Strategy Tester, select XAUUSD, M5, and **Every tick based on real ticks** when broker history is available.
5. Test one module at a time before enabling all three.
6. Record spread, commission, swap, trade count, profit factor, expected payoff, and equity drawdown.
7. Forward-test on demo and compare actual fills/spreads with the backtest.

Do not use a live account until the EA has passed independent out-of-sample testing and an extended demo forward test. Backtest results do not guarantee future performance.
