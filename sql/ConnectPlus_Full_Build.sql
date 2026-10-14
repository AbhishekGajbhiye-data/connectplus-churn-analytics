/* ==================================================================
   ConnectPlus Churn & Retention Analytics - complete SQL Server build
   ------------------------------------------------------------------
   Run order (top to bottom):
     PART 0   Setup ........... database + schemas
     PART 1   Audit tables .... load log, data-quality log, pipeline log
     PART 2   Staging ......... stg tables + one load procedure per CSV
     PART 3   Cleaning ........ clean tables + one cleaning procedure per table
     PART 4   Star schema ..... dimensions, facts, build procedures
     PART 5   Helper views .... risk score + customer priority logic
     PART 6   Reporting views . rpt views used by Power BI
     PART 7   Pipeline ........ audit.usp_run_pipeline (runs Parts 2-4 in order)
     PART 8   Validation view . rpt.vw_dashboard_validation (one row per KPI)
     PART 9   Run ............. executes the pipeline once
     PART 10  Checks .......... row counts, data quality, reconciliation
     PART 11  Analysis ........ business questions (reference, run on demand)

   Parts 0-8 only CREATE objects; nothing is loaded until PART 9.
   Re-running the whole script rebuilds everything from the CSVs.
   CSV folder used by the load procedures:
     D:\END TO END PROJECT\ConnectPlus_Synthetic_Data\
   ================================================================== */

/* ==================================================================
   PART 0: SETUP - database and schemas
   ================================================================== */

-- 1. Project database (only if it doesn't already exist)
USE master;
GO

IF DB_ID(N'ConnectPlus_Analytics') IS NULL
    CREATE DATABASE ConnectPlus_Analytics;
GO

USE ConnectPlus_Analytics;
GO

-- 2. The schemas (one per data layer)
IF SCHEMA_ID(N'stg')   IS NULL EXEC(N'CREATE SCHEMA stg');    -- Raw data, loaded as-is from CSVs
IF SCHEMA_ID(N'clean') IS NULL EXEC(N'CREATE SCHEMA clean');  -- Cleaned, correctly typed data
IF SCHEMA_ID(N'dw')    IS NULL EXEC(N'CREATE SCHEMA dw');     -- Star schema: dimensions and facts
IF SCHEMA_ID(N'rpt')   IS NULL EXEC(N'CREATE SCHEMA rpt');    -- Reporting views for Power BI
IF SCHEMA_ID(N'audit') IS NULL EXEC(N'CREATE SCHEMA audit');  -- Load logs and data-quality logs
GO

/* ==================================================================
   PART 1: AUDIT TABLES
   Created only if missing, so re-running the script keeps the history.
   ================================================================== */

-- --------------------------------------------------------------
-- 1.1 audit.load_log - one row per CSV load (written by PART 2 procedures)
-- --------------------------------------------------------------

IF OBJECT_ID(N'audit.load_log', N'U') IS NULL
CREATE TABLE audit.load_log (
    load_id         INT IDENTITY(1,1) PRIMARY KEY,
    table_name      NVARCHAR(100)  NOT NULL,
    rows_loaded     INT            NULL,
    load_status     NVARCHAR(20)   NOT NULL,   -- 'Success' or 'Failed'
    error_message   NVARCHAR(4000) NULL,
    load_time       DATETIME2(0)   NOT NULL DEFAULT SYSDATETIME()
);
GO

-- --------------------------------------------------------------
-- 1.2 audit.data_quality_log - one row per issue fixed in the latest cleaning run
-- --------------------------------------------------------------

IF OBJECT_ID(N'audit.data_quality_log', N'U') IS NULL
CREATE TABLE audit.data_quality_log (
    dq_id           INT IDENTITY(1,1) PRIMARY KEY,
    table_name      NVARCHAR(100) NOT NULL,
    issue           NVARCHAR(255) NOT NULL,
    rows_affected   INT           NOT NULL,
    action_taken    NVARCHAR(255) NOT NULL,
    logged_at       DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME()
);
GO

-- --------------------------------------------------------------
-- 1.3 audit.pipeline_log - one row per pipeline stage per run
-- --------------------------------------------------------------

IF OBJECT_ID(N'audit.pipeline_log', N'U') IS NULL
CREATE TABLE audit.pipeline_log (
    log_id            INT IDENTITY(1,1) PRIMARY KEY,
    run_id            INT            NOT NULL,
    stage_name        NVARCHAR(50)   NOT NULL,
    start_time        DATETIME2(0)   NOT NULL,
    end_time          DATETIME2(0)   NOT NULL,
    duration_seconds  INT            NOT NULL,
    stage_status      NVARCHAR(20)   NOT NULL,   -- 'Success' or 'Failed'
    details           NVARCHAR(4000) NULL        -- row counts, or the error message
);
GO

/* ==================================================================
   PART 2: STAGING (raw CSV copies, every column is text)
   ================================================================== */

-- --------------------------------------------------------------
-- 2.1 Staging tables
-- --------------------------------------------------------------

-- STG_Tables = Regions --
DROP TABLE IF EXISTS stg.regions;
CREATE TABLE stg.regions (
    region_id       NVARCHAR(50),
    region_name     NVARCHAR(100),
    circle          NVARCHAR(100),
    zone            NVARCHAR(50),
    city_tier       NVARCHAR(50)
);

-- STG_Tables = Plans --
DROP TABLE IF EXISTS stg.plans;
CREATE TABLE stg.plans (
    plan_id             NVARCHAR(50),
    plan_name           NVARCHAR(100),
    service_type        NVARCHAR(50),
    plan_category       NVARCHAR(50),
    contract_type       NVARCHAR(50),
    contract_months     NVARCHAR(50),
    launch_price        NVARCHAR(50),
    data_allowance_gb   NVARCHAR(50),
    speed_mbps          NVARCHAR(50),
    is_active           NVARCHAR(50)
);

-- STG_Tables = Plan Price History --
DROP TABLE IF EXISTS stg.plan_price_history;
CREATE TABLE stg.plan_price_history (
    price_history_id    NVARCHAR(50),
    plan_id             NVARCHAR(50),
    monthly_price       NVARCHAR(50),
    effective_from      NVARCHAR(50),
    effective_to        NVARCHAR(50)
);

-- STG_Tables = Churn Reason Codes --
DROP TABLE IF EXISTS stg.churn_reason_codes;
CREATE TABLE stg.churn_reason_codes (
    churn_reason_id     NVARCHAR(50),
    reason_code         NVARCHAR(50),
    reason_description  NVARCHAR(255),
    reason_category     NVARCHAR(100),
    applies_to          NVARCHAR(50)
);

-- STG_Tables = Retention Offer Catalog --
DROP TABLE IF EXISTS stg.retention_offer_catalog;
CREATE TABLE stg.retention_offer_catalog (
    offer_id                NVARCHAR(50),
    offer_name              NVARCHAR(255),
    offer_type              NVARCHAR(100),
    offer_value             NVARCHAR(50),
    offer_duration_months   NVARCHAR(50)
);

-- STG_Tables = Customers ---------------------------
DROP TABLE IF EXISTS stg.customers;
CREATE TABLE stg.customers (
    customer_id             NVARCHAR(50),
    signup_date             NVARCHAR(50),
    service_type            NVARCHAR(50),
    region_id               NVARCHAR(50),
    acquisition_channel     NVARCHAR(100),
    age_band                NVARCHAR(50),
    gender                  NVARCHAR(50),
    payment_method          NVARCHAR(50),
    paperless_billing_flag  NVARCHAR(50),
    account_status          NVARCHAR(50)
);

-- STG_Tables = Subscriptions ---------------------------
DROP TABLE IF EXISTS stg.subscriptions;
CREATE TABLE stg.subscriptions (
    subscription_id     NVARCHAR(50),
    customer_id         NVARCHAR(50),
    plan_id             NVARCHAR(50),
    start_date          NVARCHAR(50),
    end_date            NVARCHAR(50),
    contract_end_date   NVARCHAR(50),
    change_type         NVARCHAR(50),
    is_current          NVARCHAR(50)
);

-- STG_Tables = Discounts ---------------------------
DROP TABLE IF EXISTS stg.discounts;
CREATE TABLE stg.discounts (
    discount_id         NVARCHAR(50),
    customer_id         NVARCHAR(50),
    discount_type       NVARCHAR(100),
    discount_percent    NVARCHAR(50),
    start_date          NVARCHAR(50),
    end_date            NVARCHAR(50)
);

-- STG_Tables = Invoices -----------------------------------------
DROP TABLE IF EXISTS stg.invoices;
CREATE TABLE stg.invoices (
    invoice_id          NVARCHAR(50),
    customer_id         NVARCHAR(50),
    subscription_id     NVARCHAR(50),
    billing_month       NVARCHAR(50),
    invoice_date        NVARCHAR(50),
    due_date            NVARCHAR(50),
    base_amount         NVARCHAR(50),
    discount_amount     NVARCHAR(50),
    tax_amount          NVARCHAR(50),
    total_amount        NVARCHAR(50)
);

-- STG_Tables = Payments -----------------------------------------
DROP TABLE IF EXISTS stg.payments;
CREATE TABLE stg.payments (
    payment_id          NVARCHAR(50),
    invoice_id          NVARCHAR(50),
    customer_id         NVARCHAR(50),
    payment_date        NVARCHAR(50),
    amount_paid         NVARCHAR(50),
    payment_method      NVARCHAR(50),
    payment_status      NVARCHAR(50)
);

-- STG_Tables = Usage Monthly -----------------------------------------
DROP TABLE IF EXISTS stg.usage_monthly;
CREATE TABLE stg.usage_monthly (
    usage_id            NVARCHAR(50),
    customer_id         NVARCHAR(50),
    usage_month         NVARCHAR(50),
    data_used_gb        NVARCHAR(50),
    call_minutes        NVARCHAR(50),
    app_logins          NVARCHAR(50),
    avg_speed_mbps      NVARCHAR(50)
);

-- STG_Tables = Support Tickets -----------------------------------------
DROP TABLE IF EXISTS stg.support_tickets;
CREATE TABLE stg.support_tickets (
    ticket_id               NVARCHAR(50),
    customer_id             NVARCHAR(50),
    created_datetime        NVARCHAR(50),
    resolved_datetime       NVARCHAR(50),
    ticket_category         NVARCHAR(100),
    channel                 NVARCHAR(50),
    priority                NVARCHAR(50),
    resolution_status       NVARCHAR(50),
    is_repeat_complaint     NVARCHAR(50),
    csat_score              NVARCHAR(50),
    ticket_notes            NVARCHAR(1000)
);

-- STG_Tables = Network Incidents -----------------------------------------
DROP TABLE IF EXISTS stg.network_incidents;
CREATE TABLE stg.network_incidents (
    incident_id                 NVARCHAR(50),
    region_id                   NVARCHAR(50),
    service_type                NVARCHAR(50),
    incident_type               NVARCHAR(100),
    start_datetime              NVARCHAR(50),
    end_datetime                NVARCHAR(50),
    severity                    NVARCHAR(50),
    customers_affected_estimate NVARCHAR(50)
);

-- STG_Tables = Churn Events -----------------------------------------
DROP TABLE IF EXISTS stg.churn_events;
CREATE TABLE stg.churn_events (
    churn_id            NVARCHAR(50),
    customer_id         NVARCHAR(50),
    churn_date          NVARCHAR(50),
    churn_type          NVARCHAR(50),
    churn_reason_id     NVARCHAR(50),
    port_out_flag       NVARCHAR(50),
    competitor_name     NVARCHAR(100),
    last_plan_id        NVARCHAR(50)
);

-- STG_Tables = Retention Offers -----------------------------------------
DROP TABLE IF EXISTS stg.retention_offers;
CREATE TABLE stg.retention_offers (
    offer_event_id      NVARCHAR(50),
    customer_id         NVARCHAR(50),
    offer_id            NVARCHAR(50),
    offer_date          NVARCHAR(50),
    trigger_type        NVARCHAR(100),
    offer_cost          NVARCHAR(50),
    accepted_flag       NVARCHAR(50)
);
GO

-- --------------------------------------------------------------
-- 2.2 Load procedures (one per CSV): empty table -> BULK INSERT -> log result
-- --------------------------------------------------------------

-- regions ----------------------------------------------------
CREATE OR ALTER PROCEDURE stg.usp_load_regions
AS
BEGIN
    SET NOCOUNT ON;
 
    BEGIN TRY
        TRUNCATE TABLE stg.regions;
 
        BULK INSERT stg.regions
        FROM 'D:\END TO END PROJECT\ConnectPlus_Synthetic_Data\regions.csv'
        WITH (
            FORMAT          = 'CSV',
            FIRSTROW        = 2,
            FIELDQUOTE      = '"',
            FIELDTERMINATOR = ',',
            ROWTERMINATOR   = '0x0a',
            CODEPAGE        = '65001',
            TABLOCK
        );
 
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status)
        SELECT 'regions', COUNT(*), 'Success'
        FROM stg.regions;
    END TRY
    BEGIN CATCH
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status, error_message)
        VALUES ('regions', NULL, 'Failed', ERROR_MESSAGE());
    END CATCH
END;
GO
 
-- plans ----------------------------------------------------
CREATE OR ALTER PROCEDURE stg.usp_load_plans
AS
BEGIN
    SET NOCOUNT ON;
 
    BEGIN TRY
        TRUNCATE TABLE stg.plans;
 
        BULK INSERT stg.plans
        FROM 'D:\END TO END PROJECT\ConnectPlus_Synthetic_Data\plans.csv'
        WITH (
            FORMAT          = 'CSV',
            FIRSTROW        = 2,
            FIELDQUOTE      = '"',
            FIELDTERMINATOR = ',',
            ROWTERMINATOR   = '0x0a',
            CODEPAGE        = '65001',
            TABLOCK
        );
 
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status)
        SELECT 'plans', COUNT(*), 'Success'
        FROM stg.plans;
    END TRY
    BEGIN CATCH
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status, error_message)
        VALUES ('plans', NULL, 'Failed', ERROR_MESSAGE());
    END CATCH
END;
GO
 
-- plan_price_history ----------------------------------------------------
CREATE OR ALTER PROCEDURE stg.usp_load_plan_price_history
AS
BEGIN
    SET NOCOUNT ON;
 
    BEGIN TRY
        TRUNCATE TABLE stg.plan_price_history;
 
        BULK INSERT stg.plan_price_history
        FROM 'D:\END TO END PROJECT\ConnectPlus_Synthetic_Data\plan_price_history.csv'
        WITH (
            FORMAT          = 'CSV',
            FIRSTROW        = 2,
            FIELDQUOTE      = '"',
            FIELDTERMINATOR = ',',
            ROWTERMINATOR   = '0x0a',
            CODEPAGE        = '65001',
            TABLOCK
        );
 
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status)
        SELECT 'plan_price_history', COUNT(*), 'Success'
        FROM stg.plan_price_history;
    END TRY
    BEGIN CATCH
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status, error_message)
        VALUES ('plan_price_history', NULL, 'Failed', ERROR_MESSAGE());
    END CATCH
END;
GO
 
-- churn_reason_codes ----------------------------------------------------
CREATE OR ALTER PROCEDURE stg.usp_load_churn_reason_codes
AS
BEGIN
    SET NOCOUNT ON;
 
    BEGIN TRY
        TRUNCATE TABLE stg.churn_reason_codes;
 
        BULK INSERT stg.churn_reason_codes
        FROM 'D:\END TO END PROJECT\ConnectPlus_Synthetic_Data\churn_reason_codes.csv'
        WITH (
            FORMAT          = 'CSV',
            FIRSTROW        = 2,
            FIELDQUOTE      = '"',
            FIELDTERMINATOR = ',',
            ROWTERMINATOR   = '0x0a',
            CODEPAGE        = '65001',
            TABLOCK
        );
 
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status)
        SELECT 'churn_reason_codes', COUNT(*), 'Success'
        FROM stg.churn_reason_codes;
    END TRY
    BEGIN CATCH
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status, error_message)
        VALUES ('churn_reason_codes', NULL, 'Failed', ERROR_MESSAGE());
    END CATCH
END;
GO
 
-- retention_offer_catalog ----------------------------------------------------
CREATE OR ALTER PROCEDURE stg.usp_load_retention_offer_catalog
AS
BEGIN
    SET NOCOUNT ON;
 
    BEGIN TRY
        TRUNCATE TABLE stg.retention_offer_catalog;
 
        BULK INSERT stg.retention_offer_catalog
        FROM 'D:\END TO END PROJECT\ConnectPlus_Synthetic_Data\retention_offer_catalog.csv' 
        WITH (
            FORMAT          = 'CSV',
            FIRSTROW        = 2,
            FIELDQUOTE      = '"',
            FIELDTERMINATOR = ',',
            ROWTERMINATOR   = '0x0a',
            CODEPAGE        = '65001',
            TABLOCK
        );
 
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status)
        SELECT 'retention_offer_catalog', COUNT(*), 'Success'
        FROM stg.retention_offer_catalog;
    END TRY
    BEGIN CATCH
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status, error_message)
        VALUES ('retention_offer_catalog', NULL, 'Failed', ERROR_MESSAGE());
    END CATCH
END;
GO
 
-- customers ----------------------------------------------------
CREATE OR ALTER PROCEDURE stg.usp_load_customers
AS
BEGIN
    SET NOCOUNT ON;
 
    BEGIN TRY
        TRUNCATE TABLE stg.customers;
 
        BULK INSERT stg.customers
        FROM 'D:\END TO END PROJECT\ConnectPlus_Synthetic_Data\customers.csv' 
        WITH (
            FORMAT          = 'CSV',
            FIRSTROW        = 2,
            FIELDQUOTE      = '"',
            FIELDTERMINATOR = ',',
            ROWTERMINATOR   = '0x0a',
            CODEPAGE        = '65001',
            TABLOCK
        );
 
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status)
        SELECT 'customers', COUNT(*), 'Success'
        FROM stg.customers;
    END TRY
    BEGIN CATCH
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status, error_message)
        VALUES ('customers', NULL, 'Failed', ERROR_MESSAGE());
    END CATCH
END;
GO
 
-- subscriptions ----------------------------------------------------
CREATE OR ALTER PROCEDURE stg.usp_load_subscriptions
AS
BEGIN
    SET NOCOUNT ON;
 
    BEGIN TRY
        TRUNCATE TABLE stg.subscriptions;
 
        BULK INSERT stg.subscriptions
        FROM 'D:\END TO END PROJECT\ConnectPlus_Synthetic_Data\subscriptions.csv'
        WITH (
            FORMAT          = 'CSV',
            FIRSTROW        = 2,
            FIELDQUOTE      = '"',
            FIELDTERMINATOR = ',',
            ROWTERMINATOR   = '0x0a',
            CODEPAGE        = '65001',
            TABLOCK
        );
 
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status)
        SELECT 'subscriptions', COUNT(*), 'Success'
        FROM stg.subscriptions;
    END TRY
    BEGIN CATCH
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status, error_message)
        VALUES ('subscriptions', NULL, 'Failed', ERROR_MESSAGE());
    END CATCH
END;
GO
 
-- discounts ----------------------------------------------------
CREATE OR ALTER PROCEDURE stg.usp_load_discounts
AS
BEGIN
    SET NOCOUNT ON;
 
    BEGIN TRY
        TRUNCATE TABLE stg.discounts;
 
        BULK INSERT stg.discounts
        FROM 'D:\END TO END PROJECT\ConnectPlus_Synthetic_Data\discounts.csv'
        WITH (
            FORMAT          = 'CSV',
            FIRSTROW        = 2,
            FIELDQUOTE      = '"',
            FIELDTERMINATOR = ',',
            ROWTERMINATOR   = '0x0a',
            CODEPAGE        = '65001',
            TABLOCK
        );
 
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status)
        SELECT 'discounts', COUNT(*), 'Success'
        FROM stg.discounts;
    END TRY
    BEGIN CATCH
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status, error_message)
        VALUES ('discounts', NULL, 'Failed', ERROR_MESSAGE());
    END CATCH
END;
GO
 
-- invoices ----------------------------------------------------
CREATE OR ALTER PROCEDURE stg.usp_load_invoices
AS
BEGIN
    SET NOCOUNT ON;
 
    BEGIN TRY
        TRUNCATE TABLE stg.invoices;
 
        BULK INSERT stg.invoices
        FROM 'D:\END TO END PROJECT\ConnectPlus_Synthetic_Data\invoices.csv'
        WITH (
            FORMAT          = 'CSV',
            FIRSTROW        = 2,
            FIELDQUOTE      = '"',
            FIELDTERMINATOR = ',',
            ROWTERMINATOR   = '0x0a',
            CODEPAGE        = '65001',
            TABLOCK
        );
 
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status)
        SELECT 'invoices', COUNT(*), 'Success'
        FROM stg.invoices;
    END TRY
    BEGIN CATCH
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status, error_message)
        VALUES ('invoices', NULL, 'Failed', ERROR_MESSAGE());
    END CATCH
END;
GO
 
-- payments ----------------------------------------------------
CREATE OR ALTER PROCEDURE stg.usp_load_payments
AS
BEGIN
    SET NOCOUNT ON;
 
    BEGIN TRY
        TRUNCATE TABLE stg.payments;
 
        BULK INSERT stg.payments
        FROM 'D:\END TO END PROJECT\ConnectPlus_Synthetic_Data\payments.csv'
        WITH (
            FORMAT          = 'CSV',
            FIRSTROW        = 2,
            FIELDQUOTE      = '"',
            FIELDTERMINATOR = ',',
            ROWTERMINATOR   = '0x0a',
            CODEPAGE        = '65001',
            TABLOCK
        );
 
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status)
        SELECT 'payments', COUNT(*), 'Success'
        FROM stg.payments;
    END TRY
    BEGIN CATCH
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status, error_message)
        VALUES ('payments', NULL, 'Failed', ERROR_MESSAGE());
    END CATCH
END;
GO
 
-- usage_monthly ----------------------------------------------------
CREATE OR ALTER PROCEDURE stg.usp_load_usage_monthly
AS
BEGIN
    SET NOCOUNT ON;
 
    BEGIN TRY
        TRUNCATE TABLE stg.usage_monthly;
 
        BULK INSERT stg.usage_monthly
        FROM 'D:\END TO END PROJECT\ConnectPlus_Synthetic_Data\usage_monthly.csv'
        WITH (
            FORMAT          = 'CSV',
            FIRSTROW        = 2,
            FIELDQUOTE      = '"',
            FIELDTERMINATOR = ',',
            ROWTERMINATOR   = '0x0a',
            CODEPAGE        = '65001',
            TABLOCK
        );
 
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status)
        SELECT 'usage_monthly', COUNT(*), 'Success'
        FROM stg.usage_monthly;
    END TRY
    BEGIN CATCH
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status, error_message)
        VALUES ('usage_monthly', NULL, 'Failed', ERROR_MESSAGE());
    END CATCH
END;
GO
 
-- support_tickets ----------------------------------------------------
CREATE OR ALTER PROCEDURE stg.usp_load_support_tickets
AS
BEGIN
    SET NOCOUNT ON;
 
    BEGIN TRY
        TRUNCATE TABLE stg.support_tickets;
 
        BULK INSERT stg.support_tickets
        FROM 'D:\END TO END PROJECT\ConnectPlus_Synthetic_Data\support_tickets.csv'
        WITH (
            FORMAT          = 'CSV',
            FIRSTROW        = 2,
            FIELDQUOTE      = '"',
            FIELDTERMINATOR = ',',
            ROWTERMINATOR   = '0x0a',
            CODEPAGE        = '65001',
            TABLOCK
        );
 
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status)
        SELECT 'support_tickets', COUNT(*), 'Success'
        FROM stg.support_tickets;
    END TRY
    BEGIN CATCH
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status, error_message)
        VALUES ('support_tickets', NULL, 'Failed', ERROR_MESSAGE());
    END CATCH
END;
GO
 
-- network_incidents ----------------------------------------------------
CREATE OR ALTER PROCEDURE stg.usp_load_network_incidents
AS
BEGIN
    SET NOCOUNT ON;
 
    BEGIN TRY
        TRUNCATE TABLE stg.network_incidents;
 
        BULK INSERT stg.network_incidents
        FROM 'D:\END TO END PROJECT\ConnectPlus_Synthetic_Data\network_incidents.csv'
        WITH (
            FORMAT          = 'CSV',
            FIRSTROW        = 2,
            FIELDQUOTE      = '"',
            FIELDTERMINATOR = ',',
            ROWTERMINATOR   = '0x0a',
            CODEPAGE        = '65001',
            TABLOCK
        );
 
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status)
        SELECT 'network_incidents', COUNT(*), 'Success'
        FROM stg.network_incidents;
    END TRY
    BEGIN CATCH
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status, error_message)
        VALUES ('network_incidents', NULL, 'Failed', ERROR_MESSAGE());
    END CATCH
END;
GO
 
-- churn_events ----------------------------------------------------
CREATE OR ALTER PROCEDURE stg.usp_load_churn_events
AS
BEGIN
    SET NOCOUNT ON;
 
    BEGIN TRY
        TRUNCATE TABLE stg.churn_events;
 
        BULK INSERT stg.churn_events
        FROM 'D:\END TO END PROJECT\ConnectPlus_Synthetic_Data\churn_events.csv'
        WITH (
            FORMAT          = 'CSV',
            FIRSTROW        = 2,
            FIELDQUOTE      = '"',
            FIELDTERMINATOR = ',',
            ROWTERMINATOR   = '0x0a',
            CODEPAGE        = '65001',
            TABLOCK
        );
 
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status)
        SELECT 'churn_events', COUNT(*), 'Success'
        FROM stg.churn_events;
    END TRY
    BEGIN CATCH
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status, error_message)
        VALUES ('churn_events', NULL, 'Failed', ERROR_MESSAGE());
    END CATCH
END;
GO
 
