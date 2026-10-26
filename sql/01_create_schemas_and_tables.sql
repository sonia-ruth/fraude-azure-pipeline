/* ============================================================
   Projet : Pipeline de détection de transactions à risque
   Script : 01_create_schemas_and_tables.sql
   Cible  : Azure SQL Database (sqldb-fraude)
   Rôle   : crée les schémas et les tables des couches
            brute (raw), nettoyée (clean) et d'audit.
   Le script peut être relancé sans erreur.
   ============================================================ */

-- 1. Schémas ---------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'raw')   EXEC('CREATE SCHEMA raw');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'clean') EXEC('CREATE SCHEMA clean');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'audit') EXEC('CREATE SCHEMA audit');
GO

-- 2. Couche brute : copie fidèle du fichier PaySim -------------
IF OBJECT_ID('raw.paysim_transactions', 'U') IS NULL
CREATE TABLE raw.paysim_transactions (
    step              INT             NULL,   -- 1 step = 1 heure
    type              NVARCHAR(20)    NULL,   -- CASH_IN, CASH_OUT, DEBIT, PAYMENT, TRANSFER
    amount            DECIMAL(18,2)   NULL,
    nameOrig          NVARCHAR(30)    NULL,   -- client émetteur
    oldbalanceOrg     DECIMAL(18,2)   NULL,
    newbalanceOrig    DECIMAL(18,2)   NULL,
    nameDest          NVARCHAR(30)    NULL,   -- destinataire
    oldbalanceDest    DECIMAL(18,2)   NULL,
    newbalanceDest    DECIMAL(18,2)   NULL,
    isFraud           TINYINT         NULL,
    isFlaggedFraud    TINYINT         NULL,
    -- métadonnées de chargement
    load_ts           DATETIME2(0)    NOT NULL CONSTRAINT DF_raw_load_ts DEFAULT SYSUTCDATETIME(),
    source_file       NVARCHAR(260)   NULL
);
GO

-- 3. Couche nettoyée : types contrôlés + colonnes dérivées ------
IF OBJECT_ID('clean.transactions', 'U') IS NULL
CREATE TABLE clean.transactions (
    transaction_id    BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_clean_transactions PRIMARY KEY,
    step              INT             NOT NULL,
    day_number        AS ((step - 1) / 24 + 1) PERSISTED,   -- jour simulé
    hour_of_day       AS ((step - 1) % 24)     PERSISTED,   -- heure simulée (0 à 23)
    transaction_type  NVARCHAR(20)    NOT NULL,
    amount            DECIMAL(18,2)   NOT NULL,
    name_orig         NVARCHAR(30)    NOT NULL,
    old_balance_orig  DECIMAL(18,2)   NOT NULL,
    new_balance_orig  DECIMAL(18,2)   NOT NULL,
    name_dest         NVARCHAR(30)    NOT NULL,
    old_balance_dest  DECIMAL(18,2)   NOT NULL,
    new_balance_dest  DECIMAL(18,2)   NOT NULL,
    is_fraud          BIT             NOT NULL,
    is_flagged_fraud  BIT             NOT NULL,
    loaded_at         DATETIME2(0)    NOT NULL CONSTRAINT DF_clean_loaded_at DEFAULT SYSUTCDATETIME()
);
GO

-- 4. Lignes rejetées par les contrôles de qualité ---------------
IF OBJECT_ID('clean.rejected_rows', 'U') IS NULL
CREATE TABLE clean.rejected_rows (
    reject_id         BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_clean_rejected_rows PRIMARY KEY,
    step              INT             NULL,
    type              NVARCHAR(20)    NULL,
    amount            DECIMAL(18,2)   NULL,
    nameOrig          NVARCHAR(30)    NULL,
    nameDest          NVARCHAR(30)    NULL,
    reject_reason     NVARCHAR(100)   NOT NULL,
    rejected_at       DATETIME2(0)    NOT NULL CONSTRAINT DF_rejected_at DEFAULT SYSUTCDATETIME()
);
GO

-- 5. Journal d'exécution du pipeline ---------------------------
IF OBJECT_ID('audit.pipeline_log', 'U') IS NULL
CREATE TABLE audit.pipeline_log (
    log_id            BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_audit_pipeline_log PRIMARY KEY,
    pipeline_name     NVARCHAR(100)   NOT NULL,
    step_name         NVARCHAR(100)   NOT NULL,
    rows_read         BIGINT          NULL,
    rows_written      BIGINT          NULL,
    rows_rejected     BIGINT          NULL,
    status            NVARCHAR(20)    NOT NULL,   -- Succeeded / Failed
    started_at        DATETIME2(0)    NOT NULL,
    ended_at          DATETIME2(0)    NULL
);
GO

-- 6. Vérification ----------------------------------------------
SELECT s.name AS [schema], t.name AS [table]
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name IN ('raw', 'clean', 'audit')
ORDER BY s.name, t.name;
