# ConnectPlus Customer Churn & Retention: Synthetic Source Data

Synthetic operational extracts for the fictional telecom provider ConnectPlus (consumer postpaid mobile and broadband).

- **Analysis window:** September 2024 to August 2026 (24 months)
- **Extract date:** 31 August 2026. Records are as they stood on that date.

## Files

| File | Grain | Rows |
|---|---|---|
| regions.csv | One row per region | 12 |
| plans.csv | One row per plan | 15 |
| plan_price_history.csv | One row per plan per price period | 35 |
| churn_reason_codes.csv | One row per reason code | 15 |
| retention_offer_catalog.csv | One row per offer type | 6 |
| customers.csv | One row per customer account | 12,882 |
| subscriptions.csv | One row per customer per plan period | 17,545 |
| discounts.csv | One row per discount applied to a customer | 7,444 |
| invoices.csv | One row per customer per monthly billing cycle | 202,952 |
| payments.csv | One row per payment attempt against an invoice | 201,236 |
| usage_monthly.csv | One row per customer per month | 202,702 |
| support_tickets.csv | One row per support ticket | 49,845 |
| network_incidents.csv | One row per incident per region | 1,499 |
| churn_events.csv | One row per churned customer account | 4,276 |
| retention_offers.csv | One row per retention offer made | 2,673 |

## File Format

- CSV, UTF-8, comma-delimited, header row, text containing commas is double-quoted.
- Dates are `YYYY-MM-DD` and datetimes are `YYYY-MM-DD HH:MM:SS`, apart from the intentional format issues noted below.
- NULLs are empty fields. Flags are 0/1. Amounts are in INR.
- IDs are text keys (for example `CUST000123`, `INV0001234`, `PL05`).

## Loading Notes

**SQL Server.** Load every file into a staging table with all columns typed as `NVARCHAR`. The raw files deliberately contain duplicates, mixed date formats and inconsistent codes, so strict data types or primary keys will reject rows at load time. Convert types and apply keys in the cleaning layer. Use the Import Flat File wizard, or `BULK INSERT` with `FORMAT = 'CSV'`, `FIRSTROW = 2` and `CODEPAGE = '65001'` (SQL Server 2017 or later).

**Power BI.** The intended flow is to connect to the cleaned and modeled SQL tables. The CSVs can also be loaded directly via Get Data > Text/CSV for exploration.

## Column Notes

- **invoices:** `total_amount = base_amount - discount_amount + tax_amount`, where tax is 18% GST on the discounted amount. `base_amount` is the plan price valid in the billing month (see plan_price_history).
- **payments:** `Failed` rows have `amount_paid = 0`. A `Partial` payment is followed by a `Success` row for the balance. Invoices with no successful payment are unpaid.
- **usage_monthly:** `call_minutes` is blank for broadband and `avg_speed_mbps` is blank for mobile. Signup-month and churn-month usage are partial months.
- **support_tickets:** a blank `resolved_datetime` means the ticket was open at the extract date. `csat_score` (1–5) is only present when the customer responded to the survey.
- **retention_offer_catalog:** `offer_value` is the discount % for Discount and Contract Lock-in offers, GB for Data Bonus, and plan tiers for Free Upgrade.
- **churn_events:** a blank `churn_reason_id` means no reason was captured. `competitor_name` is only recorded when known.
- **network_incidents:** incidents are recorded at region level, not customer level. They link to customers through `region_id`.
- **Pre-window arrears:** a small number of involuntary churns in September–October 2024 belong to accounts already in arrears before the window opened. Their earlier unpaid invoices fall outside this extract.

## Intentional Data-Quality Issues

As defined in the project specification, the raw data contains a small share (roughly 0.1–3%) of real-world data-quality problems. These include duplicate records, inconsistent names and codes, mixed date formats, missing values, activity after churn, illogical timestamps, outliers and credit adjustments. Finding and fixing them is part of the data-cleaning phase.