-- retention_offers ----------------------------------------------------
CREATE OR ALTER PROCEDURE stg.usp_load_retention_offers
AS
BEGIN
    SET NOCOUNT ON;
 
    BEGIN TRY
        TRUNCATE TABLE stg.retention_offers;
 
        BULK INSERT stg.retention_offers
        FROM 'D:\END TO END PROJECT\ConnectPlus_Synthetic_Data\retention_offers.csv'
        WITH (
            FORMAT          = 'CSV',
            FIRSTROW        = 2,
            FIELDQUOTE      = '"',
            FIELDTERMINATOR = ',',
            ROWTERMINATOR   = '0x0a',
            CODEPAGE        = '65001',
            TABLOCK
        );
 
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status)
        SELECT 'retention_offers', COUNT(*), 'Success'
        FROM stg.retention_offers;
    END TRY
    BEGIN CATCH
        INSERT INTO audit.load_log (table_name, rows_loaded, load_status, error_message)
        VALUES ('retention_offers', NULL, 'Failed', ERROR_MESSAGE());
    END CATCH
END;
GO

-- --------------------------------------------------------------
-- 2.3 Master load procedure - runs all 15 loads in order
-- --------------------------------------------------------------

CREATE OR ALTER PROCEDURE stg.usp_load_all_bulkinsert_procedures
AS
BEGIN
    SET NOCOUNT ON;
 
    -- Reference tables
    EXEC stg.usp_load_regions;
    EXEC stg.usp_load_plans;
    EXEC stg.usp_load_plan_price_history;
    EXEC stg.usp_load_churn_reason_codes;
    EXEC stg.usp_load_retention_offer_catalog;
 
    -- Customer and subscription tables
    EXEC stg.usp_load_customers;
    EXEC stg.usp_load_subscriptions;
    EXEC stg.usp_load_discounts;
 
    -- Transaction tables
    EXEC stg.usp_load_invoices;
    EXEC stg.usp_load_payments;
    EXEC stg.usp_load_usage_monthly;
    EXEC stg.usp_load_support_tickets;
    EXEC stg.usp_load_network_incidents;
    EXEC stg.usp_load_churn_events;
    EXEC stg.usp_load_retention_offers;
END;
GO

/* ==================================================================
   PART 3: CLEANING (typed, de-duplicated, standardised data)
   ================================================================== */

-- --------------------------------------------------------------
-- 3.1 Clean tables
-- --------------------------------------------------------------

-- Clean tables - Regions -------------------------------------------
DROP TABLE IF EXISTS clean.regions;
CREATE TABLE clean.regions (
    region_id       NVARCHAR(10)  NOT NULL PRIMARY KEY,
    region_name     NVARCHAR(100) NOT NULL,
    circle          NVARCHAR(100) NOT NULL,
    zone            NVARCHAR(20)  NOT NULL,
    city_tier       NVARCHAR(20)  NOT NULL
);

-- Clean tables - Plans -------------------------------------------
DROP TABLE IF EXISTS clean.plans;
CREATE TABLE clean.plans (
    plan_id             NVARCHAR(10)  NOT NULL PRIMARY KEY,
    plan_name           NVARCHAR(100) NOT NULL,
    service_type        NVARCHAR(20)  NOT NULL,
    plan_category       NVARCHAR(20)  NOT NULL,
    contract_type       NVARCHAR(20)  NOT NULL,
    contract_months     INT           NOT NULL,
    launch_price        DECIMAL(10,2) NOT NULL,
    data_allowance_gb   INT           NOT NULL,
    speed_mbps          INT           NULL,       -- blank for mobile plans
    is_active           BIT           NOT NULL
);

-- Clean tables - Plan Price History  -------------------------------------------
DROP TABLE IF EXISTS clean.plan_price_history;
CREATE TABLE clean.plan_price_history (
    price_history_id    NVARCHAR(10)  NOT NULL PRIMARY KEY,
    plan_id             NVARCHAR(10)  NOT NULL,
    monthly_price       DECIMAL(10,2) NOT NULL,
    effective_from      DATE          NOT NULL,
    effective_to        DATE          NULL        -- NULL = current price
);

-- Clean tables - Churn Reason Codes  -------------------------------------------
DROP TABLE IF EXISTS clean.churn_reason_codes;
CREATE TABLE clean.churn_reason_codes (
    churn_reason_id     NVARCHAR(10)  NOT NULL PRIMARY KEY,
    reason_code         NVARCHAR(10)  NOT NULL,
    reason_description  NVARCHAR(255) NOT NULL,
    reason_category     NVARCHAR(50)  NOT NULL,
    applies_to          NVARCHAR(20)  NOT NULL
);

-- Clean tables - Retention Offer Catalog  -------------------------------------------
DROP TABLE IF EXISTS clean.retention_offer_catalog;
CREATE TABLE clean.retention_offer_catalog (
    offer_id                NVARCHAR(10)  NOT NULL PRIMARY KEY,
    offer_name              NVARCHAR(255) NOT NULL,
    offer_type              NVARCHAR(50)  NOT NULL,
    offer_value             INT           NOT NULL,   -- % / GB / tiers depending on offer_type
    offer_duration_months   INT           NOT NULL
);
 
-- Clean tables - Customers  ------------------------------------------------
DROP TABLE IF EXISTS clean.customers;
CREATE TABLE clean.customers (
    customer_id             NVARCHAR(20)  NOT NULL PRIMARY KEY,
    signup_date             DATE          NOT NULL,
    service_type            NVARCHAR(20)  NOT NULL,
    region_id               NVARCHAR(10)  NOT NULL,
    acquisition_channel     NVARCHAR(50)  NOT NULL,
    age_band                NVARCHAR(20)  NOT NULL,
    gender                  NVARCHAR(20)  NOT NULL,
    payment_method          NVARCHAR(20)  NOT NULL,
    paperless_billing_flag  BIT           NOT NULL,
    account_status          NVARCHAR(20)  NOT NULL
);

-- Clean tables - Subscription  -------------------------------------------
DROP TABLE IF EXISTS clean.subscriptions;
CREATE TABLE clean.subscriptions (
    subscription_id     NVARCHAR(20)  NOT NULL PRIMARY KEY,
    customer_id         NVARCHAR(20)  NOT NULL,
    plan_id             NVARCHAR(10)  NOT NULL,
    start_date          DATE          NOT NULL,
    end_date            DATE          NULL,       -- NULL = current subscription
    contract_end_date   DATE          NULL,       -- NULL = month-to-month plan
    change_type         NVARCHAR(20)  NOT NULL,
    is_current          BIT           NOT NULL
);

-- Clean tables - Discounts  -------------------------------------------
DROP TABLE IF EXISTS clean.discounts;
CREATE TABLE clean.discounts (
    discount_id         NVARCHAR(20)  NOT NULL PRIMARY KEY,
    customer_id         NVARCHAR(20)  NOT NULL,
    discount_type       NVARCHAR(50)  NOT NULL,
    discount_percent    INT           NOT NULL,
    start_date          DATE          NOT NULL,
    end_date            DATE          NOT NULL
);
 
-- Clean tables - Chrun Events  -------------------------------------------
DROP TABLE IF EXISTS clean.churn_events;
CREATE TABLE clean.churn_events (
    churn_id            NVARCHAR(20)  NOT NULL PRIMARY KEY,
    customer_id         NVARCHAR(20)  NOT NULL,
    churn_date          DATE          NOT NULL,
    churn_type          NVARCHAR(20)  NOT NULL,
    churn_reason_id     NVARCHAR(10)  NOT NULL,
    port_out_flag       BIT           NOT NULL,
    competitor_name     NVARCHAR(100) NULL,       -- only when known
    last_plan_id        NVARCHAR(10)  NOT NULL
);

-- Clean tables - Invoices  -------------------------------------------
DROP TABLE IF EXISTS clean.invoices;
CREATE TABLE clean.invoices (
    invoice_id          NVARCHAR(20)  NOT NULL PRIMARY KEY,
    customer_id         NVARCHAR(20)  NOT NULL,
    subscription_id     NVARCHAR(20)  NOT NULL,
    billing_month       DATE          NOT NULL,
    invoice_date        DATE          NOT NULL,
    due_date            DATE          NOT NULL,
    base_amount         DECIMAL(12,2) NOT NULL,
    discount_amount     DECIMAL(12,2) NOT NULL,
    tax_amount          DECIMAL(12,2) NOT NULL,
    total_amount        DECIMAL(12,2) NOT NULL,
    is_credit_note      BIT           NOT NULL    -- 1 = refund / credit adjustment
);

-- Clean tables - Payments  ------------------------------------------- 
DROP TABLE IF EXISTS clean.payments;
CREATE TABLE clean.payments (
    payment_id          NVARCHAR(20)  NOT NULL PRIMARY KEY,
    invoice_id          NVARCHAR(20)  NOT NULL,
    customer_id         NVARCHAR(20)  NOT NULL,
    payment_date        DATE          NOT NULL,
    amount_paid         DECIMAL(12,2) NOT NULL,
    payment_method      NVARCHAR(20)  NOT NULL,
    payment_status      NVARCHAR(20)  NOT NULL
);

-- Clean tables - Usage Monthly  -------------------------------------------
DROP TABLE IF EXISTS clean.usage_monthly;
CREATE TABLE clean.usage_monthly (
    usage_id            NVARCHAR(20)  NOT NULL PRIMARY KEY,
    customer_id         NVARCHAR(20)  NOT NULL,
    usage_month         DATE          NOT NULL,
    data_used_gb        DECIMAL(10,2) NOT NULL,
    call_minutes        INT           NULL,       -- NULL for broadband
    app_logins          INT           NOT NULL,
    avg_speed_mbps      DECIMAL(8,1)  NULL,       -- NULL for mobile
    is_outlier          BIT           NOT NULL    -- 1 = usage spike > 5x customer median
);

-- Clean tables - Support Tickets  -------------------------------------------
DROP TABLE IF EXISTS clean.support_tickets;
CREATE TABLE clean.support_tickets (
    ticket_id               NVARCHAR(20)   NOT NULL PRIMARY KEY,
    customer_id             NVARCHAR(20)   NOT NULL,
    created_datetime        DATETIME2(0)   NOT NULL,
    resolved_datetime       DATETIME2(0)   NULL,   -- NULL = open, or invalid date removed
    ticket_category         NVARCHAR(50)   NOT NULL,
    channel                 NVARCHAR(20)   NOT NULL,
    priority                NVARCHAR(20)   NOT NULL,
    resolution_status       NVARCHAR(20)   NOT NULL,
    is_repeat_complaint     BIT            NOT NULL,
    csat_score              TINYINT        NULL,   -- only when the customer responded
    ticket_notes            NVARCHAR(1000) NULL,
    resolution_hours        DECIMAL(10,2)  NULL,
    is_invalid_resolution   BIT            NOT NULL,   -- 1 = resolved before created in source
    is_resolution_outlier   BIT            NOT NULL    -- 1 = took more than 500 hours
);

-- Clean tables - Network Incidents  ------------------------------------------- 
DROP TABLE IF EXISTS clean.network_incidents;
CREATE TABLE clean.network_incidents (
    incident_id                 NVARCHAR(20)  NOT NULL PRIMARY KEY,
    region_id                   NVARCHAR(10)  NOT NULL,
    service_type                NVARCHAR(20)  NOT NULL,
    incident_type               NVARCHAR(50)  NOT NULL,
    start_datetime              DATETIME2(0)  NOT NULL,
    end_datetime                DATETIME2(0)  NOT NULL,
    duration_hours              DECIMAL(10,2) NOT NULL,
    severity                    NVARCHAR(20)  NOT NULL,
    customers_affected_estimate INT           NOT NULL
);

-- Clean tables - Retention Offers  -------------------------------------------
DROP TABLE IF EXISTS clean.retention_offers;
CREATE TABLE clean.retention_offers (
    offer_event_id      NVARCHAR(20)  NOT NULL PRIMARY KEY,
    customer_id         NVARCHAR(20)  NOT NULL,
    offer_id            NVARCHAR(10)  NOT NULL,
    offer_date          DATE          NOT NULL,
    trigger_type        NVARCHAR(50)  NOT NULL,
    offer_cost          DECIMAL(10,2) NOT NULL,
    accepted_flag       BIT           NOT NULL
);
GO

-- --------------------------------------------------------------
-- 3.2 Cleaning procedures: empty clean table -> insert cleaned rows -> log fixes
-- --------------------------------------------------------------

-- ------------------------------------------------------------
-- 3.1 regions 
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE clean.usp_clean_regions                        
AS
BEGIN
    SET NOCOUNT ON;
 
    TRUNCATE TABLE clean.regions;
 
    INSERT INTO clean.regions (region_id, region_name, circle, zone, city_tier)

    SELECT UPPER(TRIM(region_id)),
     
           CASE UPPER(TRIM(region_name))
                WHEN 'MUMBAI'    THEN 'Mumbai'
                WHEN 'DELHI NCR' THEN 'Delhi NCR'
                ELSE TRIM(region_name)
           END,

           TRIM(circle), 
           TRIM(zone), 
           TRIM(city_tier)

    FROM stg.regions;
 
    -- Log: compare raw vs clean exactly --
    INSERT INTO audit.data_quality_log (table_name, issue, rows_affected, action_taken)
    
    SELECT 
    'regions', 
    'region_name had extra spaces or wrong capitalization', 
    COUNT(*),
    'FIX: trimmed and corrected to approved names'

    FROM stg.regions AS s
    JOIN clean.regions AS c 
   
    ON c.region_id = UPPER(TRIM(s.region_id))
    WHERE '[' + s.region_name + ']' COLLATE Latin1_General_CS_AS <> '[' + c.region_name + ']';
END;
GO

-- ------------------------------------------------------------
-- 3.2 plans 
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE clean.usp_clean_plans
AS
BEGIN
    SET NOCOUNT ON;
 
    TRUNCATE TABLE clean.plans;
 
    WITH p AS 
    (
        SELECT *, TRIM(REPLACE(plan_name, '  ', ' ')) AS name_fixed   -- remove double and outer spaces
        FROM stg.plans
    )
    
    INSERT INTO clean.plans 
    (plan_id, plan_name, service_type, plan_category, contract_type,contract_months, launch_price, data_allowance_gb, speed_mbps, is_active)
    
    SELECT UPPER(TRIM(plan_id)),
    
    CASE UPPER(name_fixed)
                WHEN 'MOBILE STANDARD 12M' THEN 'Mobile Standard 12M'
                WHEN 'FIBER ULTRA 24M'     THEN 'Fiber Ultra 24M'
                ELSE name_fixed
    END,
    TRIM(service_type), 
    TRIM(plan_category), 
    TRIM(contract_type),
    CAST(contract_months AS INT),
    CAST(launch_price AS DECIMAL(10,2)),
    CAST(data_allowance_gb AS INT),
    TRY_CAST(NULLIF(TRIM(speed_mbps), '') AS INT),
    CAST(is_active AS BIT)
    
    FROM p;
 
    INSERT INTO audit.data_quality_log (table_name, issue, rows_affected, action_taken)
    SELECT 'plans', 'plan_name had extra spaces or wrong capitalization', COUNT(*),
           'FIX: trimmed, removed double spaces, corrected to approved names'
    FROM stg.plans AS s
    JOIN clean.plans AS c ON c.plan_id = UPPER(TRIM(s.plan_id))
    WHERE '[' + s.plan_name + ']' COLLATE Latin1_General_CS_AS <> '[' + c.plan_name + ']';
END;
GO
 
-- ------------------------------------------------------------
-- 3.3 plan_price_history  
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE clean.usp_clean_plan_price_history
AS
BEGIN
    SET NOCOUNT ON;
 
    TRUNCATE TABLE clean.plan_price_history;
 
    INSERT INTO clean.plan_price_history (price_history_id, plan_id, monthly_price, effective_from, effective_to)
    
    SELECT UPPER(TRIM(price_history_id)),
           UPPER(TRIM(plan_id)),
           CAST(monthly_price AS DECIMAL(10,2)),
           CONVERT(DATE, effective_from, 23),
           TRY_CONVERT(DATE, NULLIF(TRIM(effective_to), ''), 23)
    FROM stg.plan_price_history;
END;
GO
 
-- ------------------------------------------------------------
-- 3.4 churn_reason_codes  
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE clean.usp_clean_churn_reason_codes
AS
BEGIN
    SET NOCOUNT ON;
 
    TRUNCATE TABLE clean.churn_reason_codes;
 
    INSERT INTO clean.churn_reason_codes (churn_reason_id, reason_code, reason_description, reason_category, applies_to)
    
    SELECT 

    UPPER(TRIM(churn_reason_id)), 
    UPPER(TRIM(reason_code)), 
    TRIM(reason_description),
    TRIM(reason_category), 
    TRIM(applies_to)
    
    FROM stg.churn_reason_codes;
 
    -- Placeholder reason so churn events with no captured reason are kept, not dropped
    INSERT INTO clean.churn_reason_codes (churn_reason_id, reason_code, reason_description, reason_category, applies_to)
    VALUES ('CR00', 'UNK', 'Reason not captured', 'Unknown', 'Voluntary');
 
    INSERT INTO audit.data_quality_log (table_name, issue, rows_affected, action_taken)
    VALUES ('churn_reason_codes', 'No code existed for churn events without a reason', 1,
            'FIX: added reason CR00 = Unknown');
END;
GO
 
-- ------------------------------------------------------------
-- 3.5 retention_offer_catalog  
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE clean.usp_clean_retention_offer_catalog
AS
BEGIN
    SET NOCOUNT ON;
 
    TRUNCATE TABLE clean.retention_offer_catalog;
 
    INSERT INTO clean.retention_offer_catalog (offer_id, offer_name, offer_type, offer_value, offer_duration_months)
    
    SELECT 
    
    UPPER(TRIM(offer_id)), 
    TRIM(offer_name), 
    TRIM(offer_type),
    CAST(offer_value AS INT), 
    CAST(offer_duration_months AS INT)
    
    FROM stg.retention_offer_catalog;
END;
GO

 
-- ------------------------------------------------------------
-- 3.6 customers
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE clean.usp_clean_customers
AS
BEGIN
    SET NOCOUNT ON;
 
    -- Step 1: prepare every staging row with raw + cleaned values side by side
    DROP TABLE IF EXISTS #c;
 
    SELECT
        UPPER(TRIM(customer_id)) AS customer_id,
        signup_date              AS signup_raw,
        
        CASE
            WHEN signup_date LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' THEN TRY_CONVERT(DATE, signup_date, 23)   -- YYYY-MM-DD
            WHEN signup_date LIKE '[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, signup_date, 105)  -- DD-MM-YYYY
            WHEN signup_date LIKE '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, signup_date, 103)  -- DD/MM/YYYY
        END                      AS signup_date,
        
        TRIM(service_type)       AS service_type,
        
        region_id                AS region_raw,
        
        UPPER(TRIM(region_id))   AS region_id,
        
        TRIM(acquisition_channel) AS acquisition_channel,
        
        age_band                 AS age_raw,
        
        ISNULL(NULLIF(TRIM(age_band), ''), 'Unknown') AS age_band,
        
        UPPER(LEFT(TRIM(gender), 1)) + LOWER(SUBSTRING(TRIM(gender), 2, 50)) AS gender,   -- FEMALE -> Female
        
        payment_method           AS payment_raw,
        
        ISNULL(NULLIF(TRIM(payment_method), ''), 'Unknown') AS payment_method,
        
        CAST(paperless_billing_flag AS BIT) AS paperless_billing_flag,
        
        TRIM(account_status)     AS account_status,
        
        
        -- Duplicate ranking: prefer the copy with a standard date and no stray spaces
        ROW_NUMBER() OVER 
        (
            PARTITION BY UPPER(TRIM(customer_id))
            
            ORDER BY 
            CASE WHEN signup_date LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' THEN 0 
            ELSE 1 
            END,
            DATALENGTH(acquisition_channel)

        ) AS rn
    INTO #c

    FROM stg.customers;
 
    -- Step 2: load one row per customer
    TRUNCATE TABLE clean.customers;
 
    INSERT INTO clean.customers (customer_id, signup_date, service_type, region_id, acquisition_channel,age_band, gender, payment_method, paperless_billing_flag, account_status)
    
    SELECT 
    customer_id, signup_date, service_type, region_id, acquisition_channel,
    age_band, gender, payment_method, paperless_billing_flag, account_status
    FROM #c

    WHERE rn = 1;
 
    -- Step 3: log every treatment
    INSERT INTO audit.data_quality_log (table_name, issue, rows_affected, action_taken)
    
    SELECT 'customers', 'Duplicate customer records', COUNT(*),
           'REMOVE: kept one row per customer'
    FROM #c WHERE rn > 1

    UNION ALL

    SELECT 'customers', 'signup_date not in YYYY-MM-DD format', COUNT(*),
           'FIX: converted DD-MM-YYYY / DD/MM/YYYY to DATE'
    FROM #c WHERE rn = 1 AND signup_raw NOT LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'

    UNION ALL

    SELECT 'customers', 'region_id lowercase or with extra spaces', COUNT(*),
           'FIX: trimmed and uppercased'
    FROM #c WHERE rn = 1 AND '[' + region_raw + ']' COLLATE Latin1_General_CS_AS <> '[' + region_id + ']'

    UNION ALL

    SELECT 'customers', 'age_band missing', COUNT(*),
           'FIX: replaced with Unknown'
    FROM #c WHERE rn = 1 AND NULLIF(TRIM(age_raw), '') IS NULL

    UNION ALL

    SELECT 'customers', 'payment_method missing', COUNT(*),
           'FIX: replaced with Unknown'
    FROM #c WHERE rn = 1 AND NULLIF(TRIM(payment_raw), '') IS NULL;

END;
GO

-- ------------------------------------------------------------
-- 3.7 churn_events  
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE clean.usp_clean_churn_events
AS
BEGIN
    SET NOCOUNT ON;
 
    TRUNCATE TABLE clean.churn_events;
 
    INSERT INTO clean.churn_events (churn_id, customer_id, churn_date, churn_type, churn_reason_id,
                                    port_out_flag, competitor_name, last_plan_id)
    SELECT 
    
    UPPER(TRIM(churn_id)),
           UPPER(TRIM(customer_id)),
           CONVERT(DATE, churn_date, 23),
           TRIM(churn_type),
           ISNULL(NULLIF(UPPER(TRIM(churn_reason_id)), ''), 'CR00'),
           CAST(port_out_flag AS BIT),
           NULLIF(TRIM(competitor_name), ''),
           UPPER(TRIM(last_plan_id))

    FROM stg.churn_events;
 
    INSERT INTO audit.data_quality_log (table_name, issue, rows_affected, action_taken)
    
    SELECT 'churn_events', 'churn_reason_id missing', COUNT(*),
           'FIX: mapped to CR00 (Unknown), row kept'
    FROM stg.churn_events
    WHERE NULLIF(TRIM(churn_reason_id), '') IS NULL;
END;
GO

-- ------------------------------------------------------------
-- 3.8 subscriptions  
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE clean.usp_clean_subscriptions
AS
BEGIN
    SET NOCOUNT ON;
 
    TRUNCATE TABLE clean.subscriptions;
 
    INSERT INTO clean.subscriptions (subscription_id, customer_id, plan_id, start_date, end_date,
                                     contract_end_date, change_type, is_current)
    SELECT UPPER(TRIM(subscription_id)),
           UPPER(TRIM(customer_id)),
           UPPER(TRIM(plan_id)),
           CONVERT(DATE, start_date, 23),
           TRY_CONVERT(DATE, NULLIF(TRIM(end_date), ''), 23),
           TRY_CONVERT(DATE, NULLIF(TRIM(contract_end_date), ''), 23),
           TRIM(change_type),
           CAST(is_current AS BIT)
    FROM stg.subscriptions;
END;
GO
 
-- ------------------------------------------------------------
-- 3.9 discounts  (no issues - type conversion only)
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE clean.usp_clean_discounts
AS
BEGIN
    SET NOCOUNT ON;
 
    TRUNCATE TABLE clean.discounts;
 
    INSERT INTO clean.discounts (discount_id, customer_id, discount_type, discount_percent, start_date, end_date)
    SELECT UPPER(TRIM(discount_id)),
           UPPER(TRIM(customer_id)),
           TRIM(discount_type),
           CAST(discount_percent AS INT),
           CONVERT(DATE, start_date, 23),
           CONVERT(DATE, end_date, 23)
    FROM stg.discounts;
END;
GO

-- ------------------------------------------------------------
-- 3.10 invoices
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE clean.usp_clean_invoices
AS
BEGIN
    SET NOCOUNT ON;
 
    DROP TABLE IF EXISTS #i;
 
    SELECT 
    
    UPPER(TRIM(i.invoice_id))      AS invoice_id,
    UPPER(TRIM(i.customer_id))     AS customer_id,
    UPPER(TRIM(i.subscription_id)) AS subscription_id,
    CONVERT(DATE, i.billing_month, 23) AS billing_month,
    CONVERT(DATE, i.invoice_date, 23)  AS invoice_date,
    CONVERT(DATE, i.due_date, 23)      AS due_date,
    CAST(i.base_amount     AS DECIMAL(12,2)) AS base_amount,
    CAST(i.discount_amount AS DECIMAL(12,2)) AS discount_amount,
    CAST(i.tax_amount      AS DECIMAL(12,2)) AS tax_amount,
    CAST(i.total_amount    AS DECIMAL(12,2)) AS total_amount,
    ch.churn_date

    INTO #i

    FROM stg.invoices AS i

    LEFT JOIN clean.churn_events AS ch 
    ON 
    ch.customer_id = UPPER(TRIM(i.customer_id));
 
    TRUNCATE TABLE clean.invoices;
 
    INSERT INTO clean.invoices (invoice_id, customer_id, subscription_id, billing_month, invoice_date, due_date,
                                base_amount, discount_amount, tax_amount, total_amount, is_credit_note)
    
    SELECT 
    invoice_id, 
    customer_id, 
    subscription_id,
    billing_month, 
    invoice_date, 
    due_date,
    base_amount, 
    discount_amount, 
    tax_amount, 
    total_amount,
           
    CASE WHEN total_amount < 0 THEN 1 
    ELSE 0 
    END
    FROM #i

    WHERE NOT (total_amount >= 0 AND churn_date IS NOT NULL AND invoice_date > churn_date);
 
    INSERT INTO audit.data_quality_log (table_name, issue, rows_affected, action_taken)
    
    SELECT 'invoices', 'Negative invoices (credit notes / refunds)', COUNT(*),
           'FLAG: kept with is_credit_note = 1; exclude from ARPU'
    FROM #i WHERE total_amount < 0

    UNION ALL

    SELECT 'invoices', 'Regular invoices dated after churn date', COUNT(*),
           'REMOVE: activity after churn'
    FROM #i WHERE total_amount >= 0 AND churn_date IS NOT NULL AND invoice_date > churn_date;
