# Ireland Consumer Price Index (CPI) Intelligence Platform

An end-to-end analytics platform built on **MySQL (Advanced)** and **Power BI**, tracking Ireland's Consumer Price Index across 14 commodity groups from November 1996 to June 2026. The project replaces manual monthly reporting with automated ETL, validation, and scheduled recalculation — paired with a 5-page Power BI report for trend analysis, commodity comparison, and inflation monitoring.

**Tech stack:** MySQL (Advanced) · Power BI · DAX
**Data source:** [CSO Ireland — Table CPM20](https://data.cso.ie)

---

## 01. Business Problem

Manual CPI reporting workflows typically involve pulling raw index data by hand, checking it for errors, recalculating month-over-month and year-over-year changes, and rebuilding charts every reporting cycle — a slow, repetitive, error-prone process. This project automates that entire workflow: from raw CSV ingestion to validated, auto-refreshing KPI reporting, with an audit trail for every load.

## 02. Dataset Overview

- **Source:** CSO Ireland, Table CPM20 (Consumer Price Index by Commodity Group)
- **Raw file:** 39,872 rows, 5 columns (Statistic Label, Month, Commodity Group, UNIT, VALUE)
- **Scope used:** Single consistent index series — *"Consumer Price Index (Base Month December 2023 = 100)"* — filtered from 8 overlapping statistic-label variants in the raw file (6 rebased index versions + 2 CSO-precomputed % change series, which were excluded so MoM/YoY could be calculated independently in SQL)
- **Final structured dataset:** 4,984 records across 14 commodity groups, spanning November 1996 – June 2026

## 03. Architecture

```
CSO CSV (39,872 rows)
        │
        ▼
staging_cpi_raw  (raw landing table, untouched for auditability)
        │
        ▼
Stored Procedures  (filter, validate, transform)
        │
        ▼
fact_cpi  (4,984 clean records)  ──▶  agg_cpi_monthly (auto-synced via trigger)
        │
        ▼
Views (vw_cpi_monthly_summary, vw_inflation_alerts)
        │
        ▼
Power BI  (5-page report)
```

## 04. Database Design

A star schema was used to keep the fact table lean and the lookup data reusable:

- **`fact_cpi`** — index value, MoM/YoY change, foreign keys to date and commodity group, linked to the load batch that created it
- **`dim_date`** — one row per month, with year/quarter/month helper columns
- **`dim_commodity_group`** — 14 commodity groups, each mapped to a simplified category
- **`etl_load_log`** — audit table recording every load run (type, rows inserted, status, timestamps, error message)
- **`agg_cpi_monthly`** — pre-aggregated summary table, kept in sync automatically via trigger

## 05. ETL Process

1. Raw CSV loaded into `staging_cpi_raw` via `LOAD DATA LOCAL INFILE` (kept untouched, as the audit-safe raw layer)
2. `sp_load_fact_from_staging()` — loops through each commodity group via cursor, filters to the chosen base-period index, validates numeric values with `REGEXP`, skips existing rows via `NOT EXISTS`, and logs the run to `etl_load_log`
3. Confirmed idempotent in testing: first run inserted 4,984 rows (SUCCESS); re-running the same procedure correctly inserted 0 new rows instead of duplicating data
4. `sp_calculate_mom_yoy_changes()` — calculates month-over-month and year-over-year % change using `LAG()` window functions, independent of CSO's own precomputed percentage columns
5. `evt_monthly_yoy_recalc` — MySQL Event, runs the recalculation automatically every month
6. `evt_purge_old_logs` — MySQL Event, clears audit logs older than 6 months, automatically every week

## 06. SQL Objects

| Type | Objects |
|---|---|
| Stored Procedures | `sp_load_fact_from_staging`, `sp_calculate_mom_yoy_changes`, `sp_get_cpi_trend`, `sp_get_high_inflation_alert` |
| Functions (UDF) | `fn_classify_inflation_level`, `fn_get_quarter_label` |
| Triggers | `trg_before_insert_fact_cpi` (blocks negative index values), `trg_after_insert_fact_cpi` (auto-syncs summary table) |
| Events | `evt_monthly_yoy_recalc`, `evt_purge_old_logs` |
| Views | `vw_cpi_monthly_summary`, `vw_inflation_alerts` |
| Indexes | `idx_fact_group_date`, `idx_fact_date_group` |

## 07. Performance Optimisation

Composite indexing was added on `fact_cpi(group_id, date_id)`, tested via `EXPLAIN` before and after:

| Metric | Before | After |
|---|---|---|
| Rows scanned | 356 | **51** |
| Access type | ref | **range** |
| Filtered | 14.06% | **100%** |

**Result:** an 86% reduction in rows scanned, with full filter efficiency.

## 08. Power BI

A 5-page report connected directly to MySQL:

1. **Executive Summary** — KPI cards, overall CPI trend, YoY change by commodity group
2. **Trend Analysis** — drill-down chart (Year → Quarter → Month), period KPIs
3. **Commodity Comparison** — bar chart and detail table across all 14 groups
4. **Inflation Alerts** — high-inflation periods (YoY > 5%), conditional formatting, alert distribution
5. **ETL Monitoring** — load history, data quality checks, pipeline overview

Built with DAX time-intelligence measures, a dedicated date table, drill-down navigation, conditional formatting, and a page navigator for consistent cross-page navigation.

**Executive Summary**
![Executive Summary](./Screenshot%202026-07-30%20154033.png)

**Trend Analysis**
![Trend Analysis](./Screenshot%202026-07-30%20154054.png)

**Commodity Comparison**
![Commodity Comparison](./Screenshot%202026-07-30%20154116.png)

**Inflation Alerts**
![Inflation Alerts](./Screenshot%202026-07-30%20154132.png)

**ETL Monitoring**
![ETL Monitoring](./Screenshot%202026-07-30%20154150.png)

## 09. Business Insights

- Housing, water, electricity, gas and other fuels showed the sharpest YoY spikes during 2022, consistent with Ireland's real-world energy cost crisis that year
- Clothing and footwear shows a distinct recurring seasonal pattern, reflecting biannual retail sales cycles
- Education services recorded the highest sustained YoY inflation in the most recent reporting period

## 10. Challenges

- CSO's raw export contains 8 overlapping statistic-label variants (rebased indices + precomputed % change columns) for the same data — resolved by standardising on a single base period and calculating percentage changes independently in SQL
- Ensuring the load procedure was safely re-runnable without creating duplicate records — solved with a `NOT EXISTS` check inside the stored procedure, confirmed via repeat-run testing

## 11. Lessons Learned

- Designing the audit table (`etl_load_log`) early made debugging and idempotency testing far easier than adding logging after the fact
- Composite index design should match the exact filter pattern used by reporting queries — indexing on `group_id` alone was not enough; the combined `(group_id, date_id)` index made the real performance difference

## 12. Future Improvements

- Automate the raw CSV ingestion itself (currently a manual download step from CSO) via a scheduled Python/PowerShell script
- Add Row-Level Security in Power BI to restrict certain views by commodity category
- Extend the alert system to notify via email/Teams when a new high-inflation month is detected
