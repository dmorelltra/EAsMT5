Universal Scaling Manager EA
============================

This repository contains **UniversalScalingManager.mq5**, a MetaTrader 5 Expert Advisor that wraps any existing strategy to provide scaling and prop-firm style risk controls.

Usage
-----
1. Copy `UniversalScalingManager.mq5` into your MetaTrader 5 `MQL5/Experts` folder.
2. Compile the EA inside MetaEditor.
3. Attach it to the same chart as the strategy you want to manage.
4. Set `InMagicNumber` to match the managed strategy so only those trades are controlled.
5. Adjust risk inputs such as `BaseRiskMoney`, `TargetProfitMoney`, and `MaxDailyRiskPercent` to align with your prop evaluation.

Notes
-----
- The EA does not generate signals; it only manages trades opened by the chosen magic number.
- Works on both netting and hedging accounts; on netting, it manages the single position per symbol.
- Daily drawdown and optional total drawdown protections will block new trades when breached.

Testing
-------
Automated testing is not available in this environment. Please compile and forward-test inside MetaTrader 5 before live use.