END;
GO

-- ------------------------------------------------------------
-- 3.11 payments  
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE clean.usp_clean_payments
AS
BEGIN
    SET NOCOUNT ON;
 
    DROP TABLE IF EXISTS #p;
 
    SELECT 
    UPPER(TRIM(payment_id)) AS payment_id,
    UPPER(TRIM(invoice_id)) AS invoice_id,
    UPPER(TRIM(customer_id)) AS customer_id,
    payment_date AS payment_date_raw,
    
    CASE
      WHEN payment_date LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' THEN TRY_CONVERT(DATE, payment_date, 23)
      WHEN payment_date LIKE '[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, payment_date, 105)
    END AS payment_date,
           
    CAST(amount_paid AS DECIMAL(12,2)) AS amount_paid,
    TRIM(payment_method) AS payment_method,
    TRIM(payment_status) AS payment_status
    INTO #p

    FROM stg.payments;
 
    TRUNCATE TABLE clean.payments;
 
    -- Only keep payments whose invoice exists in clean.invoices
    INSERT INTO clean.payments (payment_id, invoice_id, customer_id, payment_date, amount_paid, payment_method, payment_status)
    
    SELECT p.payment_id, p.invoice_id, p.customer_id, p.payment_date, p.amount_paid, p.payment_method, p.payment_status
    FROM #p AS p

    WHERE EXISTS (SELECT 1 FROM clean.invoices AS i WHERE i.invoice_id = p.invoice_id);
 
    INSERT INTO audit.data_quality_log (table_name, issue, rows_affected, action_taken)
    
    SELECT 'payments', 'payment_date in DD-MM-YYYY format', COUNT(*),
           'FIX: converted to DATE'
    FROM #p WHERE payment_date_raw NOT LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
    
    UNION ALL
    
    SELECT 'payments', 'Payments for invoices not in clean.invoices', COUNT(*),
           'REMOVE: orphan payment'
    FROM #p AS p
    WHERE NOT EXISTS (SELECT 1 FROM clean.invoices AS i WHERE i.invoice_id = p.invoice_id);
END;
GO

-- ------------------------------------------------------------
-- 3.12 usage_monthly
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE clean.usp_clean_usage_monthly
AS
BEGIN
    SET NOCOUNT ON;
 
    DROP TABLE IF EXISTS #u;
 
    SELECT 

    UPPER(TRIM(u.usage_id))    AS usage_id,
    UPPER(TRIM(u.customer_id)) AS customer_id,
    CONVERT(DATE, u.usage_month, 23) AS usage_month,
    CAST(u.data_used_gb AS DECIMAL(10,2)) AS data_used_gb,
    TRY_CAST(NULLIF(TRIM(u.call_minutes), '') AS INT)            AS call_minutes,
    CAST(u.app_logins AS INT)                                    AS app_logins,
    TRY_CAST(NULLIF(TRIM(u.avg_speed_mbps), '') AS DECIMAL(8,1)) AS avg_speed_mbps,
    
    CASE 

    WHEN ch.churn_date IS NOT NULL AND CONVERT(DATE, u.usage_month, 23) > DATEFROMPARTS(YEAR(ch.churn_date), MONTH(ch.churn_date), 1) THEN 1 
    ELSE 0 
    END AS after_churn

    INTO #u
    FROM stg.usage_monthly AS u
    LEFT JOIN clean.churn_events AS ch 
    ON 
    ch.customer_id = UPPER(TRIM(u.customer_id));
 
    TRUNCATE TABLE clean.usage_monthly;
 
    INSERT INTO clean.usage_monthly (usage_id, customer_id, usage_month, data_used_gb, call_minutes,
                                     app_logins, avg_speed_mbps, is_outlier)
    SELECT usage_id, customer_id, usage_month, data_used_gb, call_minutes, app_logins, avg_speed_mbps, 0
    FROM #u
    WHERE after_churn = 0;
 
    -- Flag spikes: compare each month with the same customer's median month
    WITH med AS (
        SELECT usage_id, data_used_gb,
               PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY data_used_gb)
                   OVER (PARTITION BY customer_id) AS median_gb
        FROM clean.usage_monthly
    )
    UPDATE u
    SET is_outlier = 1
    FROM clean.usage_monthly AS u
    JOIN med AS m ON m.usage_id = u.usage_id
    WHERE m.data_used_gb > 5 * m.median_gb;
 
    INSERT INTO audit.data_quality_log (table_name, issue, rows_affected, action_taken)
    SELECT 'usage_monthly', 'Usage recorded after churn month', COUNT(*),
           'REMOVE: activity after churn'
    FROM #u WHERE after_churn = 1
    UNION ALL
    SELECT 'usage_monthly', 'Data usage spike above 5x customer median', COUNT(*),
           'FLAG: kept with is_outlier = 1; exclude from averages'
    FROM clean.usage_monthly WHERE is_outlier = 1;
END;
GO

 
-- ------------------------------------------------------------
-- 3.13 support_tickets
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE clean.usp_clean_support_tickets
AS
BEGIN
    SET NOCOUNT ON;
 
    DROP TABLE IF EXISTS #t;
 
    SELECT UPPER(TRIM(ticket_id))   AS ticket_id,
           UPPER(TRIM(customer_id)) AS customer_id,
           created_datetime         AS created_raw,
           
           CASE
               WHEN created_datetime LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' THEN TRY_CONVERT(DATETIME2(0), created_datetime, 120)
               
               WHEN created_datetime LIKE '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9] [0-9][0-9]:[0-9][0-9]'
                   -- Build the datetime from its parts: DD/MM/YYYY HH:MM
               THEN DATETIME2FROMPARTS(CAST(SUBSTRING(created_datetime, 7, 4)  AS INT),   -- year
                                           CAST(SUBSTRING(created_datetime, 4, 2)  AS INT),   -- month
                                           CAST(SUBSTRING(created_datetime, 1, 2)  AS INT),   -- day
                                           CAST(SUBSTRING(created_datetime, 12, 2) AS INT),   -- hour
                                           CAST(SUBSTRING(created_datetime, 15, 2) AS INT),   -- minute
                                           0, 0, 0)
           END AS created_dt,
           TRY_CONVERT(DATETIME2(0), 
           NULLIF(TRIM(resolved_datetime), ''), 120) AS resolved_dt,
           TRIM(ticket_category)   AS ticket_category,
           TRIM(channel)           AS channel,
           TRIM(priority)          AS priority,
           TRIM(resolution_status) AS resolution_status,
           CAST(is_repeat_complaint AS BIT)                     AS is_repeat_complaint,
           TRY_CAST(NULLIF(TRIM(csat_score), '') AS TINYINT)    AS csat_score,
           NULLIF(TRIM(ticket_notes), '')                       AS ticket_notes
    INTO #t
    FROM stg.support_tickets;
 
    TRUNCATE TABLE clean.support_tickets;
 
    INSERT INTO clean.support_tickets (ticket_id, customer_id, created_datetime, resolved_datetime, ticket_category,
                                       channel, priority, resolution_status, is_repeat_complaint, csat_score,
                                       ticket_notes, resolution_hours, is_invalid_resolution, is_resolution_outlier)
    
    SELECT ticket_id, customer_id, created_dt,
    
    CASE WHEN resolved_dt < created_dt THEN NULL 
    ELSE resolved_dt 
    END,
    ticket_category, 
    channel, 
    priority, 
    resolution_status, 
    is_repeat_complaint, 
    csat_score, 
    ticket_notes,
           
           CASE WHEN resolved_dt >= created_dt
                THEN CAST(DATEDIFF(MINUTE, created_dt, resolved_dt) / 60.0 AS DECIMAL(10,2)) END,
           
           CASE WHEN resolved_dt < created_dt THEN 1 ELSE 0 END,
           
           CASE WHEN resolved_dt >= created_dt
                 AND DATEDIFF(MINUTE, created_dt, resolved_dt) / 60.0 > 500 THEN 1 ELSE 0 END
    FROM #t;
 
    INSERT INTO audit.data_quality_log(table_name, issue, rows_affected, action_taken)
    SELECT 'support_tickets', 'created_datetime in DD/MM/YYYY HH:MM format', COUNT(*),
           'FIX: converted to DATETIME'
    FROM #t WHERE created_raw NOT LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] %'
    UNION ALL
    SELECT 'support_tickets', 'Resolved before created', COUNT(*),
           'FIX: resolved date set to NULL, flagged is_invalid_resolution = 1'
    FROM #t WHERE resolved_dt < created_dt
    UNION ALL
    SELECT 'support_tickets', 'Resolution took more than 500 hours', COUNT(*),
           'FLAG: kept with is_resolution_outlier = 1; exclude from average resolution time'
    FROM #t WHERE resolved_dt >= created_dt AND DATEDIFF(MINUTE, created_dt, resolved_dt) / 60.0 > 500;
END;
GO

-- ------------------------------------------------------------
-- 3.14 network_incidents  
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE clean.usp_clean_network_incidents
AS
BEGIN
    SET NOCOUNT ON;
 
    TRUNCATE TABLE clean.network_incidents;
 
    INSERT INTO clean.network_incidents (incident_id, region_id, service_type, incident_type, start_datetime,
                                         end_datetime, duration_hours, severity, customers_affected_estimate)
    SELECT UPPER(TRIM(incident_id)),
           UPPER(TRIM(region_id)),
           TRIM(service_type),
           TRIM(incident_type),
           CONVERT(DATETIME2(0), start_datetime, 120),
           CONVERT(DATETIME2(0), end_datetime, 120),
           CAST(DATEDIFF(MINUTE, CONVERT(DATETIME2(0), start_datetime, 120),
                                 CONVERT(DATETIME2(0), end_datetime, 120)) / 60.0 AS DECIMAL(10,2)),
           TRIM(severity),
           CAST(customers_affected_estimate AS INT)
    FROM stg.network_incidents;
 
    INSERT INTO audit.data_quality_log (table_name, issue, rows_affected, action_taken)
    SELECT 'network_incidents', 'region_id lowercase or with extra spaces', COUNT(*),
           'FIX: trimmed and uppercased'
    FROM stg.network_incidents
    WHERE '[' + region_id + ']' COLLATE Latin1_General_CS_AS <> '[' + UPPER(TRIM(region_id)) + ']';
END;
GO

-- ------------------------------------------------------------
-- 3.15 retention_offers  (no issues - type conversion only)
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE clean.usp_clean_retention_offers
AS
BEGIN
    SET NOCOUNT ON;
 
    TRUNCATE TABLE clean.retention_offers;
 
    INSERT INTO clean.retention_offers (offer_event_id, customer_id, offer_id, offer_date, trigger_type, offer_cost, accepted_flag)
    SELECT UPPER(TRIM(offer_event_id)),
           UPPER(TRIM(customer_id)),
           UPPER(TRIM(offer_id)),
           CONVERT(DATE, offer_date, 23),
           TRIM(trigger_type),
           CAST(offer_cost AS DECIMAL(10,2)),
           CAST(accepted_flag AS BIT)
    FROM stg.retention_offers;
END;
GO

-- --------------------------------------------------------------
-- 3.3 Master cleaning procedure (order matters: churn events before invoices and usage)
-- --------------------------------------------------------------

CREATE OR ALTER PROCEDURE clean.usp_clean_all_cleaning_procedure
AS
BEGIN
    SET NOCOUNT ON;
 
    TRUNCATE TABLE audit.data_quality_log;   -- the log always describes the latest run
 
    -- Reference tables
    EXEC clean.usp_clean_regions;
    EXEC clean.usp_clean_plans;
    EXEC clean.usp_clean_plan_price_history;
    EXEC clean.usp_clean_churn_reason_codes;
    EXEC clean.usp_clean_retention_offer_catalog;
 
    -- Customers and churn (needed by later tables)
    EXEC clean.usp_clean_customers;
    EXEC clean.usp_clean_churn_events;
 
    -- Subscription tables
    EXEC clean.usp_clean_subscriptions;
    EXEC clean.usp_clean_discounts;
 
    -- Transaction tables
    EXEC clean.usp_clean_invoices;
    EXEC clean.usp_clean_payments;
    EXEC clean.usp_clean_usage_monthly;
    EXEC clean.usp_clean_support_tickets;
    EXEC clean.usp_clean_network_incidents;
    EXEC clean.usp_clean_retention_offers;
END;
GO

/* ==================================================================
   PART 4: STAR SCHEMA (dimensions and facts)
   ================================================================== */

-- --------------------------------------------------------------
-- 4.1 Helper function: date -> date key (20250501)
-- --------------------------------------------------------------

CREATE OR ALTER FUNCTION dw.fn_date_key (@d DATE)
RETURNS INT
AS
BEGIN
    RETURN YEAR(@d) * 10000 + MONTH(@d) * 100 + DAY(@d);   -- NULL date -> NULL key
END;
GO

-- --------------------------------------------------------------
-- 4.2 Dimension tables
-- --------------------------------------------------------------

--- Dimension Tables - Date Table ------------------------------
DROP TABLE IF EXISTS dw.dim_date;
CREATE TABLE dw.dim_date (
    date_key            INT          NOT NULL PRIMARY KEY,   -- 20250501
    full_date           DATE         NOT NULL,
    day_of_month        INT          NOT NULL,
    month_number        INT          NOT NULL,
    month_name          NVARCHAR(20) NOT NULL,
    month_short         NVARCHAR(3)  NOT NULL,
    month_start_date    DATE         NOT NULL,
    quarter_number      INT          NOT NULL,
    quarter_label       NVARCHAR(2)  NOT NULL,
    year_number         INT          NOT NULL,
    year_month          NVARCHAR(7)  NOT NULL,               -- 2025-05
    fiscal_year         NVARCHAR(9)  NOT NULL,               -- FY2025-26 (April to March)
    is_analysis_window  BIT          NOT NULL
);

--- Dimension Tables - Customer Table ------------------------------ 
DROP TABLE IF EXISTS dw.dim_customer;
CREATE TABLE dw.dim_customer (
    customer_id             NVARCHAR(20)  NOT NULL PRIMARY KEY,
    signup_date             DATE          NOT NULL,
    signup_cohort_month     DATE          NOT NULL,          -- first day of signup month
    service_type            NVARCHAR(20)  NOT NULL,
    region_id               NVARCHAR(10)  NOT NULL,
    acquisition_channel     NVARCHAR(50)  NOT NULL,
    age_band                NVARCHAR(20)  NOT NULL,
    gender                  NVARCHAR(20)  NOT NULL,
    payment_method          NVARCHAR(20)  NOT NULL,
    paperless_billing_flag  BIT           NOT NULL,
    current_plan_id         NVARCHAR(10)  NOT NULL,          -- current plan, or last plan if churned
    account_status          NVARCHAR(20)  NOT NULL,
    churn_date              DATE          NULL,
    churn_type              NVARCHAR(20)  NULL,
    tenure_months           INT           NOT NULL,          -- to churn date, or to extract date
    tenure_band             NVARCHAR(20)  NOT NULL
);

--- Dimension Tables - Plan Table ------------------------------ 
DROP TABLE IF EXISTS dw.dim_plan;
CREATE TABLE dw.dim_plan (
    plan_id             NVARCHAR(10)  NOT NULL PRIMARY KEY,
    plan_name           NVARCHAR(100) NOT NULL,
    service_type        NVARCHAR(20)  NOT NULL,
    plan_category       NVARCHAR(20)  NOT NULL,
    contract_type       NVARCHAR(20)  NOT NULL,
    contract_months     INT           NOT NULL,
    launch_price        DECIMAL(10,2) NOT NULL,
    current_price       DECIMAL(10,2) NOT NULL,
    data_allowance_gb   INT           NOT NULL,
    speed_mbps          INT           NULL,
    is_active           BIT           NOT NULL
);

--- Dimension Tables - Region Table ------------------------------ 
DROP TABLE IF EXISTS dw.dim_region;
CREATE TABLE dw.dim_region (
    region_id       NVARCHAR(10)  NOT NULL PRIMARY KEY,
    region_name     NVARCHAR(100) NOT NULL,
    circle          NVARCHAR(100) NOT NULL,
    zone            NVARCHAR(20)  NOT NULL,
    city_tier       NVARCHAR(20)  NOT NULL
);

--- Dimension Tables - Churn Reason Table ------------------------------ 
DROP TABLE IF EXISTS dw.dim_churn_reason;
CREATE TABLE dw.dim_churn_reason (
    churn_reason_id     NVARCHAR(10)  NOT NULL PRIMARY KEY,
    reason_code         NVARCHAR(10)  NOT NULL,
    reason_description  NVARCHAR(255) NOT NULL,
    reason_category     NVARCHAR(50)  NOT NULL,
    applies_to          NVARCHAR(20)  NOT NULL
);

--- Dimension Tables - Offer Table ------------------------------ 
DROP TABLE IF EXISTS dw.dim_offer;
CREATE TABLE dw.dim_offer (
    offer_id                NVARCHAR(10)  NOT NULL PRIMARY KEY,
    offer_name              NVARCHAR(255) NOT NULL,
    offer_type              NVARCHAR(50)  NOT NULL,
    offer_value             INT           NOT NULL,
    offer_duration_months   INT           NOT NULL
);
GO

-- --------------------------------------------------------------
-- 4.3 Fact tables
-- --------------------------------------------------------------

--- Fact Tables - Billing Table ------------------------------ 
DROP TABLE IF EXISTS dw.fact_billing;
CREATE TABLE dw.fact_billing (
    invoice_id          NVARCHAR(20)  NOT NULL PRIMARY KEY,
    customer_id         NVARCHAR(20)  NOT NULL,
    subscription_id     NVARCHAR(20)  NOT NULL,
    plan_id             NVARCHAR(10)  NOT NULL,
    billing_month       DATE          NOT NULL,
    billing_month_key   INT           NOT NULL,
    invoice_date_key    INT           NOT NULL,
    due_date_key        INT           NOT NULL,
    due_date            DATE          NOT NULL,
    base_amount         DECIMAL(12,2) NOT NULL,
    discount_amount     DECIMAL(12,2) NOT NULL,
    tax_amount          DECIMAL(12,2) NOT NULL,
    total_amount        DECIMAL(12,2) NOT NULL,
    is_credit_note      BIT           NOT NULL,
    amount_paid         DECIMAL(12,2) NOT NULL,
    last_payment_date   DATE          NULL,
    payment_attempts    INT           NOT NULL,
    failed_attempts     INT           NOT NULL,
    payment_outcome     NVARCHAR(20)  NOT NULL,   -- Paid On Time / Paid Late / Unpaid / Credit Note
    days_late           INT           NULL,       -- paid late: days after due date
    is_late_payment     BIT           NOT NULL,   -- paid after due date, or unpaid and overdue
    is_unpaid           BIT           NOT NULL
);
 
--- Fact Tables - Support Tickets Table ------------------------------ 
DROP TABLE IF EXISTS dw.fact_support_ticket;
CREATE TABLE dw.fact_support_ticket (
    ticket_id               NVARCHAR(20)   NOT NULL PRIMARY KEY,
    customer_id             NVARCHAR(20)   NOT NULL,
    created_date_key        INT            NOT NULL,
    resolved_date_key       INT            NULL,
    created_datetime        DATETIME2(0)   NOT NULL,
    resolved_datetime       DATETIME2(0)   NULL,
    ticket_category         NVARCHAR(50)   NOT NULL,
    channel                 NVARCHAR(20)   NOT NULL,
    priority                NVARCHAR(20)   NOT NULL,
    resolution_status       NVARCHAR(20)   NOT NULL,
    is_repeat_complaint     BIT            NOT NULL,
    csat_score              TINYINT        NULL,
    resolution_hours        DECIMAL(10,2)  NULL,
    is_invalid_resolution   BIT            NOT NULL,
    is_resolution_outlier   BIT            NOT NULL,
    complaint_theme         NVARCHAR(50)   NOT NULL,   -- derived from ticket_notes
    ticket_notes            NVARCHAR(1000) NULL
);
 
--- Fact Tables - Churn Events Table ------------------------------ 
DROP TABLE IF EXISTS dw.fact_churn_event;
CREATE TABLE dw.fact_churn_event (
    churn_id                NVARCHAR(20)  NOT NULL PRIMARY KEY,
    customer_id             NVARCHAR(20)  NOT NULL,
    churn_date              DATE          NOT NULL,
    churn_date_key          INT           NOT NULL,
    churn_month_key         INT           NOT NULL,
    churn_type              NVARCHAR(20)  NOT NULL,
    churn_reason_id         NVARCHAR(10)  NOT NULL,
    plan_id                 NVARCHAR(10)  NOT NULL,     -- last plan
    region_id               NVARCHAR(10)  NOT NULL,
    port_out_flag           BIT           NOT NULL,
    competitor_name         NVARCHAR(100) NULL,
    tenure_at_churn_months  INT           NOT NULL,
    last_monthly_revenue    DECIMAL(12,2) NULL          -- last regular invoice amount
);
 
--- Fact Tables - Retention Offer Table ------------------------------ 
DROP TABLE IF EXISTS dw.fact_retention_offer;
CREATE TABLE dw.fact_retention_offer (
    offer_event_id          NVARCHAR(20)  NOT NULL PRIMARY KEY,
    customer_id             NVARCHAR(20)  NOT NULL,
    offer_id                NVARCHAR(10)  NOT NULL,
    plan_id                 NVARCHAR(10)  NULL,         -- customer's plan in the offer month
    offer_date              DATE          NOT NULL,
    offer_date_key          INT           NOT NULL,
    trigger_type            NVARCHAR(50)  NOT NULL,
    offer_cost              DECIMAL(10,2) NOT NULL,
    accepted_flag           BIT           NOT NULL,
    churned_within_90_days  BIT           NOT NULL
);
 
--- Fact Tables - Network Incident Table ------------------------------ 
DROP TABLE IF EXISTS dw.fact_network_incident;
CREATE TABLE dw.fact_network_incident (
    incident_id                 NVARCHAR(20)  NOT NULL PRIMARY KEY,
    region_id                   NVARCHAR(10)  NOT NULL,
    service_type                NVARCHAR(20)  NOT NULL,
    start_date_key              INT           NOT NULL,
    start_datetime              DATETIME2(0)  NOT NULL,
    end_datetime                DATETIME2(0)  NOT NULL,
    incident_type               NVARCHAR(50)  NOT NULL,
    severity                    NVARCHAR(20)  NOT NULL,
    duration_hours              DECIMAL(10,2) NOT NULL,
    customers_affected_estimate INT           NOT NULL,
    is_service_disruption       BIT           NOT NULL  -- 1 = outage or speed degradation (not maintenance)
);
 
--- Fact Tables - Customers Monthly Table ------------------------------ 
DROP TABLE IF EXISTS dw.fact_customer_monthly;
CREATE TABLE dw.fact_customer_monthly (
    customer_id                 NVARCHAR(20)  NOT NULL,
    month_start_date            DATE          NOT NULL,
    month_key                   INT           NOT NULL,
    -- Who and what
    plan_id                     NVARCHAR(10)  NOT NULL,
    subscription_id             NVARCHAR(20)  NOT NULL,
    region_id                   NVARCHAR(10)  NOT NULL,
    service_type                NVARCHAR(20)  NOT NULL,
    plan_category               NVARCHAR(20)  NOT NULL,
    contract_type               NVARCHAR(20)  NOT NULL,
    -- Lifecycle
    tenure_months               INT           NOT NULL,
    is_early_life               BIT           NOT NULL,   -- first 3 months (tenure 0-2)
    is_in_contract              BIT           NOT NULL,
    months_to_contract_end      INT           NULL,
    months_since_contract_end   INT           NULL,
    -- Revenue and pricing
    billed_amount               DECIMAL(12,2) NOT NULL,
    base_amount                 DECIMAL(12,2) NOT NULL,
    discount_amount             DECIMAL(12,2) NOT NULL,
    current_plan_price          DECIMAL(10,2) NOT NULL,
    has_discount                BIT           NOT NULL,
    discount_expired_last_60d   BIT           NOT NULL,
    price_increase_last_3m      BIT           NOT NULL,
    -- Payment
    is_late_payment             BIT           NOT NULL,
    is_unpaid                   BIT           NOT NULL,
    late_payments_last_6m       INT           NULL,       -- previous 6 months, not including this one
    -- Usage
    data_used_gb                DECIMAL(10,2) NOT NULL,
    call_minutes                INT           NULL,
    app_logins                  INT           NOT NULL,
    is_usage_outlier            BIT           NOT NULL,
    usage_change_vs_prior_3m    DECIMAL(12,4) NULL,       -- 0.25 = 25% above previous 3-month average
    logins_change_vs_prior_3m   DECIMAL(12,4) NULL,
    -- Support (cancellation requests counted separately)
    tickets_count               INT           NOT NULL,
    unresolved_tickets_count    INT           NOT NULL,
    csat_responses              INT           NOT NULL,
    csat_score_sum              INT           NOT NULL,
    tickets_last_3m             INT           NULL,       -- this month + 2 previous
    unresolved_tickets_last_3m  INT           NULL,
    avg_csat_last_3m            DECIMAL(5,2)  NULL,
    has_cancellation_request    BIT           NOT NULL,
    -- Service quality (region-level, matched on service type)
    region_outage_hours         DECIMAL(10,2) NOT NULL,
    region_outage_hours_last_2m DECIMAL(10,2) NULL,       -- this month + previous
    -- Retention
    offer_received_flag         BIT           NOT NULL,
    offer_accepted_flag         BIT           NOT NULL,
    -- Outcome
    is_churn_month              BIT           NOT NULL,
    churn_type                  NVARCHAR(20)  NULL,
    CONSTRAINT pk_fact_customer_monthly PRIMARY KEY (customer_id, month_start_date)
);
GO

-- --------------------------------------------------------------
-- 4.4 Build procedures
-- --------------------------------------------------------------

-- ------------------------------------------------------------
-- 4.1 dim_date: one row per day, 2020-01-01 to 2026-12-31
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dw.usp_build_dim_date
AS
BEGIN
    SET NOCOUNT ON;
 
    TRUNCATE TABLE dw.dim_date;
 
    WITH dates AS (
        SELECT CAST('2020-01-01' AS DATE) AS dt
        UNION ALL
        SELECT DATEADD(DAY, 1, dt) FROM dates WHERE dt < '2026-12-31'
    )
    INSERT INTO dw.dim_date (date_key, full_date, day_of_month, month_number, month_name, month_short,
                             month_start_date, quarter_number, quarter_label, year_number, year_month,
                             fiscal_year, is_analysis_window)
    SELECT 
    dw.fn_date_key(dt),
    dt,
    DAY(dt),
    MONTH(dt),
    DATENAME(MONTH, dt),
    LEFT(DATENAME(MONTH, dt), 3),
    DATEFROMPARTS(YEAR(dt), MONTH(dt), 1),
    DATEPART(QUARTER, dt),
    'Q' + CAST(DATEPART(QUARTER, dt) AS NVARCHAR(1)),
    YEAR(dt),
    CAST(YEAR(dt) AS NVARCHAR(4)) + '-' + RIGHT('0' + CAST(MONTH(dt) AS NVARCHAR(2)), 2),
    
    CASE WHEN MONTH(dt) >= 4
                THEN 'FY' + CAST(YEAR(dt) AS NVARCHAR(4)) + '-' + RIGHT(CAST(YEAR(dt) + 1 AS NVARCHAR(4)), 2)
                ELSE 'FY' + CAST(YEAR(dt) - 1 AS NVARCHAR(4)) + '-' + RIGHT(CAST(YEAR(dt) AS NVARCHAR(4)), 2)
    END,
    
    CASE WHEN dt BETWEEN '2024-09-01' AND '2026-08-31' THEN 1 ELSE 0 END
    FROM dates
    OPTION (MAXRECURSION 0);
END;
GO
 
-- ------------------------------------------------------------
-- 4.2 dim_customer: customer profile + churn status + tenure
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dw.usp_build_dim_customer
AS
BEGIN
    SET NOCOUNT ON;
 
    TRUNCATE TABLE dw.dim_customer;
 
    WITH base AS (
        SELECT c.*,
               ch.churn_date,
               ch.churn_type,
               COALESCE(cur.plan_id, ch.last_plan_id) AS current_plan_id,
               DATEDIFF(MONTH, c.signup_date, ISNULL(ch.churn_date, '2026-08-31')) AS tenure_months
        FROM clean.customers AS c
        LEFT JOIN clean.churn_events AS ch
               ON ch.customer_id = c.customer_id
        LEFT JOIN clean.subscriptions AS cur
               ON cur.customer_id = c.customer_id AND cur.is_current = 1
    )
    INSERT INTO dw.dim_customer (customer_id, signup_date, signup_cohort_month, service_type, region_id,
                                 acquisition_channel, age_band, gender, payment_method, paperless_billing_flag,
                                 current_plan_id, account_status, churn_date, churn_type, tenure_months, tenure_band)
    SELECT customer_id,
           signup_date,
           DATEFROMPARTS(YEAR(signup_date), 
           MONTH(signup_date), 1),
           service_type, 
           region_id, 
           acquisition_channel, 
           age_band, 
           gender, 
           payment_method, 
           paperless_billing_flag,
           current_plan_id, 
           account_status, 
           churn_date, 
           churn_type,
           tenure_months,
           
           CASE WHEN tenure_months <= 3  THEN '0-3 Months'
                WHEN tenure_months <= 12 THEN '4-12 Months'
                WHEN tenure_months <= 24 THEN '13-24 Months'
                WHEN tenure_months <= 36 THEN '25-36 Months'
                ELSE '37+ Months'
           END
    FROM base;
END;
GO
 
-- ------------------------------------------------------------
-- 4.3 dim_plan: plan details + current price
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dw.usp_build_dim_plan
AS
BEGIN
    SET NOCOUNT ON;
 
    TRUNCATE TABLE dw.dim_plan;
 
    INSERT INTO dw.dim_plan (plan_id, plan_name, service_type, plan_category, contract_type, contract_months,
                             launch_price, current_price, data_allowance_gb, speed_mbps, is_active)
    SELECT p.plan_id, p.plan_name, p.service_type, p.plan_category, p.contract_type, p.contract_months,
           p.launch_price, h.monthly_price, p.data_allowance_gb, p.speed_mbps, p.is_active
    FROM clean.plans AS p
    JOIN clean.plan_price_history AS h
      ON h.plan_id = p.plan_id AND h.effective_to IS NULL;    -- current price row
END;
GO
 
-- ------------------------------------------------------------
-- 4.4 Small dimensions: region, churn reason, offer (direct copies)
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dw.usp_build_small_dims
AS
BEGIN
    SET NOCOUNT ON;
 
    TRUNCATE TABLE dw.dim_region;
    INSERT INTO dw.dim_region (region_id, region_name, circle, zone, city_tier)
    SELECT region_id, region_name, circle, zone, city_tier FROM clean.regions;
 
    TRUNCATE TABLE dw.dim_churn_reason;
    INSERT INTO dw.dim_churn_reason (churn_reason_id, reason_code, reason_description, reason_category, applies_to)
    SELECT churn_reason_id, reason_code, reason_description, reason_category, applies_to FROM clean.churn_reason_codes;
 
    TRUNCATE TABLE dw.dim_offer;
    INSERT INTO dw.dim_offer (offer_id, offer_name, offer_type, offer_value, offer_duration_months)
    SELECT offer_id, offer_name, offer_type, offer_value, offer_duration_months FROM clean.retention_offer_catalog;
END;
GO
 
-- ------------------------------------------------------------
-- 4.5 fact_billing: invoices + summarized payments
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dw.usp_build_fact_billing
AS
BEGIN
    SET NOCOUNT ON;
 
    TRUNCATE TABLE dw.fact_billing;
 
    WITH pay AS (
        SELECT invoice_id,
               SUM(CASE WHEN payment_status IN ('Success', 'Partial') THEN amount_paid ELSE 0 END) AS amount_paid,
               MAX(CASE WHEN payment_status IN ('Success', 'Partial') THEN payment_date END)      AS last_payment_date,
               COUNT(*)                                                                           AS payment_attempts,
               SUM(CASE WHEN payment_status = 'Failed' THEN 1 ELSE 0 END)                         AS failed_attempts
        FROM clean.payments
        GROUP BY invoice_id
    ),
    inv AS (
        SELECT i.*,
               s.plan_id,
               ISNULL(p.amount_paid, 0)      AS amount_paid,
               p.last_payment_date,
               ISNULL(p.payment_attempts, 0) AS payment_attempts,
               ISNULL(p.failed_attempts, 0)  AS failed_attempts,
               CASE WHEN ISNULL(p.amount_paid, 0) >= i.total_amount - 0.01 THEN 1 ELSE 0 END AS fully_paid
        FROM clean.invoices AS i
        JOIN clean.subscriptions AS s ON s.subscription_id = i.subscription_id
        LEFT JOIN pay AS p            ON p.invoice_id      = i.invoice_id
    )
    INSERT INTO dw.fact_billing (invoice_id, customer_id, subscription_id, plan_id, billing_month, billing_month_key,
                                 invoice_date_key, due_date_key, due_date, base_amount, discount_amount, tax_amount,
                                 total_amount, is_credit_note, amount_paid, last_payment_date, payment_attempts,
                                 failed_attempts, payment_outcome, days_late, is_late_payment, is_unpaid)
    SELECT invoice_id, customer_id, subscription_id, plan_id, billing_month, dw.fn_date_key(billing_month),
           dw.fn_date_key(invoice_date), dw.fn_date_key(due_date), due_date,
           base_amount, discount_amount, tax_amount, total_amount, is_credit_note,
           amount_paid, last_payment_date, payment_attempts, failed_attempts,
           CASE WHEN is_credit_note = 1 THEN 'Credit Note'
                WHEN fully_paid = 1 AND (last_payment_date IS NULL OR last_payment_date <= due_date) THEN 'Paid On Time'
                WHEN fully_paid = 1 THEN 'Paid Late'
                ELSE 'Unpaid'
           END,
           CASE WHEN is_credit_note = 0 AND last_payment_date > due_date
                THEN DATEDIFF(DAY, due_date, last_payment_date) END,
           CASE WHEN is_credit_note = 1 THEN 0
                WHEN last_payment_date > due_date THEN 1
                WHEN fully_paid = 0 AND due_date < '2026-08-31' THEN 1
                ELSE 0
           END,
           CASE WHEN is_credit_note = 0 AND fully_paid = 0 THEN 1 ELSE 0 END
    FROM inv;
END;
GO
 
-- ------------------------------------------------------------
-- 4.6 fact_support_ticket: tickets + complaint theme from notes
--     Theme rules are checked top to bottom; the first match wins.
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dw.usp_build_fact_support_ticket
AS
BEGIN
    SET NOCOUNT ON;
 
    TRUNCATE TABLE dw.fact_support_ticket;
 
    INSERT INTO dw.fact_support_ticket (ticket_id, customer_id, created_date_key, resolved_date_key, created_datetime,
                                        resolved_datetime, ticket_category, channel, priority, resolution_status,
                                        is_repeat_complaint, csat_score, resolution_hours, is_invalid_resolution,
                                        is_resolution_outlier, complaint_theme, ticket_notes)
    SELECT 
    
    ticket_id, 
    customer_id,
    dw.fn_date_key(CAST(created_datetime AS DATE)),
    dw.fn_date_key(CAST(resolved_datetime AS DATE)),
    created_datetime, 
    resolved_datetime, 
    ticket_category, 
    channel, 
    priority, 
    resolution_status,
    is_repeat_complaint, 
    csat_score, 
    resolution_hours, 
    is_invalid_resolution, 
    is_resolution_outlier,
    
    CASE
    WHEN 
               ticket_notes LIKE '%competitor%'     OR 
               ticket_notes LIKE '%other provider%' OR 
               ticket_notes LIKE '%elsewhere%'      OR 
               ticket_notes LIKE '%port out%'       
    THEN 'Competitor Offer'
               
    WHEN 
    ticket_notes LIKE '%bill%'      OR 
    ticket_notes LIKE '%price%'     OR 
    ticket_notes LIKE '%charge%'    OR 
    ticket_notes LIKE '%fee%'       OR 
    ticket_notes LIKE '%discount%'  OR 
    ticket_notes LIKE '%expensive%'       
    THEN 'Billing & Price'
               
    WHEN 
    ticket_notes LIKE '%slow%'      OR 
    ticket_notes LIKE '%speed%'     OR 
    ticket_notes LIKE '%buffer%'    OR 
    ticket_notes LIKE '%mbps%'      OR 
    ticket_notes LIKE '%data not working%'                                   
    THEN 'Slow Speed'
               
    WHEN ticket_notes LIKE '%down%'      OR 
    ticket_notes LIKE '%outage%'         OR 
    ticket_notes LIKE '%signal%'         OR 
    ticket_notes LIKE '%drop%'           OR 
    ticket_notes LIKE '%coverage%'       OR 
    ticket_notes LIKE '%no internet%'    OR 
    ticket_notes LIKE '%disconnecting%'                                      
    THEN 'Network Outage / Drops'

    WHEN 
    ticket_notes LIKE '%not resolved%' OR 
    ticket_notes LIKE '%support%'      
    THEN 'Unresolved / Poor Support'
              
    WHEN ticket_notes LIKE '%moving%'    OR 
    ticket_notes LIKE '%shifting%'        
    THEN 'Relocation'
               
    WHEN 
    ticket_notes LIKE '%router%'    OR 
    ticket_notes LIKE '%modem%'     OR 
    ticket_notes LIKE '%sim %'      OR 
    ticket_notes LIKE '%login%'     OR 
    ticket_notes LIKE '%otp%'       OR 
    ticket_notes LIKE '%password%'  OR 
    ticket_notes LIKE '%not working%'                                        
    THEN 'Technical'
               
    WHEN ticket_notes LIKE '%plan%'      OR 
    ticket_notes LIKE '%upgrade%'        OR 
    ticket_notes LIKE '%data%'                                               
    THEN 'Plan Change'
    
    ELSE 'General Enquiry'
    END,
    
    ticket_notes
    FROM clean.support_tickets;
END;
GO
 
-- ------------------------------------------------------------
-- 4.7 fact_churn_event: churn + tenure + last monthly revenue
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dw.usp_build_fact_churn_event
AS
BEGIN
    SET NOCOUNT ON;
 
    TRUNCATE TABLE dw.fact_churn_event;
 
    WITH last_bill AS 
    (
        SELECT customer_id, total_amount,
               ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY billing_month DESC) AS rn
        FROM clean.invoices
        WHERE is_credit_note = 0
    )
    INSERT INTO dw.fact_churn_event (churn_id, customer_id, churn_date, churn_date_key, churn_month_key, churn_type,
                                     churn_reason_id, plan_id, region_id, port_out_flag, competitor_name,
                                     tenure_at_churn_months, last_monthly_revenue)
    SELECT e.churn_id, e.customer_id, e.churn_date,
           dw.fn_date_key(e.churn_date),
           dw.fn_date_key(DATEFROMPARTS(YEAR(e.churn_date), MONTH(e.churn_date), 1)),
           e.churn_type, e.churn_reason_id, e.last_plan_id, c.region_id, e.port_out_flag, e.competitor_name,
           DATEDIFF(MONTH, c.signup_date, e.churn_date),
           lb.total_amount
    FROM clean.churn_events AS e
    JOIN clean.customers AS c ON c.customer_id = e.customer_id
    LEFT JOIN last_bill AS lb ON lb.customer_id = e.customer_id AND lb.rn = 1;
END;
GO
 
-- ------------------------------------------------------------
-- 4.8 fact_retention_offer: offers + did the customer churn within 90 days?
--     (needs fact_billing to be built first, for the plan in the offer month)
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dw.usp_build_fact_retention_offer
AS
BEGIN
    SET NOCOUNT ON;
 
    TRUNCATE TABLE dw.fact_retention_offer;
 
    INSERT INTO dw.fact_retention_offer (offer_event_id, customer_id, offer_id, plan_id, offer_date, offer_date_key,
                                         trigger_type, offer_cost, accepted_flag, churned_within_90_days)
    SELECT o.offer_event_id, o.customer_id, o.offer_id,
           b.plan_id,
           o.offer_date, dw.fn_date_key(o.offer_date),
           o.trigger_type, o.offer_cost, o.accepted_flag,
           CASE WHEN e.churn_date BETWEEN o.offer_date AND DATEADD(DAY, 90, o.offer_date) THEN 1 ELSE 0 END
    FROM clean.retention_offers AS o
    LEFT JOIN clean.churn_events AS e
           ON e.customer_id = o.customer_id
    LEFT JOIN dw.fact_billing AS b
           ON b.customer_id    = o.customer_id
          AND b.billing_month  = DATEFROMPARTS(YEAR(o.offer_date), MONTH(o.offer_date), 1)
          AND b.is_credit_note = 0;
END;
GO
 
-- ------------------------------------------------------------
-- 4.9 fact_network_incident
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dw.usp_build_fact_network_incident
AS
BEGIN
    SET NOCOUNT ON;
 
    TRUNCATE TABLE dw.fact_network_incident;
 
    INSERT INTO dw.fact_network_incident (incident_id, region_id, service_type, start_date_key, start_datetime,
                                          end_datetime, incident_type, severity, duration_hours,
                                          customers_affected_estimate, is_service_disruption)
    SELECT incident_id, region_id, service_type,
           dw.fn_date_key(CAST(start_datetime AS DATE)),
           start_datetime, end_datetime,
           incident_type, severity, duration_hours, customers_affected_estimate,
           CASE WHEN incident_type <> 'Maintenance' THEN 1 ELSE 0 END
    FROM clean.network_incidents;
END;
GO

-- ------------------------------------------------------------
-- 4.10 fact_customer_monthly (central snapshot)
--   Step 1: skeleton  - one row per customer per active month
--   Step 2: summaries - tickets, incidents, offers, prices per month
--   Step 3: insert    - join everything onto the skeleton
--   Step 4: rolling   - 3-month / 6-month window columns
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dw.usp_build_fact_customer_monthly
AS
BEGIN
    SET NOCOUNT ON;
 
    -- Step 1: skeleton. Active = from signup month to churn month (or end of window).
    DROP TABLE IF EXISTS #months;
    SELECT 
    
    c.customer_id,
    d.full_date AS month_start_date,
    d.date_key  AS month_key,
    c.region_id, 
    c.service_type, 
    c.signup_date, 
    c.churn_date, 
    c.churn_type
    INTO #months
    FROM 
    dw.dim_customer AS c JOIN dw.dim_date AS d
    ON 
    d.day_of_month = 1
    AND d.is_analysis_window = 1
    AND d.full_date >= c.signup_cohort_month
    AND (c.churn_date IS NULL OR d.full_date <= DATEFROMPARTS(YEAR(c.churn_date), MONTH(c.churn_date), 1));
 
    -- Step 2a: tickets per customer per month
    DROP TABLE IF EXISTS #tix;
    
    SELECT 
    customer_id,
    DATEFROMPARTS(YEAR(created_datetime), MONTH(created_datetime), 1) AS month_start_date,
    SUM(
    CASE 
    WHEN ticket_category <> 'Cancellation Request' 
    THEN 1 
    ELSE 0 
    END) AS tickets_count,
    
    SUM(
    CASE 
    WHEN ticket_category <> 'Cancellation Request' AND resolution_status = 'Unresolved' 
    THEN 1 
    ELSE 0 
    END)  AS unresolved_tickets_count,
    
    COUNT(csat_score)                                                           AS csat_responses,
    ISNULL(SUM(CAST(csat_score AS INT)), 0)                                     AS csat_score_sum,
    MAX(CASE WHEN ticket_category = 'Cancellation Request' THEN 1 ELSE 0 END)   AS has_cancellation_request
    INTO #tix
    
    FROM dw.fact_support_ticket
    
    GROUP BY customer_id, DATEFROMPARTS(YEAR(created_datetime), MONTH(created_datetime), 1);
 
    -- Step 2b: disruption hours per region, service type and month
    DROP TABLE IF EXISTS #inc;
    
    SELECT 
    region_id, 
    service_type,
    DATEFROMPARTS(YEAR(start_datetime), 
    MONTH(start_datetime), 1) AS month_start_date,
    SUM(CASE WHEN is_service_disruption = 1 THEN duration_hours ELSE 0 END) AS outage_hours
    INTO #inc

    FROM dw.fact_network_incident

    GROUP BY region_id, service_type, DATEFROMPARTS(YEAR(start_datetime), MONTH(start_datetime), 1);
 
    -- Step 2c: retention offers per customer per month
    DROP TABLE IF EXISTS #off;
   
    SELECT customer_id,
           DATEFROMPARTS(YEAR(offer_date), MONTH(offer_date), 1) AS month_start_date,
           MAX(CAST(accepted_flag AS INT)) AS offer_accepted
    INTO #off

    FROM dw.fact_retention_offer

    GROUP BY customer_id, DATEFROMPARTS(YEAR(offer_date), MONTH(offer_date), 1);
 
    -- Step 2d: plan prices with the previous price (to detect increases)
    DROP TABLE IF EXISTS #price;
    
    SELECT plan_id, monthly_price, effective_from, effective_to,
           LAG(monthly_price) OVER (PARTITION BY plan_id ORDER BY effective_from) AS previous_price
    INTO #price

    FROM clean.plan_price_history;
 
    -- Step 3: insert
    TRUNCATE TABLE dw.fact_customer_monthly;
 
    INSERT INTO 
    dw.fact_customer_monthly (
        customer_id, month_start_date, month_key, plan_id, subscription_id, region_id, service_type,
        plan_category, contract_type, tenure_months, is_early_life, is_in_contract, months_to_contract_end,
        months_since_contract_end, billed_amount, base_amount, discount_amount, current_plan_price, has_discount,
        discount_expired_last_60d, price_increase_last_3m, is_late_payment, is_unpaid, data_used_gb, call_minutes,
        app_logins, is_usage_outlier, tickets_count, unresolved_tickets_count, csat_responses, csat_score_sum,
        has_cancellation_request, region_outage_hours, offer_received_flag, offer_accepted_flag,
        is_churn_month, churn_type)
    
    SELECT
        m.customer_id, 
        m.month_start_date, 
        m.month_key,
        b.plan_id, 
        b.subscription_id, 
        m.region_id,
        m.service_type,
        p.plan_category, 
        p.contract_type,
        -- Lifecycle
        DATEDIFF(MONTH, m.signup_date, m.month_start_date),
       
        CASE WHEN DATEDIFF(MONTH, m.signup_date, m.month_start_date) <= 2 THEN 1 ELSE 0 END,
        CASE WHEN s.contract_end_date >= m.month_start_date THEN 1 ELSE 0 END,
        CASE WHEN s.contract_end_date >= m.month_start_date THEN DATEDIFF(MONTH, m.month_start_date, s.contract_end_date) END,
        CASE WHEN s.contract_end_date <  m.month_start_date THEN DATEDIFF(MONTH, s.contract_end_date, m.month_start_date) END,

        -- Revenue and pricing
        b.total_amount, 
        b.base_amount, b.discount_amount,
        pr.monthly_price,
        CASE WHEN b.discount_amount > 0 THEN 1 ELSE 0 END,
        
        CASE WHEN EXISTS (SELECT 1
                          FROM clean.discounts AS d
                          WHERE d.customer_id = m.customer_id
                            AND d.discount_type <> 'Loyalty'
                            AND d.end_date >= DATEADD(MONTH, -2, m.month_start_date)
                            AND d.end_date <  m.month_start_date)
        THEN 1 ELSE 0 END,
        
        CASE WHEN EXISTS 
        (SELECT 1 FROM #price AS ph
         WHERE ph.plan_id = b.plan_id
         AND ph.previous_price IS NOT NULL
         AND ph.monthly_price > ph.previous_price
         AND ph.effective_from >  DATEADD(MONTH, -3, m.month_start_date)   -- increase in the last 3 months
         AND ph.effective_from <= m.month_start_date
         AND m.signup_date < ph.effective_from)                            -- joined before the increase
         THEN 1 ELSE 0 END,

        -- Payment
        b.is_late_payment, 
        b.is_unpaid,

        -- Usage
        u.data_used_gb, 
        u.call_minutes, 
        u.app_logins, 
        u.is_outlier,

        -- Support
        ISNULL(t.tickets_count, 0), 
        ISNULL(t.unresolved_tickets_count, 0),
        ISNULL(t.csat_responses, 0), ISNULL(t.csat_score_sum, 0),
        ISNULL(t.has_cancellation_request, 0),

        -- Service quality
        ISNULL(i.outage_hours, 0),

        -- Retention
        CASE WHEN o.customer_id IS NOT NULL THEN 1 ELSE 0 END,
        ISNULL(o.offer_accepted, 0),

        -- Outcome
        CASE WHEN m.churn_date IS NOT NULL
              AND DATEFROMPARTS(YEAR(m.churn_date), MONTH(m.churn_date), 1) = m.month_start_date THEN 1 ELSE 0 END,
        CASE WHEN m.churn_date IS NOT NULL
              AND DATEFROMPARTS(YEAR(m.churn_date), MONTH(m.churn_date), 1) = m.month_start_date THEN m.churn_type END

    FROM #months AS m
    JOIN dw.fact_billing AS b                                   -- the month's regular invoice
      ON 
    b.customer_id = m.customer_id AND b.billing_month = m.month_start_date AND b.is_credit_note = 0
    JOIN clean.subscriptions AS s   
    ON 
    s.subscription_id = b.subscription_id

    JOIN dw.dim_plan AS p           
    ON p.plan_id = b.plan_id

    JOIN #price AS pr               
    ON pr.plan_id = b.plan_id
    AND m.month_start_date BETWEEN pr.effective_from AND ISNULL(pr.effective_to, '9999-12-31')

    JOIN clean.usage_monthly AS u   
    ON u.customer_id = m.customer_id AND u.usage_month = m.month_start_date

    LEFT JOIN #tix AS t             
    ON t.customer_id = m.customer_id AND t.month_start_date = m.month_start_date

    LEFT JOIN #inc AS i             
    ON i.region_id = m.region_id   AND i.service_type = m.service_type AND i.month_start_date = m.month_start_date

    LEFT JOIN #off AS o             
    ON o.customer_id = m.customer_id AND o.month_start_date = m.month_start_date;
 
    -- Step 4: rolling window columns (rows are consecutive months per customer)

    WITH r AS (
        SELECT customer_id, month_start_date,
               SUM(tickets_count) OVER (PARTITION BY customer_id ORDER BY month_start_date
                                        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)            AS tickets_3m,
               SUM(unresolved_tickets_count) OVER (PARTITION BY customer_id ORDER BY month_start_date
                                        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)            AS unresolved_3m,
               SUM(csat_score_sum) OVER (PARTITION BY customer_id ORDER BY month_start_date
                                        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)            AS csat_sum_3m,
               SUM(csat_responses) OVER (PARTITION BY customer_id ORDER BY month_start_date
                                        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)            AS csat_n_3m,
               SUM(region_outage_hours) OVER (PARTITION BY customer_id ORDER BY month_start_date
                                        ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)            AS outage_2m,
               SUM(CAST(is_late_payment AS INT)) OVER (PARTITION BY customer_id ORDER BY month_start_date
                                        ROWS BETWEEN 6 PRECEDING AND 1 PRECEDING)            AS late_6m,
               data_used_gb,
               app_logins,
               AVG(data_used_gb) OVER (PARTITION BY customer_id ORDER BY month_start_date
                                        ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING)            AS avg_data_prior_3m,
               AVG(CAST(app_logins AS DECIMAL(10,2))) OVER (PARTITION BY customer_id ORDER BY month_start_date
                                        ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING)            AS avg_logins_prior_3m
        FROM dw.fact_customer_monthly
    )
    UPDATE f
    SET tickets_last_3m             = r.tickets_3m,
        unresolved_tickets_last_3m  = r.unresolved_3m,
        avg_csat_last_3m            = CAST(r.csat_sum_3m AS DECIMAL(10,2)) / NULLIF(r.csat_n_3m, 0),
        region_outage_hours_last_2m = r.outage_2m,
        late_payments_last_6m       = ISNULL(r.late_6m, 0),
        usage_change_vs_prior_3m    = CASE WHEN r.avg_data_prior_3m > 0
                                           THEN r.data_used_gb / r.avg_data_prior_3m - 1 END,
        logins_change_vs_prior_3m   = CASE WHEN r.avg_logins_prior_3m > 0
                                           THEN r.app_logins / r.avg_logins_prior_3m - 1 END
    FROM dw.fact_customer_monthly AS f
    JOIN r ON r.customer_id = f.customer_id AND r.month_start_date = f.month_start_date;
END;
GO

-- --------------------------------------------------------------
-- 4.5 Master build procedure (billing before offers; snapshot last)
-- --------------------------------------------------------------

CREATE OR ALTER PROCEDURE dw.usp_build_all
AS
BEGIN
    SET NOCOUNT ON;
 
    -- Dimensions
    EXEC dw.usp_build_dim_date;
    EXEC dw.usp_build_dim_customer;
    EXEC dw.usp_build_dim_plan;
    EXEC dw.usp_build_small_dims;
 
    -- Transaction facts (billing before offers: offers look up the plan from billing)
    EXEC dw.usp_build_fact_billing;
    EXEC dw.usp_build_fact_support_ticket;
    EXEC dw.usp_build_fact_churn_event;
    EXEC dw.usp_build_fact_retention_offer;
    EXEC dw.usp_build_fact_network_incident;
 
    -- Central snapshot
    EXEC dw.usp_build_fact_customer_monthly;
END;
GO

/* ==================================================================
   PART 5: HELPER VIEWS (risk score and customer priority)
   Used by the reporting views, the validation view and the analysis queries.
   ================================================================== */

-- ------------------------------------------------------------
-- 5.1 dw.vw_customer_month_risk: 12 risk flags, risk score, risk band per customer-month
-- ------------------------------------------------------------
CREATE OR ALTER VIEW dw.vw_customer_month_risk
AS
WITH base AS (
    SELECT f.*,
           c.acquisition_channel,
           c.payment_method,
           c.churn_date AS customer_churn_date,
           LAG(f.usage_change_vs_prior_3m)
               OVER (PARTITION BY f.customer_id ORDER BY f.month_start_date) AS prev_usage_change
    FROM dw.fact_customer_monthly AS f
    JOIN dw.dim_customer AS c ON c.customer_id = f.customer_id
),
flags AS (
    SELECT base.*,
           CASE WHEN contract_type = 'Month-to-Month' THEN 1 ELSE 0 END                         AS flag_month_to_month,
           CASE WHEN months_to_contract_end = 0
                  OR months_since_contract_end BETWEEN 1 AND 2 THEN 1 ELSE 0 END                AS flag_contract_ending,
           CASE WHEN is_early_life = 1 THEN 1 ELSE 0 END                                        AS flag_early_life,
           CASE WHEN is_early_life = 1 AND acquisition_channel = 'Partner Dealer' THEN 1 ELSE 0 END AS flag_partner_early_life,
           CAST(price_increase_last_3m AS INT)                                                  AS flag_price_increase,
           CAST(discount_expired_last_60d AS INT)                                               AS flag_discount_expired,
           CASE WHEN unresolved_tickets_last_3m >= 2 THEN 1 ELSE 0 END                          AS flag_unresolved_2plus,
           CASE WHEN unresolved_tickets_last_3m = 1 THEN 1 ELSE 0 END                           AS flag_unresolved_1,
           CASE WHEN avg_csat_last_3m <= 2 THEN 1 ELSE 0 END                                    AS flag_low_csat,
           CASE WHEN service_type = 'Broadband' AND region_outage_hours_last_2m >= 40 THEN 1 ELSE 0 END AS flag_high_outage,
           -- Usage down 25%+ vs the previous 3-month average:
           --   this month's value -> used by the risk score (predicts next month)
           --   last month's value -> used by same-month driver analysis, because
           --   usage in the churn month itself is only a partial month
           CASE WHEN usage_change_vs_prior_3m <= -0.25 THEN 1 ELSE 0 END                        AS flag_usage_decline,
           CASE WHEN prev_usage_change <= -0.25 THEN 1 ELSE 0 END                               AS flag_usage_decline_prev,
           CASE WHEN late_payments_last_6m >= 2 THEN 1 ELSE 0 END                               AS flag_repeated_late
    FROM base
)
SELECT flags.*,
       s.risk_score,
       CASE WHEN s.risk_score >= 45 THEN 'High'
            WHEN s.risk_score >= 25 THEN 'Medium'
            ELSE 'Low'
       END AS risk_band,
       -- Outcome: did the customer churn in the following month?
       CASE WHEN customer_churn_date >  EOMONTH(month_start_date)
             AND customer_churn_date <= EOMONTH(month_start_date, 1) THEN 1 ELSE 0 END AS churned_next_month,
       -- Only rows where the next month can be observed are usable for testing the score
       CASE WHEN is_churn_month = 0 AND month_start_date < '2026-08-01' THEN 1 ELSE 0 END AS has_next_month_outcome
FROM flags
CROSS APPLY (
    -- Points roughly follow the strength of each driver (see Section 4)
    SELECT 15 * flag_month_to_month
         + 25 * flag_contract_ending
         + 10 * flag_early_life
         + 10 * flag_partner_early_life
         + 15 * flag_price_increase
         + 15 * flag_discount_expired
         + 20 * flag_unresolved_2plus
         +  8 * flag_unresolved_1
         + 10 * flag_low_csat
         + 10 * flag_high_outage
         + 15 * flag_usage_decline
         + 15 * flag_repeated_late AS risk_score
) AS s;
GO
 
-- ------------------------------------------------------------
-- 5.2 dw.vw_active_customer_priority: current customers with value tier, priority and action
-- ------------------------------------------------------------
CREATE OR ALTER VIEW dw.vw_active_customer_priority
AS
WITH latest AS (
    SELECT *
    FROM dw.vw_customer_month_risk
    WHERE month_start_date = (SELECT MAX(month_start_date) FROM dw.fact_customer_monthly)
      AND is_churn_month = 0
),
value AS (
    -- Average bill over the last 6 months = customer value
    SELECT customer_id, AVG(billed_amount) AS avg_bill_6m
    FROM dw.fact_customer_monthly
    WHERE month_start_date >= DATEADD(MONTH, -5, (SELECT MAX(month_start_date) FROM dw.fact_customer_monthly))
    GROUP BY customer_id
),
tiered AS (
    SELECT l.*,
           v.avg_bill_6m,
           CASE NTILE(3) OVER (ORDER BY v.avg_bill_6m DESC)
                WHEN 1 THEN 'High' WHEN 2 THEN 'Medium' ELSE 'Low'
           END AS value_tier
    FROM latest AS l
    JOIN value  AS v ON v.customer_id = l.customer_id
)
SELECT customer_id, region_id, service_type, plan_id, plan_category, contract_type, tenure_months,
       acquisition_channel, payment_method,
       billed_amount AS current_monthly_bill,
       avg_bill_6m,
       value_tier,
       risk_score,
       risk_band,
       -- Human-readable reasons (CONCAT_WS skips the NULLs)
       CONCAT_WS(', ',
           CASE WHEN flag_contract_ending    = 1 THEN 'Contract ending' END,
           CASE WHEN flag_month_to_month     = 1 THEN 'Month-to-month' END,
           CASE WHEN flag_early_life         = 1 THEN 'New customer' END,
           CASE WHEN flag_price_increase     = 1 THEN 'Recent price increase' END,
           CASE WHEN flag_discount_expired   = 1 THEN 'Discount expired' END,
           CASE WHEN flag_unresolved_2plus   = 1 THEN '2+ unresolved tickets' END,
           CASE WHEN flag_unresolved_1       = 1 THEN '1 unresolved ticket' END,
           CASE WHEN flag_low_csat           = 1 THEN 'Low CSAT' END,
           CASE WHEN flag_high_outage        = 1 THEN 'Frequent outages' END,
           CASE WHEN flag_usage_decline      = 1 THEN 'Usage falling' END,
           CASE WHEN flag_repeated_late      = 1 THEN 'Repeated late payments' END
       ) AS risk_reasons,
       CASE WHEN risk_band = 'High'   AND value_tier = 'High'   THEN 1
            WHEN risk_band = 'High'   AND value_tier = 'Medium' THEN 2
            WHEN risk_band = 'Medium' AND value_tier = 'High'   THEN 2
            WHEN risk_band = 'High'   AND value_tier = 'Low'    THEN 3
            WHEN risk_band = 'Medium' AND value_tier = 'Medium' THEN 3
            ELSE 4
       END AS priority_rank,
       CASE WHEN risk_band = 'High'   AND value_tier = 'High'   THEN 'P1: Proactive call + tailored offer'
            WHEN risk_band = 'High'   AND value_tier = 'Medium' THEN 'P2: Targeted retention offer'
            WHEN risk_band = 'Medium' AND value_tier = 'High'   THEN 'P2: Service recovery / loyalty perk'
            WHEN risk_band = 'High'   AND value_tier = 'Low'    THEN 'P3: Low-cost digital nudge, no discount'
            WHEN risk_band = 'Medium' AND value_tier = 'Medium' THEN 'P3: Monitor and nurture'
            ELSE 'P4: Business as usual'
       END AS recommended_action
FROM tiered;
GO

/* ==================================================================
   PART 6: REPORTING VIEWS (the only objects Power BI reads)
   ================================================================== */

-- --------------------------------------------------------------
-- 6.1 Dimension views
-- --------------------------------------------------------------

CREATE OR ALTER VIEW rpt.dim_date
AS
SELECT date_key, full_date, day_of_month, month_number, month_name, month_short,
       month_start_date, quarter_number, quarter_label, year_number, year_month,
       fiscal_year, CAST(is_analysis_window AS INT) AS is_analysis_window
FROM dw.dim_date;
GO
 
-- Customer attributes + current risk band and value tier (for slicing)
CREATE OR ALTER VIEW rpt.dim_customer
AS
SELECT c.customer_id,
       c.signup_date,
       c.signup_cohort_month,
       c.service_type,
       c.region_id,
       c.acquisition_channel,
       c.age_band,
       c.gender,
       c.payment_method,
       CAST(c.paperless_billing_flag AS INT)          AS paperless_billing_flag,
       c.current_plan_id,
       c.account_status,
       c.churn_date,
       ISNULL(c.churn_type, 'Not Churned')            AS churn_type,
       CASE WHEN c.churn_date IS NOT NULL THEN 1 ELSE 0 END AS is_churned,
       c.tenure_months,
       c.tenure_band,
       CASE c.tenure_band WHEN '0-3 Months'   THEN 1 WHEN '4-12 Months'  THEN 2
                          WHEN '13-24 Months' THEN 3 WHEN '25-36 Months' THEN 4
                          ELSE 5 END          AS tenure_band_sort,      -- for "Sort by column" in Power BI
       ISNULL(p.risk_band,  'Churned')                AS current_risk_band,
       CASE ISNULL(p.risk_band, 'Churned') WHEN 'High' THEN 1 WHEN 'Medium' THEN 2
                                           WHEN 'Low'  THEN 3 ELSE 4 END AS current_risk_band_sort,
       ISNULL(p.value_tier, 'Churned')                AS current_value_tier,
       CASE ISNULL(p.value_tier, 'Churned') WHEN 'High' THEN 1 WHEN 'Medium' THEN 2
                                            WHEN 'Low'  THEN 3 ELSE 4 END AS current_value_tier_sort
FROM dw.dim_customer AS c
LEFT JOIN dw.vw_active_customer_priority AS p ON p.customer_id = c.customer_id;
GO
 
CREATE OR ALTER VIEW rpt.dim_plan
AS
SELECT plan_id, plan_name, service_type, plan_category, contract_type, contract_months,
       launch_price, current_price, data_allowance_gb, speed_mbps,
       CAST(is_active AS INT) AS is_active
FROM dw.dim_plan;
GO
 
CREATE OR ALTER VIEW rpt.dim_region
AS
SELECT region_id, region_name, circle, zone, city_tier
FROM dw.dim_region;
GO
 
CREATE OR ALTER VIEW rpt.dim_churn_reason
AS
SELECT churn_reason_id, reason_code, reason_description, reason_category, applies_to
FROM dw.dim_churn_reason;
GO
 
CREATE OR ALTER VIEW rpt.dim_offer
AS
SELECT offer_id, offer_name, offer_type, offer_value, offer_duration_months
FROM dw.dim_offer;
GO

-- --------------------------------------------------------------
-- 6.2 Fact views
-- --------------------------------------------------------------

-- Central fact: one row per customer per active month, with risk score
CREATE OR ALTER VIEW rpt.fact_customer_monthly
AS
SELECT customer_id,
       month_start_date,
       month_key,
       plan_id,
       region_id,
       service_type,
       plan_category,
       contract_type,
       -- Lifecycle
       tenure_months,
       CASE WHEN tenure_months <= 2  THEN '0-2'
            WHEN tenure_months <= 5  THEN '3-5'
            WHEN tenure_months <= 8  THEN '6-8'
            WHEN tenure_months <= 11 THEN '9-11'
            WHEN tenure_months <= 14 THEN '12-14'
            WHEN tenure_months <= 17 THEN '15-17'
            WHEN tenure_months <= 20 THEN '18-20'
            WHEN tenure_months <= 23 THEN '21-23'
            WHEN tenure_months <= 26 THEN '24-26'
            ELSE '27+'
       END                                    AS tenure_band,       -- Page 2 lifecycle chart
       CASE WHEN tenure_months <= 26 THEN tenure_months / 3 + 1
            ELSE 10
       END                                    AS tenure_band_sort,  -- 1..10, for "Sort by column"
       CAST(is_early_life  AS INT)            AS is_early_life,
       CAST(is_in_contract AS INT)            AS is_in_contract,
       months_to_contract_end,
       months_since_contract_end,
       -- Revenue and pricing
       billed_amount,
       base_amount,
       discount_amount,
       current_plan_price,
       CAST(has_discount              AS INT) AS has_discount,
       CAST(discount_expired_last_60d AS INT) AS discount_expired_last_60d,
       CAST(price_increase_last_3m    AS INT) AS price_increase_last_3m,
       -- Payment
       CAST(is_late_payment AS INT)           AS is_late_payment,
       CAST(is_unpaid       AS INT)           AS is_unpaid,
       late_payments_last_6m,
       -- Usage
       data_used_gb,
       call_minutes,
       app_logins,
       CAST(is_usage_outlier AS INT)          AS is_usage_outlier,
       usage_change_vs_prior_3m,
       logins_change_vs_prior_3m,
       -- Support
       tickets_count,
       unresolved_tickets_count,
       csat_responses,
       csat_score_sum,
       unresolved_tickets_last_3m,
       avg_csat_last_3m,
       CAST(has_cancellation_request AS INT)  AS has_cancellation_request,
       -- Service quality
       region_outage_hours,
       region_outage_hours_last_2m,
       -- Retention
       CAST(offer_received_flag AS INT)       AS offer_received_flag,
       CAST(offer_accepted_flag AS INT)       AS offer_accepted_flag,
       -- Outcome
       CAST(is_churn_month AS INT)            AS is_churn_month,
       CASE WHEN churn_type = 'Voluntary'   THEN 1 ELSE 0 END AS is_voluntary_churn,
       CASE WHEN churn_type = 'Involuntary' THEN 1 ELSE 0 END AS is_involuntary_churn,
       churn_type,
       -- Risk score (from dw.vw_customer_month_risk)
       risk_score,
       risk_band,
       CASE risk_band WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 ELSE 3 END AS risk_band_sort,
       churned_next_month,
       has_next_month_outcome,
       flag_contract_ending,
       flag_unresolved_2plus,
       flag_low_csat,
       flag_high_outage,
       flag_usage_decline,
       flag_repeated_late
FROM dw.vw_customer_month_risk;
GO
 
CREATE OR ALTER VIEW rpt.fact_billing
AS
SELECT invoice_id, customer_id, plan_id, billing_month, billing_month_key, invoice_date_key, due_date_key,
       base_amount, discount_amount, tax_amount, total_amount,
       CAST(is_credit_note AS INT)  AS is_credit_note,
       amount_paid, last_payment_date, payment_attempts, failed_attempts,
       payment_outcome, days_late,
       CAST(is_late_payment AS INT) AS is_late_payment,
       CAST(is_unpaid AS INT)       AS is_unpaid
FROM dw.fact_billing;
GO
 
CREATE OR ALTER VIEW rpt.fact_support_ticket
AS
SELECT t.ticket_id, t.customer_id,
       -- Plan the customer was on in the month the ticket was raised;
       -- falls back to the customer's current plan if that month has no snapshot row
       ISNULL(m.plan_id, c.current_plan_id) AS plan_id,
       t.created_date_key, t.resolved_date_key, t.created_datetime, t.resolved_datetime,
       t.ticket_category, t.channel, t.priority, t.resolution_status, t.complaint_theme,
       CAST(t.is_repeat_complaint AS INT)   AS is_repeat_complaint,
       t.csat_score,
       t.resolution_hours,
       CAST(t.is_invalid_resolution AS INT) AS is_invalid_resolution,
       CAST(t.is_resolution_outlier AS INT) AS is_resolution_outlier,
       CASE WHEN t.is_invalid_resolution = 0 AND t.is_resolution_outlier = 0
            THEN t.resolution_hours END     AS resolution_hours_for_avg,
       t.ticket_notes
FROM dw.fact_support_ticket AS t
JOIN dw.dim_customer AS c
       ON c.customer_id = t.customer_id
LEFT JOIN dw.fact_customer_monthly AS m
       ON m.customer_id = t.customer_id
      AND m.month_start_date = DATEFROMPARTS(YEAR(t.created_datetime), MONTH(t.created_datetime), 1);
GO
 
CREATE OR ALTER VIEW rpt.fact_churn_event
AS
SELECT churn_id, customer_id, churn_date, churn_date_key, churn_month_key, churn_type,
       churn_reason_id, plan_id, region_id,
       CAST(port_out_flag AS INT) AS port_out_flag,
       ISNULL(competitor_name, 'Not recorded') AS competitor_name,
       tenure_at_churn_months,
       last_monthly_revenue,
       last_monthly_revenue * 12  AS annualized_revenue_lost
FROM dw.fact_churn_event;
GO
 
CREATE OR ALTER VIEW rpt.fact_retention_offer
AS
SELECT offer_event_id, customer_id, offer_id, plan_id, offer_date, offer_date_key, trigger_type,
       offer_cost,
       CAST(accepted_flag AS INT)          AS accepted_flag,
       CAST(churned_within_90_days AS INT) AS churned_within_90_days,
       -- 1 = the full 90-day outcome window is visible (use for effectiveness KPIs)
       CASE WHEN offer_date <= DATEADD(DAY, -90, '2026-08-31') THEN 1 ELSE 0 END AS has_90d_outcome,
       CASE WHEN accepted_flag = 1 AND churned_within_90_days = 0 THEN 1 ELSE 0 END AS is_saved,
       CASE WHEN accepted_flag = 1 THEN offer_cost ELSE 0 END                         AS offer_spend
FROM dw.fact_retention_offer;
GO
 
CREATE OR ALTER VIEW rpt.fact_network_incident
AS
SELECT incident_id, region_id, service_type, start_date_key, start_datetime, end_datetime,
       incident_type, severity, duration_hours, customers_affected_estimate,
       CAST(is_service_disruption AS INT) AS is_service_disruption
FROM dw.fact_network_incident;
GO

-- --------------------------------------------------------------
-- 6.3 Analysis views (logic kept in SQL, not rebuilt in DAX)
-- --------------------------------------------------------------

-- 3.1 Retention target list: active customers with risk, value and action
-- region_name is included because this view is not related to dim_region in Power BI
-- (that would create an ambiguous filter path), so region slicers on the risk page use this column.
CREATE OR ALTER VIEW rpt.vw_customer_priority
AS
SELECT p.customer_id, p.region_id, r.region_name, p.service_type, p.plan_id, p.plan_category, p.contract_type, p.tenure_months,
       p.acquisition_channel, p.payment_method, p.current_monthly_bill, p.avg_bill_6m,
       p.value_tier,
       CASE p.value_tier WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 ELSE 3 END AS value_tier_sort,
       p.risk_score, p.risk_band,
       CASE p.risk_band  WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 ELSE 3 END AS risk_band_sort,
       p.risk_reasons, p.priority_rank, p.recommended_action
FROM dw.vw_active_customer_priority AS p
JOIN dw.dim_region AS r ON r.region_id = p.region_id;
GO
 
-- 3.2 Churn drivers with lift and chi-square significance (same logic as Step 6, query 4.1)
CREATE OR ALTER VIEW rpt.vw_churn_drivers
AS
WITH d AS (
    SELECT v.driver,
           v.driver_group,
           v.flag,
           CASE WHEN r.is_churn_month = 1 AND r.churn_type = 'Voluntary' THEN 1 ELSE 0 END AS churned
    FROM dw.vw_customer_month_risk AS r
    CROSS APPLY (VALUES
        ('Month-to-month plan',                   'Contract', r.flag_month_to_month),
        ('Contract ending / ended 1-2 months',    'Contract', r.flag_contract_ending),
        ('Early life (first 3 months)',           'Lifecycle', r.flag_early_life),
        ('Partner Dealer customer, early life',   'Lifecycle', r.flag_partner_early_life),
        ('Price increase in last 3 months',       'Pricing',  r.flag_price_increase),
        ('Discount expired in last 60 days',      'Pricing',  r.flag_discount_expired),
        ('2+ unresolved tickets (last 3 months)', 'Support',  r.flag_unresolved_2plus),
        ('1 unresolved ticket (last 3 months)',   'Support',  r.flag_unresolved_1),
        ('Low CSAT (avg 2 or less)',              'Support',  r.flag_low_csat),
        ('Broadband + frequent outages',          'Network',  r.flag_high_outage),
        ('Usage down 25%+ (previous month)',      'Engagement', r.flag_usage_decline_prev)
    ) AS v(driver, driver_group, flag)
    WHERE r.month_start_date >= '2024-12-01'
      AND NOT (r.is_churn_month = 1 AND r.churn_type = 'Involuntary')
),
t AS (
    SELECT driver, driver_group,
           CAST(SUM(CASE WHEN flag = 1 AND churned = 1 THEN 1 ELSE 0 END) AS FLOAT) AS a,
           CAST(SUM(CASE WHEN flag = 1 AND churned = 0 THEN 1 ELSE 0 END) AS FLOAT) AS b,
           CAST(SUM(CASE WHEN flag = 0 AND churned = 1 THEN 1 ELSE 0 END) AS FLOAT) AS c,
           CAST(SUM(CASE WHEN flag = 0 AND churned = 0 THEN 1 ELSE 0 END) AS FLOAT) AS d
    FROM d
    GROUP BY driver, driver_group
),
s AS (
    SELECT driver, driver_group, a, b, c, d,
           a / NULLIF(a + b, 0) AS rate_with,
           c / NULLIF(c + d, 0) AS rate_without,
           (a + b + c + d) * SQUARE(a * d - b * c)
               / NULLIF((a + b) * (c + d) * (a + c) * (b + d), 0) AS chi_square
    FROM t
)
SELECT driver,
       driver_group,
       CAST(a + b AS INT)                                        AS months_with_factor,
       CAST(a AS INT)                                            AS churners_with_factor,
       CAST(100 * rate_with    AS DECIMAL(6,2))                  AS churn_rate_with_pct,
       CAST(100 * rate_without AS DECIMAL(6,2))                  AS churn_rate_without_pct,
       CAST(rate_with / NULLIF(rate_without, 0) AS DECIMAL(6,2)) AS lift,
       CAST(chi_square AS DECIMAL(12,1))                         AS chi_square,
       CASE WHEN chi_square >= 10.83 THEN 'Significant (p < 0.001)'
            WHEN chi_square >= 6.63  THEN 'Significant (p < 0.01)'
            WHEN chi_square >= 3.84  THEN 'Significant (p < 0.05)'
            ELSE 'Not significant'
       END                                                       AS significance
FROM s;
GO
 
-- 3.3 Cohort retention in long format (one row per cohort per month number)
--     Ideal for a Power BI matrix / heatmap: rows = cohort, columns = month_number
CREATE OR ALTER VIEW rpt.vw_cohort_retention
AS
WITH cohort AS (
    SELECT customer_id, signup_cohort_month
    FROM dw.dim_customer
    WHERE signup_cohort_month >= '2024-09-01'
),
sizes AS (
    SELECT signup_cohort_month, COUNT(*) AS cohort_size
    FROM cohort
    GROUP BY signup_cohort_month
),
activity AS (
    SELECT c.signup_cohort_month,
           DATEDIFF(MONTH, c.signup_cohort_month, f.month_start_date) AS month_number,
           SUM(CASE WHEN f.is_churn_month = 0 THEN 1 ELSE 0 END)     AS retained_customers
    FROM cohort AS c
    JOIN dw.fact_customer_monthly AS f ON f.customer_id = c.customer_id
    GROUP BY c.signup_cohort_month, DATEDIFF(MONTH, c.signup_cohort_month, f.month_start_date)
)
SELECT a.signup_cohort_month,
       s.cohort_size,
       a.month_number,
       'M' + CAST(a.month_number AS VARCHAR(3)) AS month_label,   -- column header, e.g. M12 (sort by month_number)
       a.retained_customers,
       CAST(100.0 * a.retained_customers / s.cohort_size AS DECIMAL(5,1)) AS retention_pct
FROM activity AS a
JOIN sizes AS s ON s.signup_cohort_month = a.signup_cohort_month;
GO
 
-- 3.4 Risk score performance by band (backtest) + rates used for what-if analysis
CREATE OR ALTER VIEW rpt.vw_risk_band_performance
AS
SELECT risk_band,
       CASE risk_band WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 ELSE 3 END           AS band_sort,
       COUNT(*)                                                                   AS customer_months,
       SUM(churned_next_month)                                                    AS churners_next_month,
       CAST(1.0 * SUM(churned_next_month) / COUNT(*) AS DECIMAL(8,5))            AS next_month_churn_rate,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1))            AS share_of_customers_pct,
       CAST(100.0 * SUM(churned_next_month) / SUM(SUM(churned_next_month)) OVER () AS DECIMAL(5,1)) AS share_of_churners_pct,
       CAST( (1.0 * SUM(churned_next_month) / COUNT(*))
           / (1.0 * SUM(SUM(churned_next_month)) OVER () / SUM(COUNT(*)) OVER ()) AS DECIMAL(5,2)) AS lift
FROM dw.vw_customer_month_risk
WHERE has_next_month_outcome = 1
  AND month_start_date >= '2024-12-01'
GROUP BY risk_band;
GO

-- 3.5 Risk reason per customer
CREATE OR ALTER VIEW rpt.vw_customer_risk_reasons
AS
SELECT p.customer_id,
       LTRIM(RTRIM(s.value)) AS risk_reason
FROM dw.vw_active_customer_priority AS p
CROSS APPLY STRING_SPLIT(p.risk_reasons, ',') AS s
WHERE LTRIM(RTRIM(s.value)) <> '';
GO

/* ==================================================================
   PART 7: PIPELINE PROCEDURE
   Stage 1 load -> Stage 2 clean -> Stage 3 build -> Stage 4 validate.
   Each stage is logged in audit.pipeline_log; a failure stops the run.
   ================================================================== */

CREATE OR ALTER PROCEDURE audit.usp_run_pipeline
AS
BEGIN
    SET NOCOUNT ON;
 
    DECLARE @run_id      INT = ISNULL((SELECT MAX(run_id) FROM audit.pipeline_log), 0) + 1;
    DECLARE @stage       NVARCHAR(50);
    DECLARE @start       DATETIME2(0);
    DECLARE @last_load   INT;
    DECLARE @details     NVARCHAR(4000);
 
    BEGIN TRY
        /* ---------- Stage 1: Load staging ---------- */
        SET @stage = N'1. Load staging';
        SET @start = SYSDATETIME();
        SET @last_load = ISNULL((SELECT MAX(load_id) FROM audit.load_log), 0);
 
        EXEC stg.usp_load_all_bulkinsert_procedures;
 
        -- The load procedures log their own errors instead of raising them,
        -- so check this run's load log entries and stop if any file failed.
        IF EXISTS (SELECT 1 FROM audit.load_log
                   WHERE load_id > @last_load AND load_status = 'Failed')
        BEGIN
            SELECT @details = N'Failed files: ' + STRING_AGG(table_name, N', ') + N'. See audit.load_log.'
            FROM audit.load_log
            WHERE load_id > @last_load AND load_status = 'Failed';
 
            THROW 50001, @details, 1;
        END;
 
        SELECT @details = CONCAT(N'Files loaded: ', COUNT(*), N'; rows: ', SUM(rows_loaded))
        FROM audit.load_log
        WHERE load_id > @last_load;
 
        INSERT INTO audit.pipeline_log (run_id, stage_name, start_time, end_time, duration_seconds, stage_status, details)
        VALUES (@run_id, @stage, @start, SYSDATETIME(), DATEDIFF(SECOND, @start, SYSDATETIME()), N'Success', @details);
 
 
        /* ---------- Stage 2: Clean data ---------- */
        SET @stage = N'2. Clean data';
        SET @start = SYSDATETIME();
 
        EXEC clean.usp_clean_all_cleaning_procedure;
 
        SELECT @details = CONCAT(N'Data-quality issues logged: ', COUNT(*),
                                 N'; rows affected: ', SUM(rows_affected), N'. See audit.data_quality_log.')
        FROM audit.data_quality_log;
 
        INSERT INTO audit.pipeline_log (run_id, stage_name, start_time, end_time, duration_seconds, stage_status, details)
        VALUES (@run_id, @stage, @start, SYSDATETIME(), DATEDIFF(SECOND, @start, SYSDATETIME()), N'Success', @details);
 
 
        /* ---------- Stage 3: Build star schema ---------- */
        SET @stage = N'3. Build star schema';
        SET @start = SYSDATETIME();
 
        EXEC dw.usp_build_all;
 
        SET @details = CONCAT(N'Customers: ',          (SELECT COUNT(*) FROM dw.dim_customer),
                              N'; snapshot rows: ',    (SELECT COUNT(*) FROM dw.fact_customer_monthly),
                              N'; invoices: ',         (SELECT COUNT(*) FROM dw.fact_billing),
                              N'; churn events: ',     (SELECT COUNT(*) FROM dw.fact_churn_event));
 
        INSERT INTO audit.pipeline_log (run_id, stage_name, start_time, end_time, duration_seconds, stage_status, details)
        VALUES (@run_id, @stage, @start, SYSDATETIME(), DATEDIFF(SECOND, @start, SYSDATETIME()), N'Success', @details);
 
 
        /* ---------- Stage 4: Validate ---------- */
        SET @stage = N'4. Validate';
        SET @start = SYSDATETIME();
 
        -- Each check counts problems; every value must be 0
        DECLARE @empty_tables       INT = (SELECT COUNT(*) FROM (VALUES
                                              ((SELECT COUNT(*) FROM dw.dim_customer)),
                                              ((SELECT COUNT(*) FROM dw.dim_plan)),
                                              ((SELECT COUNT(*) FROM dw.dim_region)),
                                              ((SELECT COUNT(*) FROM dw.dim_date)),
                                              ((SELECT COUNT(*) FROM dw.fact_billing)),
                                              ((SELECT COUNT(*) FROM dw.fact_support_ticket)),
                                              ((SELECT COUNT(*) FROM dw.fact_churn_event)),
                                              ((SELECT COUNT(*) FROM dw.fact_customer_monthly))
                                          ) AS t(row_count)
                                          WHERE row_count = 0);
        DECLARE @snapshot_vs_bills  INT = ABS((SELECT COUNT(*) FROM dw.fact_customer_monthly)
                                            - (SELECT COUNT(*) FROM dw.fact_billing WHERE is_credit_note = 0));
        DECLARE @churn_mismatch     INT = ABS((SELECT SUM(CAST(is_churn_month AS INT)) FROM dw.fact_customer_monthly)
                                            - (SELECT COUNT(*) FROM dw.fact_churn_event));
        DECLARE @orphan_customers   INT = (SELECT COUNT(*) FROM dw.fact_customer_monthly AS f
                                           WHERE NOT EXISTS (SELECT 1 FROM dw.dim_customer AS d
                                                             WHERE d.customer_id = f.customer_id));
 
        SET @details = CONCAT(N'Empty tables: ', @empty_tables,
                              N'; snapshot vs invoices difference: ', @snapshot_vs_bills,
                              N'; churn month mismatch: ', @churn_mismatch,
                              N'; orphan customers: ', @orphan_customers);
 
        IF @empty_tables + @snapshot_vs_bills + @churn_mismatch + @orphan_customers > 0
            THROW 50002, @details, 1;
 
        INSERT INTO audit.pipeline_log (run_id, stage_name, start_time, end_time, duration_seconds, stage_status, details)
        VALUES (@run_id, @stage, @start, SYSDATETIME(), DATEDIFF(SECOND, @start, SYSDATETIME()), N'Success', @details);
 
    END TRY
    BEGIN CATCH
        -- Log the failed stage, then re-raise the error so SSMS shows it
        INSERT INTO audit.pipeline_log (run_id, stage_name, start_time, end_time, duration_seconds, stage_status, details)
        VALUES (@run_id, @stage, @start, SYSDATETIME(), DATEDIFF(SECOND, @start, SYSDATETIME()), N'Failed', ERROR_MESSAGE());
 
        THROW;
    END CATCH;
 
    -- Summary of this run
    SELECT run_id, stage_name, start_time, end_time, duration_seconds, stage_status, details
    FROM audit.pipeline_log
    WHERE run_id = @run_id
    ORDER BY log_id;
END;
GO

/* ==================================================================
   PART 8: DASHBOARD VALIDATION VIEW
   SELECT * FROM rpt.vw_dashboard_validation ORDER BY kpi_id;
   Copy the sql_value column into the validation sheet (column H).
   ================================================================== */

-- ------------------------------------------------------------
-- 8.1 rpt.vw_dashboard_validation
--     One row per dashboard KPI, in the same order as the
--     validation sheet (kpi_id). Values are in Power BI units:
--     rates are fractions (0.0211 = 2.11%), money is in rupees.
--     Runs the heavy risk views several times: allow ~30-60 seconds.
-- ------------------------------------------------------------
CREATE OR ALTER VIEW rpt.vw_dashboard_validation
AS
WITH
-- Customer-month snapshot (all periods)
cm AS (
    SELECT COUNT(*)                                                         AS customer_months,
           SUM(CAST(is_churn_month AS INT))                                 AS churned,
           SUM(CASE WHEN churn_type = 'Involuntary' THEN 1 ELSE 0 END)      AS involuntary,
           SUM(CASE WHEN is_churn_month = 1 THEN billed_amount ELSE 0 END)  AS revenue_lost,
           SUM(CASE WHEN is_early_life = 1 THEN 1 ELSE 0 END)               AS early_months,
           SUM(CASE WHEN is_early_life = 1 AND is_churn_month = 1 THEN 1 ELSE 0 END) AS early_churned,
           SUM(CASE WHEN contract_type = 'Month-to-Month' THEN 1 ELSE 0 END) AS m2m_months,
           SUM(CASE WHEN contract_type = 'Month-to-Month' AND is_churn_month = 1 THEN 1 ELSE 0 END) AS m2m_churned,
           MAX(month_start_date)                                            AS latest_month
    FROM dw.fact_customer_monthly
),
-- Latest month only
lm AS (
    SELECT COUNT(*)                          AS active_customers,
           SUM(CAST(f.is_churn_month AS INT)) AS churned,
           AVG(f.billed_amount)              AS arpu
    FROM dw.fact_customer_monthly AS f
    JOIN cm ON f.month_start_date = cm.latest_month
),
-- Net revenue retention for the latest month
nrr AS (
    SELECT SUM(cur.billed_amount) AS revenue_from_existing,
           (SELECT SUM(billed_amount) FROM dw.fact_customer_monthly
            WHERE month_start_date = DATEADD(MONTH, -1, (SELECT latest_month FROM cm))) AS prior_revenue
    FROM dw.fact_customer_monthly AS cur
    JOIN cm ON cur.month_start_date = cm.latest_month
    WHERE EXISTS (SELECT 1 FROM dw.fact_customer_monthly AS prev
                  WHERE prev.customer_id = cur.customer_id
                    AND prev.month_start_date = DATEADD(MONTH, -1, cm.latest_month))
),
-- Partner Dealer channel: early-life churn (Page 2 channel chart)
pd AS (
    SELECT SUM(CASE WHEN f.is_early_life = 1 THEN 1 ELSE 0 END)                         AS early_months,
           SUM(CASE WHEN f.is_early_life = 1 AND f.is_churn_month = 1 THEN 1 ELSE 0 END) AS early_churned
    FROM dw.fact_customer_monthly AS f
    JOIN dw.dim_customer AS c ON c.customer_id = f.customer_id
    WHERE c.acquisition_channel = 'Partner Dealer'
),
-- Cash-Counter payment method: involuntary churn (Page 3 non-payment chart)
cc AS (
    SELECT COUNT(*)                                                    AS months,
           SUM(CASE WHEN f.churn_type = 'Involuntary' THEN 1 ELSE 0 END) AS involuntary
    FROM dw.fact_customer_monthly AS f
    JOIN dw.dim_customer AS c ON c.customer_id = f.customer_id
    WHERE c.payment_method = 'Cash-Counter'
),
-- Support tickets (cancellation requests excluded, as in the DAX measures)
tk AS (
    SELECT COUNT(*)                                                         AS tickets,
           SUM(CASE WHEN resolution_status = 'Unresolved' THEN 1 ELSE 0 END) AS unresolved,
           AVG(CAST(csat_score AS FLOAT))                                   AS avg_csat
    FROM dw.fact_support_ticket
    WHERE ticket_category <> 'Cancellation Request'
),
res AS (
    SELECT AVG(CAST(resolution_hours AS FLOAT)) AS avg_resolution_hours
    FROM dw.fact_support_ticket
    WHERE is_invalid_resolution = 0 AND is_resolution_outlier = 0
),
-- Current customers (Page 4)
pr AS (
    SELECT p.risk_band, p.priority_rank, p.current_monthly_bill, b.next_month_churn_rate
    FROM dw.vw_active_customer_priority AS p
    JOIN rpt.vw_risk_band_performance   AS b ON b.risk_band = p.risk_band
),
pr_sum AS (
    SELECT COUNT(*)                                                     AS active_current,
           SUM(CASE WHEN risk_band = 'High' THEN 1 ELSE 0 END)          AS high_risk,
           SUM(CASE WHEN priority_rank = 1 THEN 1 ELSE 0 END)           AS priority_1,
           SUM(CAST(next_month_churn_rate AS FLOAT))                    AS expected_churners,
           SUM(current_monthly_bill * CAST(next_month_churn_rate AS FLOAT)) * 12 AS revenue_at_risk,
           SUM(CASE WHEN priority_rank <= 2
                    THEN 1 - POWER(1 - CAST(next_month_churn_rate AS FLOAT), 12) ELSE 0 END) AS expected_churners_12m,
           AVG(CASE WHEN priority_rank <= 2 THEN current_monthly_bill END) AS avg_bill_p1p2
    FROM pr
),
-- Retention offers (Page 5)
ofr AS (
    SELECT COUNT(*)                                                                          AS offers,
           SUM(CAST(accepted_flag AS INT))                                                   AS accepted,
           SUM(CASE WHEN has_90d = 1 THEN 1 ELSE 0 END)                                      AS offers_90d,
           SUM(CASE WHEN has_90d = 1 AND accepted_flag = 1 AND churned_within_90_days = 0 THEN 1 ELSE 0 END) AS saved,
           SUM(CASE WHEN has_90d = 1 AND accepted_flag = 1 THEN offer_cost ELSE 0 END)       AS spend_90d,
           SUM(CASE WHEN has_90d = 1 AND accepted_flag = 0 THEN 1 ELSE 0 END)                AS declined_90d,
           SUM(CASE WHEN has_90d = 1 AND accepted_flag = 0 AND churned_within_90_days = 1 THEN 1 ELSE 0 END) AS declined_churned
    FROM dw.fact_retention_offer
    CROSS APPLY (SELECT CASE WHEN offer_date <= DATEADD(DAY, -90, '2026-08-31') THEN 1 ELSE 0 END AS has_90d) AS h
),
-- Every KPI as one row
k AS (
    -- Page 1: Overview
    SELECT 1  AS kpi_id, '1 Overview' AS page, 'Active customers (latest month)' AS kpi, 'Active Customers (Latest Month)' AS power_bi_measure, 'Slicers cleared' AS filter_context,
           CAST(lm.active_customers AS FLOAT) AS sql_value FROM lm
    UNION ALL SELECT 2,  '1 Overview', 'Churn rate (latest month)',       'Churn Rate % (Latest Month)', 'Slicers cleared',
           1.0 * lm.churned / NULLIF(lm.active_customers, 0) FROM lm
    UNION ALL SELECT 3,  '1 Overview', 'ARPU (latest month)',             'ARPU (Latest Month)',         'Slicers cleared',
           CAST(lm.arpu AS FLOAT) FROM lm
    UNION ALL SELECT 4,  '1 Overview', 'Net revenue retention (latest month)', 'NRR %',                 'Slicers cleared',
           CAST(nrr.revenue_from_existing AS FLOAT) / NULLIF(nrr.prior_revenue, 0) FROM nrr
    UNION ALL SELECT 5,  '1 Overview', 'Churned customers (all periods)', 'Churned Customers',           'Slicers cleared',
           cm.churned FROM cm
    UNION ALL SELECT 6,  '1 Overview', 'Churn rate (all periods)',        'Churn Rate %',                'Slicers cleared',
           1.0 * cm.churned / NULLIF(cm.customer_months, 0) FROM cm
    UNION ALL SELECT 7,  '1 Overview', 'Annualized revenue lost (all periods)', 'Annualized Revenue Lost', 'Slicers cleared',
           CAST(cm.revenue_lost AS FLOAT) * 12 FROM cm
    -- Page 2: Segments
    UNION ALL SELECT 8,  '2 Segments', 'Churn rate: Month-to-Month contract', 'Churn Rate % (bar: contract type)', 'Contract = Month-to-Month',
           1.0 * cm.m2m_churned / NULLIF(cm.m2m_months, 0) FROM cm
    UNION ALL SELECT 9,  '2 Segments', 'Early-life churn rate: Partner Dealer', 'Early-Life Churn Rate % (bar: channel)', 'Channel = Partner Dealer',
           1.0 * pd.early_churned / NULLIF(pd.early_months, 0) FROM pd
    UNION ALL SELECT 10, '2 Segments', 'Early-life churn rate',           'Early-Life Churn Rate %',     'Slicers cleared',
           1.0 * cm.early_churned / NULLIF(cm.early_months, 0) FROM cm
    UNION ALL SELECT 11, '2 Segments', 'Average tenure at churn (months)', 'Avg Tenure at Churn (Months)', 'Slicers cleared',
           (SELECT AVG(CAST(tenure_at_churn_months AS FLOAT)) FROM dw.fact_churn_event)
    -- Page 3: Drivers
    UNION ALL SELECT 12, '3 Drivers', 'Support tickets',                  'Tickets',                     'Slicers cleared',
           tk.tickets FROM tk
    UNION ALL SELECT 13, '3 Drivers', 'Unresolved ticket rate',           'Unresolved Rate %',           'Slicers cleared',
           1.0 * tk.unresolved / NULLIF(tk.tickets, 0) FROM tk
    UNION ALL SELECT 14, '3 Drivers', 'Average CSAT',                     'Avg CSAT',                    'Slicers cleared',
           tk.avg_csat FROM tk
    UNION ALL SELECT 15, '3 Drivers', 'Average resolution hours',         'Avg Resolution Hours',        'Slicers cleared',
           res.avg_resolution_hours FROM res
    UNION ALL SELECT 16, '3 Drivers', 'Network outage hours',             'Outage Hours',                'Slicers cleared',
           (SELECT CAST(SUM(duration_hours) AS FLOAT) FROM dw.fact_network_incident WHERE is_service_disruption = 1)
    UNION ALL SELECT 17, '3 Drivers', 'Involuntary churn rate: Cash-Counter', 'Involuntary Churn Rate % (non-payment chart)', 'Payment method = Cash-Counter',
           1.0 * cc.involuntary / NULLIF(cc.months, 0) FROM cc
    UNION ALL SELECT 18, '3 Drivers', 'Lift: Contract ending / ended 1-2 months', 'churn_drivers[lift]', 'None (pre-calculated)',
           (SELECT CAST(lift AS FLOAT) FROM rpt.vw_churn_drivers WHERE driver = 'Contract ending / ended 1-2 months')
    UNION ALL SELECT 19, '3 Drivers', 'Lift: Usage down 25%+ (previous month)', 'churn_drivers[lift]', 'None (pre-calculated)',
           (SELECT CAST(lift AS FLOAT) FROM rpt.vw_churn_drivers WHERE driver = 'Usage down 25%+ (previous month)')
    -- Page 4: Risk (current customers; not affected by the period)
    UNION ALL SELECT 20, '4 Risk', 'Active customers (current)',          'Active Customers (Current)',  'Slicers cleared',
           pr_sum.active_current FROM pr_sum
    UNION ALL SELECT 21, '4 Risk', 'High-risk customers',                 'High-Risk Customers',         'Slicers cleared',
           pr_sum.high_risk FROM pr_sum
    UNION ALL SELECT 22, '4 Risk', 'Priority 1 customers',                'Priority 1 Customers',        'Slicers cleared',
           pr_sum.priority_1 FROM pr_sum
    UNION ALL SELECT 23, '4 Risk', 'Expected churners next month',        'Expected Churners Next Month', 'Slicers cleared',
           pr_sum.expected_churners FROM pr_sum
    UNION ALL SELECT 24, '4 Risk', 'Revenue at risk (annualized)',        'Revenue at Risk (Annualized)', 'Slicers cleared',
           CAST(pr_sum.revenue_at_risk AS FLOAT) FROM pr_sum
    UNION ALL SELECT 25, '4 Risk', 'Next-month churn rate: High band',    'Band Next-Month Churn Rate',  'High band (backtest chart)',
           (SELECT CAST(next_month_churn_rate AS FLOAT) FROM rpt.vw_risk_band_performance WHERE risk_band = 'High')
    -- Page 5: Offers
    UNION ALL SELECT 26, '5 Offers', 'Offers made',                       'Offers Made',                 'Slicers cleared',
           ofr.offers FROM ofr
    UNION ALL SELECT 27, '5 Offers', 'Offer acceptance rate',             'Offer Acceptance %',          'Slicers cleared',
           1.0 * ofr.accepted / NULLIF(ofr.offers, 0) FROM ofr
    UNION ALL SELECT 28, '5 Offers', 'Save rate',                         'Save Rate %',                 'Slicers cleared',
           1.0 * ofr.saved / NULLIF(ofr.offers_90d, 0) FROM ofr
    UNION ALL SELECT 29, '5 Offers', 'Cost per saved customer',           'Cost per Saved Customer',     'Slicers cleared',
           CAST(ofr.spend_90d AS FLOAT) / NULLIF(ofr.saved, 0) FROM ofr
    UNION ALL SELECT 30, '5 Offers', 'Churn within 90 days if declined',  'Churn within 90d if Declined %', 'Slicers cleared',
           1.0 * ofr.declined_churned / NULLIF(ofr.declined_90d, 0) FROM ofr
    UNION ALL SELECT 31, '5 Offers', 'Customers saved (what-if at 20%)',  'Customers Saved (What-If)',   'Slider = 20%',
           pr_sum.expected_churners_12m * 0.20 FROM pr_sum
    UNION ALL SELECT 32, '5 Offers', 'Net benefit 12 months (what-if at 20%)', 'Net Benefit 12M',       'Slider = 20%',
           pr_sum.expected_churners_12m * 0.20
             * (CAST(pr_sum.avg_bill_p1p2 AS FLOAT) * 12 - CAST(ofr.spend_90d AS FLOAT) / NULLIF(ofr.saved, 0))
      FROM pr_sum CROSS JOIN ofr
)
SELECT kpi_id, page, kpi, power_bi_measure, filter_context,
       CAST(sql_value AS DECIMAL(18,6)) AS sql_value
FROM k;
GO

/* ==================================================================
   PART 9: RUN THE PIPELINE (loads, cleans and builds everything once)
   ================================================================== */

EXEC audit.usp_run_pipeline;
GO

/* ==================================================================
   PART 10: CHECKS (run after PART 9)
   Each query says what a good result looks like.
   ================================================================== */

-- --------------------------------------------------------------
-- 10.1 Schemas exist -> 5 rows
-- --------------------------------------------------------------

SELECT name AS schema_name
FROM sys.schemas
WHERE name IN (N'stg', N'clean', N'dw', N'rpt', N'audit')
ORDER BY name;
GO

-- --------------------------------------------------------------
-- 10.2 Staging: latest load vs rows in each CSV -> every row OK
-- --------------------------------------------------------------

WITH expected AS (
    SELECT * FROM (VALUES
        ('regions', 12),
        ('plans', 15),
        ('plan_price_history', 35),
        ('churn_reason_codes', 15),
        ('retention_offer_catalog', 6),
        ('customers', 12882),
        ('subscriptions', 17545),
        ('discounts', 7444),
        ('invoices', 202952),
        ('payments', 201236),
        ('usage_monthly', 202702),
        ('support_tickets', 49845),
        ('network_incidents', 1499),
        ('churn_events', 4276),
        ('retention_offers', 2673)
    ) AS e(table_name, expected_rows)
),
latest_load AS (
    SELECT table_name, rows_loaded, load_status, error_message,
           ROW_NUMBER() OVER (PARTITION BY table_name ORDER BY load_id DESC) AS rn
    FROM audit.load_log
)
SELECT e.table_name,
       e.expected_rows,
       l.rows_loaded,
       l.load_status,
       CASE WHEN l.rows_loaded = e.expected_rows THEN 'OK' ELSE 'CHECK' END AS check_result,
       l.error_message
FROM expected AS e
LEFT JOIN latest_load AS l
       ON l.table_name = e.table_name
      AND l.rn = 1
ORDER BY check_result, e.table_name;
GO

-- --------------------------------------------------------------
-- 10.3 Cleaning: data-quality log, stg vs clean counts, re-run profiling checks, kept flags
-- --------------------------------------------------------------

-- 6.1 What was cleaned (the data-quality log)
SELECT table_name, issue, rows_affected, action_taken, logged_at
FROM audit.data_quality_log
ORDER BY dq_id;

-- 6.2 Row counts: staging vs clean  -> every row should show 'OK'
WITH counts AS (
    SELECT 'regions' AS table_name, (SELECT COUNT(*) FROM stg.regions) AS stg_rows, (SELECT COUNT(*) FROM clean.regions) AS clean_rows, 12 AS expected_clean
    UNION ALL SELECT 'plans',                   (SELECT COUNT(*) FROM stg.plans),                   (SELECT COUNT(*) FROM clean.plans),                   15
    UNION ALL SELECT 'plan_price_history',      (SELECT COUNT(*) FROM stg.plan_price_history),      (SELECT COUNT(*) FROM clean.plan_price_history),      35
    UNION ALL SELECT 'churn_reason_codes',      (SELECT COUNT(*) FROM stg.churn_reason_codes),      (SELECT COUNT(*) FROM clean.churn_reason_codes),      16      -- +1 Unknown
    UNION ALL SELECT 'retention_offer_catalog', (SELECT COUNT(*) FROM stg.retention_offer_catalog), (SELECT COUNT(*) FROM clean.retention_offer_catalog), 6
    UNION ALL SELECT 'customers',               (SELECT COUNT(*) FROM stg.customers),               (SELECT COUNT(*) FROM clean.customers),               12732   -- -150 duplicates
    UNION ALL SELECT 'churn_events',            (SELECT COUNT(*) FROM stg.churn_events),            (SELECT COUNT(*) FROM clean.churn_events),            4276
    UNION ALL SELECT 'subscriptions',           (SELECT COUNT(*) FROM stg.subscriptions),           (SELECT COUNT(*) FROM clean.subscriptions),           17545
    UNION ALL SELECT 'discounts',               (SELECT COUNT(*) FROM stg.discounts),               (SELECT COUNT(*) FROM clean.discounts),               7444
    UNION ALL SELECT 'invoices',                (SELECT COUNT(*) FROM stg.invoices),                (SELECT COUNT(*) FROM clean.invoices),                202912  -- -40 after churn
    UNION ALL SELECT 'payments',                (SELECT COUNT(*) FROM stg.payments),                (SELECT COUNT(*) FROM clean.payments),                201236
    UNION ALL SELECT 'usage_monthly',           (SELECT COUNT(*) FROM stg.usage_monthly),           (SELECT COUNT(*) FROM clean.usage_monthly),           202662  -- -40 after churn
    UNION ALL SELECT 'support_tickets',         (SELECT COUNT(*) FROM stg.support_tickets),         (SELECT COUNT(*) FROM clean.support_tickets),         49845
    UNION ALL SELECT 'network_incidents',       (SELECT COUNT(*) FROM stg.network_incidents),       (SELECT COUNT(*) FROM clean.network_incidents),       1499
    UNION ALL SELECT 'retention_offers',        (SELECT COUNT(*) FROM stg.retention_offers),        (SELECT COUNT(*) FROM clean.retention_offers),        2673
)
SELECT table_name, stg_rows, clean_rows, expected_clean,
       stg_rows - clean_rows AS rows_removed,
       CASE WHEN clean_rows = expected_clean THEN 'OK' ELSE 'CHECK' END AS check_result
FROM counts
ORDER BY check_result, table_name;

-- 6.3 Re-run the key profiling checks on the clean tables -> every issue_count should be 0
SELECT 'Region names with spaces or ALL CAPS / lowercase' AS check_name, COUNT(*) AS issue_count
FROM clean.regions
WHERE DATALENGTH(region_name) <> DATALENGTH(TRIM(region_name))
   OR region_name COLLATE Latin1_General_CS_AS = UPPER(region_name)
   OR region_name COLLATE Latin1_General_CS_AS = LOWER(region_name)
UNION ALL
SELECT 'Plan names with double/outer spaces or ALL CAPS / lowercase', COUNT(*)
FROM clean.plans
WHERE DATALENGTH(plan_name) <> DATALENGTH(TRIM(plan_name))
   OR CHARINDEX('  ', plan_name) > 0
   OR plan_name COLLATE Latin1_General_CS_AS = UPPER(plan_name)
   OR plan_name COLLATE Latin1_General_CS_AS = LOWER(plan_name)
UNION ALL
SELECT 'Customers with region not in regions', COUNT(*)
FROM clean.customers AS c
WHERE NOT EXISTS (SELECT 1 FROM clean.regions AS r WHERE r.region_id COLLATE Latin1_General_CS_AS = c.region_id)
UNION ALL
SELECT 'Customers with non-standard gender / channel text', COUNT(*)
FROM clean.customers
WHERE gender COLLATE Latin1_General_CS_AS NOT IN ('Male', 'Female', 'Other')
   OR DATALENGTH(acquisition_channel) <> DATALENGTH(TRIM(acquisition_channel))
UNION ALL
SELECT 'Churn events with no customer', COUNT(*)
FROM clean.churn_events AS e
WHERE NOT EXISTS (SELECT 1 FROM clean.customers AS c WHERE c.customer_id = e.customer_id)
UNION ALL
SELECT 'Churn events with unknown reason code', COUNT(*)
FROM clean.churn_events AS e
WHERE NOT EXISTS (SELECT 1 FROM clean.churn_reason_codes AS r WHERE r.churn_reason_id = e.churn_reason_id)
UNION ALL
SELECT 'Regular invoices after churn date', COUNT(*)
FROM clean.invoices AS i
JOIN clean.churn_events AS e ON e.customer_id = i.customer_id
WHERE i.is_credit_note = 0 AND i.invoice_date > e.churn_date
UNION ALL
SELECT 'Usage after churn month', COUNT(*)
FROM clean.usage_monthly AS u
JOIN clean.churn_events AS e ON e.customer_id = u.customer_id
WHERE u.usage_month > DATEFROMPARTS(YEAR(e.churn_date), MONTH(e.churn_date), 1)
UNION ALL
SELECT 'Tickets resolved before created', COUNT(*)
FROM clean.support_tickets
WHERE resolved_datetime < created_datetime
UNION ALL
SELECT 'Incidents with region not in regions', COUNT(*)
FROM clean.network_incidents AS n
WHERE NOT EXISTS (SELECT 1 FROM clean.regions AS r WHERE r.region_id COLLATE Latin1_General_CS_AS = n.region_id)
UNION ALL
SELECT 'Payments with no invoice', COUNT(*)
FROM clean.payments AS p
WHERE NOT EXISTS (SELECT 1 FROM clean.invoices AS i WHERE i.invoice_id = p.invoice_id);

-- 6.4 Flags kept for analysis (these are expected, not errors)
SELECT 'Credit notes (is_credit_note = 1)' AS flag_name, COUNT(*) AS flagged_rows FROM clean.invoices WHERE is_credit_note = 1
UNION ALL
SELECT 'Usage spikes (is_outlier = 1)', COUNT(*) FROM clean.usage_monthly WHERE is_outlier = 1
UNION ALL
SELECT 'Invalid resolution dates (is_invalid_resolution = 1)', COUNT(*) FROM clean.support_tickets WHERE is_invalid_resolution = 1
UNION ALL
SELECT 'Slow resolutions (is_resolution_outlier = 1)', COUNT(*) FROM clean.support_tickets WHERE is_resolution_outlier = 1;
GO

-- --------------------------------------------------------------
-- 10.4 Star schema: row counts, reconciliation, orphan keys, first look
-- --------------------------------------------------------------

-- 7.1 Row counts -> every row should show 'OK'
WITH counts AS (
    SELECT 'dim_date' AS table_name, (SELECT COUNT(*) FROM dw.dim_date) AS actual_rows, 2557 AS expected_rows   -- 2020-01-01 to 2026-12-31
    UNION ALL SELECT 'dim_customer',          (SELECT COUNT(*) FROM dw.dim_customer),          12732
    UNION ALL SELECT 'dim_plan',              (SELECT COUNT(*) FROM dw.dim_plan),              15
    UNION ALL SELECT 'dim_region',            (SELECT COUNT(*) FROM dw.dim_region),            12
    UNION ALL SELECT 'dim_churn_reason',      (SELECT COUNT(*) FROM dw.dim_churn_reason),      16
    UNION ALL SELECT 'dim_offer',             (SELECT COUNT(*) FROM dw.dim_offer),             6
    UNION ALL SELECT 'fact_billing',          (SELECT COUNT(*) FROM dw.fact_billing),          202912
    UNION ALL SELECT 'fact_support_ticket',   (SELECT COUNT(*) FROM dw.fact_support_ticket),   49845
    UNION ALL SELECT 'fact_churn_event',      (SELECT COUNT(*) FROM dw.fact_churn_event),      4276
    UNION ALL SELECT 'fact_retention_offer',  (SELECT COUNT(*) FROM dw.fact_retention_offer),  2673
    UNION ALL SELECT 'fact_network_incident', (SELECT COUNT(*) FROM dw.fact_network_incident), 1499
    UNION ALL SELECT 'fact_customer_monthly', (SELECT COUNT(*) FROM dw.fact_customer_monthly), 202662
)
SELECT table_name, expected_rows, actual_rows,
       CASE WHEN actual_rows = expected_rows THEN 'OK' ELSE 'CHECK' END AS check_result
FROM counts
ORDER BY check_result, table_name;

-- 7.2 Reconciliation checks -> every difference should be 0
SELECT 'Snapshot rows vs regular invoices' AS check_name,
       CAST((SELECT COUNT(*) FROM dw.fact_customer_monthly)
          - (SELECT COUNT(*) FROM dw.fact_billing WHERE is_credit_note = 0) AS DECIMAL(18,2)) AS difference
UNION ALL
SELECT 'Snapshot rows vs usage rows',
       (SELECT COUNT(*) FROM dw.fact_customer_monthly)
     - (SELECT COUNT(*) FROM clean.usage_monthly)
UNION ALL
SELECT 'Snapshot churn months vs churn events',
       (SELECT SUM(CAST(is_churn_month AS INT)) FROM dw.fact_customer_monthly)
     - (SELECT COUNT(*) FROM dw.fact_churn_event)
UNION ALL
SELECT 'Snapshot revenue vs regular invoice revenue (INR)',
       (SELECT SUM(billed_amount) FROM dw.fact_customer_monthly)
     - (SELECT SUM(total_amount) FROM dw.fact_billing WHERE is_credit_note = 0)
UNION ALL
SELECT 'Churned customers in dim_customer vs churn events',
       (SELECT COUNT(*) FROM dw.dim_customer WHERE churn_date IS NOT NULL)
     - (SELECT COUNT(*) FROM dw.fact_churn_event);
 
-- 7.3 Orphan checks: every fact key must exist in its dimension -> all 0
SELECT 'fact_billing -> dim_customer' AS check_name, COUNT(*) AS orphan_rows
FROM dw.fact_billing AS f WHERE NOT EXISTS (SELECT 1 FROM dw.dim_customer AS d WHERE d.customer_id = f.customer_id)
UNION ALL
SELECT 'fact_billing -> dim_plan', COUNT(*)
FROM dw.fact_billing AS f WHERE NOT EXISTS (SELECT 1 FROM dw.dim_plan AS d WHERE d.plan_id = f.plan_id)
UNION ALL
SELECT 'fact_billing -> dim_date', COUNT(*)
FROM dw.fact_billing AS f WHERE NOT EXISTS (SELECT 1 FROM dw.dim_date AS d WHERE d.date_key = f.invoice_date_key)
UNION ALL
SELECT 'fact_support_ticket -> dim_customer', COUNT(*)
FROM dw.fact_support_ticket AS f WHERE NOT EXISTS (SELECT 1 FROM dw.dim_customer AS d WHERE d.customer_id = f.customer_id)
UNION ALL
SELECT 'fact_churn_event -> dim_churn_reason', COUNT(*)
FROM dw.fact_churn_event AS f WHERE NOT EXISTS (SELECT 1 FROM dw.dim_churn_reason AS d WHERE d.churn_reason_id = f.churn_reason_id)
UNION ALL
SELECT 'fact_churn_event -> dim_region', COUNT(*)
FROM dw.fact_churn_event AS f WHERE NOT EXISTS (SELECT 1 FROM dw.dim_region AS d WHERE d.region_id = f.region_id)
UNION ALL
SELECT 'fact_retention_offer -> dim_offer', COUNT(*)
FROM dw.fact_retention_offer AS f WHERE NOT EXISTS (SELECT 1 FROM dw.dim_offer AS d WHERE d.offer_id = f.offer_id)
UNION ALL
SELECT 'fact_network_incident -> dim_region', COUNT(*)
FROM dw.fact_network_incident AS f WHERE NOT EXISTS (SELECT 1 FROM dw.dim_region AS d WHERE d.region_id = f.region_id)
UNION ALL
SELECT 'fact_customer_monthly -> dim_customer', COUNT(*)
FROM dw.fact_customer_monthly AS f WHERE NOT EXISTS (SELECT 1 FROM dw.dim_customer AS d WHERE d.customer_id = f.customer_id)
UNION ALL
SELECT 'fact_customer_monthly -> dim_date', COUNT(*)
FROM dw.fact_customer_monthly AS f WHERE NOT EXISTS (SELECT 1 FROM dw.dim_date AS d WHERE d.date_key = f.month_key);
 
-- 7.4 First look: monthly churn rate from the snapshot
--     Expect roughly 1.6% at the start rising to about 2.4% at the end
SELECT month_start_date,
       COUNT(*)                                                                  AS active_customers,
       SUM(CAST(is_churn_month AS INT))                                          AS churned,
       CAST(100.0 * SUM(CAST(is_churn_month AS INT)) / COUNT(*) AS DECIMAL(5,2)) AS churn_rate_pct
FROM dw.fact_customer_monthly
GROUP BY month_start_date
ORDER BY month_start_date;
 
-- 7.5 Complaint themes -> review: 'General Enquiry' should be a small share
SELECT complaint_theme, COUNT(*) AS tickets
FROM dw.fact_support_ticket
GROUP BY complaint_theme
ORDER BY tickets DESC;
 
-- 7.6 Sample rows from the snapshot
SELECT TOP (20) *
FROM dw.fact_customer_monthly
ORDER BY customer_id, month_start_date;
GO

-- --------------------------------------------------------------
-- 10.5 Risk reasons view: counts per reason, and no duplicates (0 rows)
-- --------------------------------------------------------------

-- Check 1: reasons and how many customers have each
SELECT risk_reason, COUNT(*) AS customers
FROM rpt.vw_customer_risk_reasons
GROUP BY risk_reason
ORDER BY customers DESC;

-- Check 2: no customer has the same reason twice (should return 0 rows)
SELECT customer_id, risk_reason, COUNT(*) AS n
FROM rpt.vw_customer_risk_reasons
GROUP BY customer_id, risk_reason
HAVING COUNT(*) > 1;
GO

-- --------------------------------------------------------------
-- 10.6 Pipeline history and the latest run
-- --------------------------------------------------------------

-- 4.1 History of all pipeline runs, one row per run
SELECT run_id,
       MIN(start_time)                                        AS run_started,
       MAX(end_time)                                          AS run_finished,
       SUM(duration_seconds)                                  AS total_seconds,
       CASE WHEN SUM(CASE WHEN stage_status = 'Failed' THEN 1 ELSE 0 END) > 0
            THEN 'Failed' ELSE 'Success' END                  AS run_status,
       COUNT(*)                                               AS stages_logged
FROM audit.pipeline_log
GROUP BY run_id
ORDER BY run_id DESC;
 
-- 4.2 Stage details of the latest run (see what failed and why)
SELECT stage_name, start_time, duration_seconds, stage_status, details
FROM audit.pipeline_log
WHERE run_id = (SELECT MAX(run_id) FROM audit.pipeline_log)
ORDER BY log_id;
GO

-- --------------------------------------------------------------
-- 10.7 Dashboard validation: paste sql_value into the validation sheet
-- --------------------------------------------------------------

SELECT kpi_id, page, kpi, power_bi_measure, filter_context, sql_value
FROM rpt.vw_dashboard_validation
ORDER BY kpi_id;
GO

/* ==================================================================
   PART 11: ANALYSIS - business questions (reference)
   Select one query and press F5 to run it on its own.
   These are the benchmarks the Power BI visuals were checked against.
   ================================================================== */

/* ============================================================
   SECTION 1: KPI BASELINE - how big is the problem?
   ============================================================ */
 
-- 1.1 Monthly KPIs: churn rate, revenue churn, ARPU
SELECT month_start_date,
       active_customers,
       new_customers,
       churned,
       CAST(100.0 * churned     / active_customers AS DECIMAL(5,2)) AS churn_rate_pct,
       CAST(100.0 * voluntary   / active_customers AS DECIMAL(5,2)) AS voluntary_churn_pct,
       CAST(100.0 * involuntary / active_customers AS DECIMAL(5,2)) AS involuntary_churn_pct,
       CAST(100.0 - 100.0 * churned / active_customers AS DECIMAL(5,2)) AS retention_rate_pct,
       CAST(mrr / active_customers AS DECIMAL(10,2))                AS arpu,
       mrr                                                          AS monthly_revenue,
       mrr_lost                                                     AS monthly_revenue_lost_to_churn,
       CAST(100.0 * mrr_lost / mrr AS DECIMAL(5,2))                 AS revenue_churn_pct,
       CAST(100.0 * churned / active_customers
            - LAG(100.0 * churned / active_customers) OVER (ORDER BY month_start_date)
            AS DECIMAL(5,2))                                        AS churn_rate_change_vs_prev_month
FROM (
    SELECT month_start_date,
           COUNT(*)                                                     AS active_customers,
           SUM(CASE WHEN tenure_months = 0 THEN 1 ELSE 0 END)           AS new_customers,
           SUM(CAST(is_churn_month AS INT))                             AS churned,
           SUM(CASE WHEN churn_type = 'Voluntary'   THEN 1 ELSE 0 END)  AS voluntary,
           SUM(CASE WHEN churn_type = 'Involuntary' THEN 1 ELSE 0 END)  AS involuntary,
           SUM(billed_amount)                                           AS mrr,
           SUM(CASE WHEN is_churn_month = 1 THEN billed_amount ELSE 0 END) AS mrr_lost
    FROM dw.fact_customer_monthly
    GROUP BY month_start_date
) AS m
ORDER BY month_start_date;

 
-- 1.2 First 6 months vs last 6 months: has churn got worse?
--     annualized_revenue_lost = churned customers' monthly bills x 12
SELECT p.period,
       COUNT(*)                                                               AS customer_months,
       SUM(CAST(f.is_churn_month AS INT))                                     AS churned_customers,
       CAST(100.0 * SUM(CAST(f.is_churn_month AS INT)) / COUNT(*) AS DECIMAL(5,2)) AS avg_monthly_churn_pct,
       CAST(100.0 * SUM(CASE WHEN f.churn_type = 'Voluntary' THEN 1 ELSE 0 END)
            / NULLIF(SUM(CAST(f.is_churn_month AS INT)), 0) AS DECIMAL(5,1))  AS voluntary_share_pct,
       CAST(AVG(f.billed_amount) AS DECIMAL(10,2))                            AS arpu,
       SUM(CASE WHEN f.is_churn_month = 1 THEN f.billed_amount ELSE 0 END) * 12 AS annualized_revenue_lost
FROM dw.fact_customer_monthly AS f
CROSS APPLY (
    SELECT CASE WHEN f.month_start_date <  '2025-03-01' THEN '1) First 6 months (Sep 2024 - Feb 2025)'
                WHEN f.month_start_date >= '2026-03-01' THEN '2) Last 6 months (Mar 2026 - Aug 2026)'
           END AS period
) AS p
WHERE p.period IS NOT NULL
GROUP BY p.period
ORDER BY p.period;
 
-- 1.3 Net revenue retention (NRR)
--     Revenue this month from customers who were already billed last month
--     / total revenue last month. Below 100% = churn outweighs upgrades/price rises.
WITH monthly_total AS (
    SELECT month_start_date, SUM(billed_amount) AS revenue
    FROM dw.fact_customer_monthly
    GROUP BY month_start_date
)
SELECT cur.month_start_date,
       SUM(cur.billed_amount)                                   AS revenue_from_existing_customers,
       t.revenue                                                AS prior_month_revenue,
       CAST(100.0 * SUM(cur.billed_amount) / t.revenue AS DECIMAL(6,2)) AS nrr_pct
FROM dw.fact_customer_monthly AS cur
JOIN dw.fact_customer_monthly AS prev
  ON prev.customer_id      = cur.customer_id
 AND prev.month_start_date = DATEADD(MONTH, -1, cur.month_start_date)
JOIN monthly_total AS t
  ON t.month_start_date    = DATEADD(MONTH, -1, cur.month_start_date)
GROUP BY cur.month_start_date, t.revenue
ORDER BY cur.month_start_date;

/* ============================================================
   SECTION 2: SEGMENTATION & LIFECYCLE - who churns, and when?
   ============================================================ */
 
-- 2.1 Churn rate by segment, all dimensions in one result
--     lift = segment churn rate / overall churn rate (1.5 = 50% higher than average)
SELECT s.dimension,
       s.segment,
       COUNT(*)                                                                    AS customer_months,
       SUM(CAST(f.is_churn_month AS INT))                                          AS churned,
       CAST(100.0 * SUM(CAST(f.is_churn_month AS INT)) / COUNT(*) AS DECIMAL(5,2)) AS churn_rate_pct,
       CAST(100.0 * SUM(CASE WHEN f.churn_type = 'Voluntary' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2))   AS voluntary_pct,
       CAST(100.0 * SUM(CASE WHEN f.churn_type = 'Involuntary' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS involuntary_pct,
       CAST( (1.0 * SUM(CAST(f.is_churn_month AS INT)) / COUNT(*))
           / (1.0 * SUM(SUM(CAST(f.is_churn_month AS INT))) OVER (PARTITION BY s.dimension)
                  / SUM(COUNT(*)) OVER (PARTITION BY s.dimension)) AS DECIMAL(5,2)) AS lift_vs_overall,
       SUM(CASE WHEN f.is_churn_month = 1 THEN f.billed_amount ELSE 0 END)         AS monthly_revenue_lost
FROM dw.fact_customer_monthly AS f
JOIN dw.dim_customer AS c ON c.customer_id = f.customer_id
JOIN dw.dim_region   AS r ON r.region_id   = f.region_id
CROSS APPLY (VALUES
    (N'1. Contract type',       f.contract_type),
    (N'2. Plan category',       f.plan_category),
    (N'3. Service type',        f.service_type),
    (N'4. Region',              r.region_name),
    (N'5. City tier',           r.city_tier),
    (N'6. Acquisition channel', c.acquisition_channel),
    (N'7. Payment method',      c.payment_method),
    (N'8. Age band',            c.age_band),
    (N'9. Tenure at the month', CASE WHEN f.tenure_months <= 2  THEN N'a) 0-2 months'
                                     WHEN f.tenure_months <= 11 THEN N'b) 3-11 months'
                                     WHEN f.tenure_months <= 23 THEN N'c) 12-23 months'
                                     WHEN f.tenure_months <= 35 THEN N'd) 24-35 months'
                                     ELSE N'e) 36+ months' END)
) AS s(dimension, segment)
GROUP BY s.dimension, s.segment
ORDER BY s.dimension, churn_rate_pct DESC;
 
-- 2.2 Contract lifecycle: when does churn spike?
SELECT cs.contract_status,
       COUNT(*)                                                                    AS customer_months,
       SUM(CAST(f.is_churn_month AS INT))                                          AS churned,
       CAST(100.0 * SUM(CAST(f.is_churn_month AS INT)) / COUNT(*) AS DECIMAL(5,2)) AS churn_rate_pct
FROM dw.fact_customer_monthly AS f
CROSS APPLY (
    SELECT CASE WHEN f.contract_type = 'Month-to-Month'        THEN '1) Month-to-month (no contract)'
                WHEN f.months_to_contract_end = 0              THEN '2) Contract ends this month'
                WHEN f.is_in_contract = 1                      THEN '3) In contract'
                WHEN f.months_since_contract_end BETWEEN 1 AND 2 THEN '4) Contract ended 1-2 months ago'
                ELSE                                                '5) Out of contract 3+ months'
           END AS contract_status
) AS cs
GROUP BY cs.contract_status
ORDER BY cs.contract_status;
 
-- 2.3 Early-life churn by acquisition channel
--     Is churn in the first 3 months concentrated in one channel?
SELECT c.acquisition_channel,
       SUM(CASE WHEN f.is_early_life = 1 THEN 1 ELSE 0 END) AS early_life_months,
       CAST(100.0 * SUM(CASE WHEN f.is_early_life = 1 AND f.is_churn_month = 1 THEN 1 ELSE 0 END)
            / NULLIF(SUM(CASE WHEN f.is_early_life = 1 THEN 1 ELSE 0 END), 0) AS DECIMAL(5,2)) AS early_life_churn_pct,
       CAST(100.0 * SUM(CASE WHEN f.is_early_life = 0 AND f.is_churn_month = 1 THEN 1 ELSE 0 END)
            / NULLIF(SUM(CASE WHEN f.is_early_life = 0 THEN 1 ELSE 0 END), 0) AS DECIMAL(5,2)) AS later_churn_pct
FROM dw.fact_customer_monthly AS f
JOIN dw.dim_customer AS c ON c.customer_id = f.customer_id
GROUP BY c.acquisition_channel
ORDER BY early_life_churn_pct DESC;

/* ============================================================
   SECTION 3: COHORT RETENTION - are newer customers retained better?
   Cohort = customers who signed up in the same month (within the window).
   Retained at month N = still active at the end of their Nth month.
   ============================================================ */
 
-- 3.1 Retention % by signup cohort (blank = cohort not old enough yet)
WITH cohort AS (
    SELECT customer_id, signup_cohort_month
    FROM dw.dim_customer
    WHERE signup_cohort_month >= '2024-09-01'
),
sizes AS (
    SELECT signup_cohort_month, COUNT(*) AS cohort_size
    FROM cohort
    GROUP BY signup_cohort_month
),
activity AS (
    SELECT c.signup_cohort_month,
           DATEDIFF(MONTH, c.signup_cohort_month, f.month_start_date) AS month_number,
           SUM(CASE WHEN f.is_churn_month = 0 THEN 1 ELSE 0 END)     AS retained
    FROM cohort AS c
    JOIN dw.fact_customer_monthly AS f ON f.customer_id = c.customer_id
    GROUP BY c.signup_cohort_month, DATEDIFF(MONTH, c.signup_cohort_month, f.month_start_date)
)
SELECT s.signup_cohort_month,
       s.cohort_size,
       CAST(MAX(CASE WHEN a.month_number = 1  THEN 100.0 * a.retained / s.cohort_size END) AS DECIMAL(5,1)) AS m1_pct,
       CAST(MAX(CASE WHEN a.month_number = 3  THEN 100.0 * a.retained / s.cohort_size END) AS DECIMAL(5,1)) AS m3_pct,
       CAST(MAX(CASE WHEN a.month_number = 6  THEN 100.0 * a.retained / s.cohort_size END) AS DECIMAL(5,1)) AS m6_pct,
       CAST(MAX(CASE WHEN a.month_number = 12 THEN 100.0 * a.retained / s.cohort_size END) AS DECIMAL(5,1)) AS m12_pct,
       CAST(MAX(CASE WHEN a.month_number = 18 THEN 100.0 * a.retained / s.cohort_size END) AS DECIMAL(5,1)) AS m18_pct
FROM sizes AS s
JOIN activity AS a ON a.signup_cohort_month = s.signup_cohort_month
GROUP BY s.signup_cohort_month, s.cohort_size
ORDER BY s.signup_cohort_month;
 
-- 3.2 Average retention curve across all cohorts
--     (each month number uses only the cohorts that have reached it)
WITH cohort AS (
    SELECT customer_id, signup_cohort_month
    FROM dw.dim_customer
    WHERE signup_cohort_month >= '2024-09-01'
),
sizes AS (
    SELECT signup_cohort_month, COUNT(*) AS cohort_size
    FROM cohort
    GROUP BY signup_cohort_month
),
activity AS (
    SELECT c.signup_cohort_month,
           DATEDIFF(MONTH, c.signup_cohort_month, f.month_start_date) AS month_number,
           SUM(CASE WHEN f.is_churn_month = 0 THEN 1 ELSE 0 END)     AS retained
    FROM cohort AS c
    JOIN dw.fact_customer_monthly AS f ON f.customer_id = c.customer_id
    GROUP BY c.signup_cohort_month, DATEDIFF(MONTH, c.signup_cohort_month, f.month_start_date)
)
SELECT a.month_number,
       COUNT(*)                                                       AS cohorts_included,
       CAST(100.0 * SUM(a.retained) / SUM(s.cohort_size) AS DECIMAL(5,1)) AS avg_retention_pct
FROM activity AS a
JOIN sizes AS s ON s.signup_cohort_month = a.signup_cohort_month
GROUP BY a.month_number
ORDER BY a.month_number;

/* ============================================================
   SECTION 4: CHURN DRIVERS - why do customers churn?
 
   Method: for each factor, compare the voluntary churn rate of
   customer-months WITH the factor against those WITHOUT it.
   A chi-square test (2x2 table) tells us whether the difference
   is statistically significant or could be random noise.
 
   Chi-square critical values (1 degree of freedom):
     3.84 -> p < 0.05    6.63 -> p < 0.01    10.83 -> p < 0.001
 
   Cancellation-request tickets are NOT used as a driver:
   they are a symptom of churn, not a cause (data leakage).
   ============================================================ */
 
-- 4.1 Voluntary churn drivers with significance test
WITH d AS (
    SELECT v.driver,
           v.flag,
           CASE WHEN r.is_churn_month = 1 AND r.churn_type = 'Voluntary' THEN 1 ELSE 0 END AS churned
    FROM dw.vw_customer_month_risk AS r
    CROSS APPLY (VALUES
        ('Month-to-month plan',                  r.flag_month_to_month),
        ('Contract ending / ended 1-2 months',   r.flag_contract_ending),
        ('Early life (first 3 months)',          r.flag_early_life),
        ('Partner Dealer customer, early life',  r.flag_partner_early_life),
        ('Price increase in last 3 months',      r.flag_price_increase),
        ('Discount expired in last 60 days',     r.flag_discount_expired),
        ('2+ unresolved tickets (last 3 months)',r.flag_unresolved_2plus),
        ('1 unresolved ticket (last 3 months)',  r.flag_unresolved_1),
        ('Low CSAT (avg 2 or less)',             r.flag_low_csat),
        ('Broadband + frequent outages',         r.flag_high_outage),
        ('Usage down 25%+ (previous month)',     r.flag_usage_decline_prev)
    ) AS v(driver, flag)
    WHERE r.month_start_date >= '2024-12-01'
      AND NOT (r.is_churn_month = 1 AND r.churn_type = 'Involuntary')   -- involuntary analysed in 4.2
),
t AS (
    SELECT driver,
           CAST(SUM(CASE WHEN flag = 1 AND churned = 1 THEN 1 ELSE 0 END) AS FLOAT) AS a,   -- with factor, churned
           CAST(SUM(CASE WHEN flag = 1 AND churned = 0 THEN 1 ELSE 0 END) AS FLOAT) AS b,   -- with factor, stayed
           CAST(SUM(CASE WHEN flag = 0 AND churned = 1 THEN 1 ELSE 0 END) AS FLOAT) AS c,   -- without, churned
           CAST(SUM(CASE WHEN flag = 0 AND churned = 0 THEN 1 ELSE 0 END) AS FLOAT) AS d    -- without, stayed
    FROM d
    GROUP BY driver
),
s AS (
    SELECT driver, a, b, c, d,
           a / NULLIF(a + b, 0) AS rate_with,
           c / NULLIF(c + d, 0) AS rate_without,
           (a + b + c + d) * SQUARE(a * d - b * c)
               / NULLIF((a + b) * (c + d) * (a + c) * (b + d), 0) AS chi_square
    FROM t
)
SELECT driver,
       CAST(a + b AS INT)                                  AS months_with_factor,
       CAST(100 * rate_with    AS DECIMAL(6,2))            AS churn_rate_with_pct,
       CAST(100 * rate_without AS DECIMAL(6,2))            AS churn_rate_without_pct,
       CAST(rate_with / NULLIF(rate_without, 0) AS DECIMAL(6,2)) AS lift,
       CAST(chi_square AS DECIMAL(12,1))                   AS chi_square,
       CASE WHEN chi_square >= 10.83 THEN 'Significant (p < 0.001)'
            WHEN chi_square >= 6.63  THEN 'Significant (p < 0.01)'
            WHEN chi_square >= 3.84  THEN 'Significant (p < 0.05)'
            ELSE 'Not significant'
       END                                                 AS result
FROM s
ORDER BY lift DESC;
 
-- 4.2 Involuntary churn: payment method and late-payment history
--     Note: the last unpaid bills are part of the non-payment process itself,
--     so late history is an early-warning signal rather than a root cause.
SELECT r.payment_method,
       CASE WHEN r.late_payments_last_6m = 0 THEN '0 late payments'
            WHEN r.late_payments_last_6m = 1 THEN '1 late payment'
            ELSE '2+ late payments'
       END                                                                     AS late_history_6m,
       COUNT(*)                                                                AS customer_months,
       SUM(CASE WHEN r.churn_type = 'Involuntary' THEN 1 ELSE 0 END)           AS involuntary_churn,
       CAST(100.0 * SUM(CASE WHEN r.churn_type = 'Involuntary' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS involuntary_churn_pct
FROM dw.vw_customer_month_risk AS r
WHERE r.month_start_date >= '2024-12-01'
GROUP BY r.payment_method,
         CASE WHEN r.late_payments_last_6m = 0 THEN '0 late payments'
              WHEN r.late_payments_last_6m = 1 THEN '1 late payment'
              ELSE '2+ late payments' END
ORDER BY r.payment_method, late_history_6m;
 
-- 4.3 Disengagement before churn: does usage fall before customers leave?
--     Change vs each customer's own previous 3-month average (-0.20 = 20% lower).
SELECT CAST(DATEDIFF(MONTH, f.month_start_date,
                     DATEFROMPARTS(YEAR(c.churn_date), MONTH(c.churn_date), 1)) AS NVARCHAR(30))
           + ' months before churn'                                  AS stage,
       COUNT(*)                                                      AS customer_months,
       CAST(AVG(CAST(f.usage_change_vs_prior_3m  AS FLOAT)) AS DECIMAL(6,3)) AS avg_data_change,
       CAST(AVG(CAST(f.logins_change_vs_prior_3m AS FLOAT)) AS DECIMAL(6,3)) AS avg_logins_change
FROM dw.fact_customer_monthly AS f
JOIN dw.dim_customer AS c ON c.customer_id = f.customer_id
WHERE c.churn_type = 'Voluntary'
  AND f.is_usage_outlier = 0
  AND f.month_start_date >= '2024-12-01'
  AND DATEDIFF(MONTH, f.month_start_date, DATEFROMPARTS(YEAR(c.churn_date), MONTH(c.churn_date), 1)) BETWEEN 1 AND 6
GROUP BY DATEDIFF(MONTH, f.month_start_date, DATEFROMPARTS(YEAR(c.churn_date), MONTH(c.churn_date), 1))
UNION ALL
SELECT 'Baseline: customers who never churned',
       COUNT(*),
       CAST(AVG(CAST(f.usage_change_vs_prior_3m  AS FLOAT)) AS DECIMAL(6,3)),
       CAST(AVG(CAST(f.logins_change_vs_prior_3m AS FLOAT)) AS DECIMAL(6,3))
FROM dw.fact_customer_monthly AS f
JOIN dw.dim_customer AS c ON c.customer_id = f.customer_id
WHERE c.churn_date IS NULL
  AND f.is_usage_outlier = 0
  AND f.month_start_date >= '2024-12-01'
ORDER BY stage DESC;
 
 
/* ============================================================
   SECTION 5: COMPLAINTS & CHURN REASONS
   ============================================================ */
 
-- 5.1 Complaint themes by quarter, with change in share vs previous quarter
WITH q AS (
    SELECT CAST(d.year_number AS NVARCHAR(4)) + '-' + d.quarter_label AS year_quarter,
           t.complaint_theme,
           COUNT(*) AS tickets
    FROM dw.fact_support_ticket AS t
    JOIN dw.dim_date AS d ON d.date_key = t.created_date_key
    WHERE d.is_analysis_window = 1
      AND t.ticket_category <> 'Cancellation Request'
    GROUP BY CAST(d.year_number AS NVARCHAR(4)) + '-' + d.quarter_label, t.complaint_theme
),
shares AS (
    SELECT year_quarter, complaint_theme, tickets,
           100.0 * tickets / SUM(tickets) OVER (PARTITION BY year_quarter) AS share_pct
    FROM q
)
SELECT year_quarter,
       complaint_theme,
       tickets,
       CAST(share_pct AS DECIMAL(5,1)) AS share_pct,
       CAST(share_pct - LAG(share_pct) OVER (PARTITION BY complaint_theme ORDER BY year_quarter)
            AS DECIMAL(5,1))           AS share_change_vs_prev_quarter
FROM shares
ORDER BY year_quarter, tickets DESC;
 
-- 5.2 Which complaint themes are followed by churn within 60 days?
SELECT t.complaint_theme,
       COUNT(*)                                                             AS tickets,
       SUM(CASE WHEN c.churn_date BETWEEN CAST(t.created_datetime AS DATE)
                                      AND DATEADD(DAY, 60, CAST(t.created_datetime AS DATE))
                THEN 1 ELSE 0 END)                                          AS followed_by_churn,
       CAST(100.0 * SUM(CASE WHEN c.churn_date BETWEEN CAST(t.created_datetime AS DATE)
                                               AND DATEADD(DAY, 60, CAST(t.created_datetime AS DATE))
                         THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2))     AS churn_within_60d_pct
FROM dw.fact_support_ticket AS t
JOIN dw.dim_customer AS c ON c.customer_id = t.customer_id
WHERE t.ticket_category <> 'Cancellation Request'
  AND t.created_datetime >= '2024-09-01'
  AND t.created_datetime <  '2026-07-01'      -- leaves 60 days to observe the outcome
GROUP BY t.complaint_theme
ORDER BY churn_within_60d_pct DESC;
 
-- 5.3 Stated churn reasons by half-year: which reasons are growing?
WITH r AS (
    SELECT CASE WHEN e.churn_date <  '2025-03-01' THEN '1) Sep 2024 - Feb 2025'
                WHEN e.churn_date <  '2025-09-01' THEN '2) Mar 2025 - Aug 2025'
                WHEN e.churn_date <  '2026-03-01' THEN '3) Sep 2025 - Feb 2026'
                ELSE                                    '4) Mar 2026 - Aug 2026'
           END AS period,
           cr.reason_category,
           e.churn_type
    FROM dw.fact_churn_event AS e
    JOIN dw.dim_churn_reason AS cr ON cr.churn_reason_id = e.churn_reason_id
)
SELECT period,
       reason_category,
       COUNT(*) AS churned_customers,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY period) AS DECIMAL(5,1)) AS share_pct
FROM r
WHERE churn_type = 'Voluntary'
GROUP BY period, reason_category
ORDER BY period, churned_customers DESC;
 
-- 5.4 Competitor losses: port-outs by competitor and service
SELECT ISNULL(e.competitor_name, 'Not recorded') AS competitor_name,
       c.service_type,
       COUNT(*)                                  AS churned_customers,
       SUM(CAST(e.port_out_flag AS INT))         AS port_outs,
       SUM(e.last_monthly_revenue) * 12          AS annualized_revenue_lost
FROM dw.fact_churn_event AS e
JOIN dw.dim_customer AS c ON c.customer_id = e.customer_id
WHERE e.churn_type = 'Voluntary'
GROUP BY ISNULL(e.competitor_name, 'Not recorded'), c.service_type
ORDER BY churned_customers DESC;
 
 
/* ============================================================
   SECTION 6: CUSTOMER VALUE
   ============================================================ */
 
-- 6.1 Simple customer lifetime value (CLV) by plan, last 12 months
--     expected lifetime (months) = 1 / monthly churn rate
--     CLV = ARPU x expected lifetime   (revenue-based; no cost/margin data)
SELECT plan_category,
       contract_type,
       COUNT(*)                                                                AS customer_months,
       CAST(AVG(billed_amount) AS DECIMAL(10,2))                               AS arpu,
       CAST(100.0 * SUM(CAST(is_churn_month AS INT)) / COUNT(*) AS DECIMAL(5,2)) AS monthly_churn_pct,
       CAST(1.0 * COUNT(*) / NULLIF(SUM(CAST(is_churn_month AS INT)), 0) AS DECIMAL(8,1)) AS expected_lifetime_months,
       CAST(AVG(billed_amount) * COUNT(*) / NULLIF(SUM(CAST(is_churn_month AS INT)), 0) AS DECIMAL(12,0)) AS clv_inr
FROM dw.fact_customer_monthly
WHERE month_start_date >= '2025-09-01'
GROUP BY plan_category, contract_type
ORDER BY clv_inr DESC;
 
-- 6.2 Value tiers of active customers: how concentrated is revenue?
SELECT value_tier,
       COUNT(*)                                                                  AS customers,
       CAST(AVG(avg_bill_6m) AS DECIMAL(10,2))                                   AS avg_monthly_bill,
       SUM(current_monthly_bill)                                                 AS monthly_revenue,
       CAST(100.0 * SUM(current_monthly_bill) / SUM(SUM(current_monthly_bill)) OVER () AS DECIMAL(5,1)) AS revenue_share_pct
FROM dw.vw_active_customer_priority
GROUP BY value_tier
ORDER BY avg_monthly_bill DESC;
 
 
/* ============================================================
   SECTION 7: CHURN RISK SCORE - does it predict churn?
   Backtest: score every customer-month from Dec 2024 to Jul 2026,
   then check who actually churned in the FOLLOWING month.
   ============================================================ */
 
-- 7.1 Next-month churn rate by score bucket
--     cumulative_capture_pct = share of all churners found if we target
--     every customer at or above this score. Use it to set band cut-offs.
WITH b AS (
    SELECT (risk_score / 10) * 10          AS score_bucket,
           COUNT(*)                        AS customer_months,
           SUM(churned_next_month)         AS churned_next_month
    FROM dw.vw_customer_month_risk
    WHERE has_next_month_outcome = 1
      AND month_start_date >= '2024-12-01'
    GROUP BY (risk_score / 10) * 10
)
SELECT score_bucket,
       customer_months,
       churned_next_month,
       CAST(100.0 * churned_next_month / customer_months AS DECIMAL(5,2))  AS next_month_churn_pct,
       CAST(100.0 * SUM(customer_months)    OVER (ORDER BY score_bucket DESC ROWS UNBOUNDED PRECEDING)
                  / SUM(customer_months)    OVER () AS DECIMAL(5,1))        AS cumulative_customers_pct,
       CAST(100.0 * SUM(churned_next_month) OVER (ORDER BY score_bucket DESC ROWS UNBOUNDED PRECEDING)
                  / SUM(churned_next_month) OVER () AS DECIMAL(5,1))        AS cumulative_capture_pct
FROM b
ORDER BY score_bucket DESC;
 
-- 7.2 Performance by risk band
--     good result: High band has a much higher churn rate (lift) and
--     captures a large share of churners while being a small share of customers
SELECT risk_band,
       COUNT(*)                                                                   AS customer_months,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1))            AS share_of_customers_pct,
       SUM(churned_next_month)                                                    AS churners,
       CAST(100.0 * SUM(churned_next_month) / COUNT(*) AS DECIMAL(5,2))          AS next_month_churn_pct,
       CAST(100.0 * SUM(churned_next_month) / SUM(SUM(churned_next_month)) OVER () AS DECIMAL(5,1)) AS share_of_churners_pct,
       CAST( (1.0 * SUM(churned_next_month) / COUNT(*))
           / (1.0 * SUM(SUM(churned_next_month)) OVER () / SUM(COUNT(*)) OVER ()) AS DECIMAL(5,2)) AS lift
FROM dw.vw_customer_month_risk
WHERE has_next_month_outcome = 1
  AND month_start_date >= '2024-12-01'
GROUP BY risk_band
ORDER BY CASE risk_band WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 ELSE 3 END;
 
-- 7.3 Current active customers by risk band (latest month)
SELECT risk_band,
       COUNT(*)                                                       AS active_customers,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1)) AS share_pct,
       SUM(current_monthly_bill)                                      AS monthly_revenue
FROM dw.vw_active_customer_priority
GROUP BY risk_band
ORDER BY CASE risk_band WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 ELSE 3 END;
 
 
/* ============================================================
   SECTION 8: RISK vs VALUE PRIORITIZATION & REVENUE AT RISK
   ============================================================ */
 
-- 8.1 Prioritization matrix with expected revenue at risk
--     expected churners = customers x the band's historical next-month churn rate
WITH band_rate AS (
    SELECT risk_band, AVG(CAST(churned_next_month AS FLOAT)) AS next_month_churn_rate
    FROM dw.vw_customer_month_risk
    WHERE has_next_month_outcome = 1
      AND month_start_date >= '2024-12-01'
    GROUP BY risk_band
)
SELECT p.priority_rank,
       p.risk_band,
       p.value_tier,
       p.recommended_action,
       COUNT(*)                                                         AS customers,
       SUM(p.current_monthly_bill)                                      AS monthly_revenue,
       CAST(SUM(br.next_month_churn_rate) AS DECIMAL(8,1))              AS expected_churners_next_month,
       CAST(SUM(p.current_monthly_bill * br.next_month_churn_rate) AS DECIMAL(12,0))      AS expected_monthly_revenue_lost,
       CAST(SUM(p.current_monthly_bill * br.next_month_churn_rate) * 12 AS DECIMAL(12,0)) AS annualized_revenue_at_risk
FROM dw.vw_active_customer_priority AS p
JOIN band_rate AS br ON br.risk_band = p.risk_band
GROUP BY p.priority_rank, p.risk_band, p.value_tier, p.recommended_action
ORDER BY p.priority_rank, annualized_revenue_at_risk DESC;
 
-- 8.2 Target list for the retention team: top 50 priority customers
SELECT TOP (50)
       customer_id, recommended_action, risk_score, risk_band, value_tier,
       CAST(avg_bill_6m AS DECIMAL(10,2)) AS avg_monthly_bill,
       plan_category, contract_type, service_type, region_id, tenure_months,
       risk_reasons
FROM dw.vw_active_customer_priority
WHERE priority_rank <= 2
ORDER BY priority_rank, risk_score DESC, avg_bill_6m DESC;
 
 
/* ============================================================
   SECTION 9: RETENTION OFFER EFFECTIVENESS
   Only offers made at least 90 days before the extract date are
   used, so every offer has a full 90-day outcome window.
   Saved customer = accepted the offer and did not churn within 90 days.
   ============================================================ */
 
-- 9.1 Offer performance by trigger and offer type
SELECT o.trigger_type,
       dof.offer_type,
       COUNT(*)                                                                       AS offers,
       CAST(100.0 * SUM(CAST(o.accepted_flag AS INT)) / COUNT(*) AS DECIMAL(5,1))     AS acceptance_pct,
       CAST(100.0 * SUM(CASE WHEN o.accepted_flag = 1 AND o.churned_within_90_days = 1 THEN 1 ELSE 0 END)
            / NULLIF(SUM(CASE WHEN o.accepted_flag = 1 THEN 1 ELSE 0 END), 0) AS DECIMAL(5,1)) AS churn_90d_if_accepted_pct,
       CAST(100.0 * SUM(CASE WHEN o.accepted_flag = 0 AND o.churned_within_90_days = 1 THEN 1 ELSE 0 END)
            / NULLIF(SUM(CASE WHEN o.accepted_flag = 0 THEN 1 ELSE 0 END), 0) AS DECIMAL(5,1)) AS churn_90d_if_declined_pct,
       SUM(CASE WHEN o.accepted_flag = 1 AND o.churned_within_90_days = 0 THEN 1 ELSE 0 END)  AS saved_customers,
       SUM(CASE WHEN o.accepted_flag = 1 THEN o.offer_cost ELSE 0 END)                         AS offer_spend,
       CAST(SUM(CASE WHEN o.accepted_flag = 1 THEN o.offer_cost ELSE 0 END)
            / NULLIF(SUM(CASE WHEN o.accepted_flag = 1 AND o.churned_within_90_days = 0 THEN 1 ELSE 0 END), 0)
            AS DECIMAL(10,0))                                                                  AS cost_per_saved_customer
FROM dw.fact_retention_offer AS o
JOIN dw.dim_offer AS dof ON dof.offer_id = o.offer_id
WHERE o.offer_date <= DATEADD(DAY, -90, '2026-08-31')
GROUP BY o.trigger_type, dof.offer_type
ORDER BY o.trigger_type, saved_customers DESC;
 
-- 9.2 Do proactive offers really reduce churn?
--     Selection bias: offered customers are not random. So we compare them
--     with NON-offered customers in the same month, plan category and risk band
--     (a matched comparison), weighted by where the offers actually went.
--     Outcome: churn within the next 3 months.
WITH offered AS (
    SELECT DISTINCT customer_id,
           DATEFROMPARTS(YEAR(offer_date), MONTH(offer_date), 1) AS offer_month
    FROM dw.fact_retention_offer
    WHERE trigger_type = 'Proactive Outreach'
),
base AS (
    SELECT r.month_start_date, r.plan_category, r.risk_band,
           CASE WHEN o.customer_id IS NOT NULL THEN 1 ELSE 0 END AS was_offered,
           CASE WHEN r.customer_churn_date >  EOMONTH(r.month_start_date)
                 AND r.customer_churn_date <= EOMONTH(r.month_start_date, 3) THEN 1 ELSE 0 END AS churned_next_3m
    FROM dw.vw_customer_month_risk AS r
    LEFT JOIN offered AS o
           ON o.customer_id = r.customer_id AND o.offer_month = r.month_start_date
    WHERE r.is_churn_month = 0
      AND r.month_start_date BETWEEN '2024-12-01' AND '2026-05-01'   -- 3 months of outcome available
),
strata AS (
    SELECT month_start_date, plan_category, risk_band,
           SUM(was_offered)                                                     AS offered_n,
           SUM(CASE WHEN was_offered = 1 THEN churned_next_3m ELSE 0 END)       AS offered_churned,
           AVG(CASE WHEN was_offered = 0 THEN CAST(churned_next_3m AS FLOAT) END) AS comparison_rate
    FROM base
    GROUP BY month_start_date, plan_category, risk_band
    HAVING SUM(was_offered) > 0
)
SELECT SUM(offered_n)                                                             AS offered_customers,
       CAST(100.0 * SUM(offered_churned) / SUM(offered_n) AS DECIMAL(5,2))        AS churn_3m_offered_pct,
       CAST(100.0 * SUM(offered_n * comparison_rate) / SUM(offered_n) AS DECIMAL(5,2)) AS churn_3m_matched_comparison_pct,
       CAST(100.0 * (SUM(offered_n * comparison_rate) - SUM(offered_churned)) / SUM(offered_n)
            AS DECIMAL(5,2))                                                      AS churn_reduction_pct_points
FROM strata;
 
-- 9.3 Where does retention spend go? (plan tier and risk band at the offer month)
SELECT r.plan_category,
       r.risk_band,
       COUNT(*)                                                                AS accepted_offers,
       SUM(o.offer_cost)                                                       AS offer_spend,
       CAST(100.0 * SUM(o.offer_cost) / SUM(SUM(o.offer_cost)) OVER () AS DECIMAL(5,1)) AS share_of_spend_pct
FROM dw.fact_retention_offer AS o
JOIN dw.vw_customer_month_risk AS r
  ON r.customer_id      = o.customer_id
 AND r.month_start_date = DATEFROMPARTS(YEAR(o.offer_date), MONTH(o.offer_date), 1)
WHERE o.accepted_flag = 1
GROUP BY r.plan_category, r.risk_band
ORDER BY offer_spend DESC;
 
 
/* ============================================================
   SECTION 10: WHAT-IF SCENARIOS
   If a retention program reduces churn among today's P1 and P2
   customers by 10%, 20% or 30%, what is it worth over 12 months?
 
   Assumptions (state these when presenting):
   - Each band keeps its historical monthly churn rate for 12 months
   - A saved customer keeps paying their current bill for 12 months
   - Program cost = saved customers x historical cost per saved customer
   ============================================================ */
WITH band_rate AS (
    SELECT risk_band, AVG(CAST(churned_next_month AS FLOAT)) AS monthly_rate
    FROM dw.vw_customer_month_risk
    WHERE has_next_month_outcome = 1
      AND month_start_date >= '2024-12-01'
    GROUP BY risk_band
),
target AS (
    SELECT COUNT(*)                                                     AS target_customers,
           AVG(p.current_monthly_bill)                                  AS avg_monthly_bill,
           -- expected churners over 12 months = customers x (1 - (1 - monthly rate)^12)
           SUM(1 - POWER(1 - br.monthly_rate, 12))                      AS expected_churners_12m
    FROM dw.vw_active_customer_priority AS p
    JOIN band_rate AS br ON br.risk_band = p.risk_band
    WHERE p.priority_rank <= 2
),
cost AS (
    SELECT SUM(CASE WHEN accepted_flag = 1 THEN offer_cost ELSE 0 END)
           / NULLIF(SUM(CASE WHEN accepted_flag = 1 AND churned_within_90_days = 0 THEN 1 ELSE 0 END), 0)
           AS cost_per_saved
    FROM dw.fact_retention_offer
    WHERE offer_date <= DATEADD(DAY, -90, '2026-08-31')
)
SELECT CAST(100 * sc.reduction AS INT)                                   AS churn_reduction_pct,
       t.target_customers,
       CAST(t.expected_churners_12m AS DECIMAL(8,0))                     AS expected_churners_12m,
       CAST(t.expected_churners_12m * sc.reduction AS DECIMAL(8,0))      AS customers_saved,
       CAST(t.expected_churners_12m * sc.reduction * t.avg_monthly_bill * 12 AS DECIMAL(14,0)) AS revenue_protected_12m,
       CAST(t.expected_churners_12m * sc.reduction * c.cost_per_saved AS DECIMAL(14,0))        AS program_cost,
       CAST(t.expected_churners_12m * sc.reduction * (t.avg_monthly_bill * 12 - c.cost_per_saved)
            AS DECIMAL(14,0))                                             AS net_benefit_12m,
       CAST((t.avg_monthly_bill * 12 - c.cost_per_saved) / NULLIF(c.cost_per_saved, 0)
            AS DECIMAL(6,1))                                              AS roi_multiple
FROM target AS t
CROSS JOIN cost AS c
CROSS JOIN (VALUES (0.10), (0.20), (0.30)) AS sc(reduction)
ORDER BY sc.reduction;
GO

USE ConnectPlus_Analytics;
GO
 
