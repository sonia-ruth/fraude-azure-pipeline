/* ============================================================
   Projet : Pipeline de détection de transactions à risque
   Script : 03_star_schema_and_risk_score.sql
   Cible  : Azure SQL Database (sqldb-fraude)
   Rôle   : crée le modèle en étoile (schéma dw) et la procédure
            dw.usp_build_star qui le remplit et calcule le score.
   Principe : le score de risque n'utilise JAMAIS is_fraud.
              is_fraud sert uniquement à évaluer les règles.
   Calibrage des règles (sur TRANSFER + CASH_OUT) :
              compte vidé               : 97,6 % des fraudes, 0,67 % de précision
              montant >= 500 000        : 47,0 % des fraudes, 1,23 % de précision
              destinataire sans mouv.   : 49,6 % des fraudes, 70,5 % de précision
   ============================================================ */

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'dw') EXEC('CREATE SCHEMA dw');
GO

/* ---- 1. Paramètres des règles (modifiables sans toucher au code) ---- */
IF OBJECT_ID('dw.risk_rule', 'U') IS NULL
BEGIN
    CREATE TABLE dw.risk_rule (
        rule_code    NVARCHAR(40)   NOT NULL CONSTRAINT PK_dw_risk_rule PRIMARY KEY,
        description  NVARCHAR(200)  NOT NULL,
        points       INT            NOT NULL,
        threshold    DECIMAL(18,2)  NULL
    );
    INSERT INTO dw.risk_rule (rule_code, description, points, threshold) VALUES
      (N'DEST_NO_BALANCE_MOVE', N'Destinataire sans variation de solde (solde avant et après à 0)', 45, NULL),
      (N'ACCOUNT_EMPTIED',      N'Compte émetteur vidé (solde final à 0 alors que le solde initial était positif)', 35, NULL),
      (N'HIGH_AMOUNT',          N'Montant supérieur ou égal au seuil', 20, 500000);
END
GO

/* ---- 2. Dimensions -------------------------------------------------- */
IF OBJECT_ID('dw.dim_transaction_type', 'U') IS NULL
CREATE TABLE dw.dim_transaction_type (
    type_key          INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_transaction_type PRIMARY KEY,
    transaction_type  NVARCHAR(20)      NOT NULL CONSTRAINT UQ_dim_transaction_type UNIQUE
);
GO

IF OBJECT_ID('dw.dim_time', 'U') IS NULL
CREATE TABLE dw.dim_time (
    time_key     INT      NOT NULL CONSTRAINT PK_dim_time PRIMARY KEY,   -- = step
    day_number   INT      NOT NULL,
    hour_of_day  TINYINT  NOT NULL,
    is_night     BIT      NOT NULL                                      -- 0 h à 5 h
);
GO

IF OBJECT_ID('dw.dim_account_category', 'U') IS NULL
BEGIN
    CREATE TABLE dw.dim_account_category (
        category_key    TINYINT      NOT NULL CONSTRAINT PK_dim_account_category PRIMARY KEY,
        category_code   CHAR(1)      NOT NULL CONSTRAINT UQ_dim_account_category UNIQUE,
        category_label  NVARCHAR(20) NOT NULL
    );
    INSERT INTO dw.dim_account_category VALUES (1, 'C', N'Client'), (2, 'M', N'Marchand');
END
GO

IF OBJECT_ID('dw.dim_risk_level', 'U') IS NULL
BEGIN
    CREATE TABLE dw.dim_risk_level (
        risk_level_key  TINYINT      NOT NULL CONSTRAINT PK_dim_risk_level PRIMARY KEY,
        risk_level      NVARCHAR(10) NOT NULL,
        min_score       INT          NOT NULL,
        max_score       INT          NOT NULL
    );
    INSERT INTO dw.dim_risk_level VALUES
      (1, N'Faible', 0, 44),
      (2, N'Moyen', 45, 79),
      (3, N'Élevé', 80, 1000);
END
GO

/* ---- 3. Table de faits : 1 ligne par transaction --------------------- */
IF OBJECT_ID('dw.fact_transaction', 'U') IS NULL
CREATE TABLE dw.fact_transaction (
    transaction_id              BIGINT        NOT NULL CONSTRAINT PK_fact_transaction PRIMARY KEY,
    time_key                    INT           NOT NULL CONSTRAINT FK_fact_time      REFERENCES dw.dim_time(time_key),
    type_key                    INT           NOT NULL CONSTRAINT FK_fact_type      REFERENCES dw.dim_transaction_type(type_key),
    orig_category_key           TINYINT       NOT NULL CONSTRAINT FK_fact_orig_cat  REFERENCES dw.dim_account_category(category_key),
    dest_category_key           TINYINT       NOT NULL CONSTRAINT FK_fact_dest_cat  REFERENCES dw.dim_account_category(category_key),
    risk_level_key              TINYINT       NOT NULL CONSTRAINT FK_fact_risk      REFERENCES dw.dim_risk_level(risk_level_key),
    name_orig                   NVARCHAR(30)  NOT NULL,
    name_dest                   NVARCHAR(30)  NOT NULL,
    amount                      DECIMAL(18,2) NOT NULL,
    old_balance_orig            DECIMAL(18,2) NOT NULL,
    new_balance_orig            DECIMAL(18,2) NOT NULL,
    old_balance_dest            DECIMAL(18,2) NOT NULL,
    new_balance_dest            DECIMAL(18,2) NOT NULL,
    is_fraud                    BIT           NOT NULL,   -- réalité (évaluation uniquement)
    is_flagged_fraud            BIT           NOT NULL,
    rule_account_emptied        BIT           NOT NULL,
    rule_high_amount            BIT           NOT NULL,
    rule_dest_no_balance_move   BIT           NOT NULL,
    risk_score                  SMALLINT      NOT NULL
);
GO

/* ---- 4. Procédure de construction ------------------------------------ */
CREATE OR ALTER PROCEDURE dw.usp_build_star
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @started_at DATETIME2(0) = SYSUTCDATETIME();
    DECLARE @rows_read BIGINT, @rows_written BIGINT;

    BEGIN TRY
        SELECT @rows_read = COUNT_BIG(*) FROM clean.transactions;

        DECLARE @p_dest    INT, @p_emptied INT, @p_high INT, @th_high DECIMAL(18,2);
        SELECT @p_dest    = points                  FROM dw.risk_rule WHERE rule_code = N'DEST_NO_BALANCE_MOVE';
        SELECT @p_emptied = points                  FROM dw.risk_rule WHERE rule_code = N'ACCOUNT_EMPTIED';
        SELECT @p_high    = points, @th_high = threshold FROM dw.risk_rule WHERE rule_code = N'HIGH_AMOUNT';

        -- Dimensions (ajout des valeurs nouvelles uniquement)
        INSERT INTO dw.dim_transaction_type (transaction_type)
        SELECT DISTINCT t.transaction_type
        FROM clean.transactions t
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_transaction_type d WHERE d.transaction_type = t.transaction_type);

        INSERT INTO dw.dim_time (time_key, day_number, hour_of_day, is_night)
        SELECT DISTINCT t.step, t.day_number, t.hour_of_day,
               CASE WHEN t.hour_of_day BETWEEN 0 AND 5 THEN 1 ELSE 0 END
        FROM clean.transactions t
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_time d WHERE d.time_key = t.step);

        -- Faits : rechargement complet
        DELETE FROM dw.fact_transaction;

        INSERT INTO dw.fact_transaction
            (transaction_id, time_key, type_key, orig_category_key, dest_category_key, risk_level_key,
             name_orig, name_dest, amount, old_balance_orig, new_balance_orig,
             old_balance_dest, new_balance_dest, is_fraud, is_flagged_fraud,
             rule_account_emptied, rule_high_amount, rule_dest_no_balance_move, risk_score)
        SELECT t.transaction_id, t.step, ty.type_key, co.category_key, cd.category_key, lv.risk_level_key,
               t.name_orig, t.name_dest, t.amount, t.old_balance_orig, t.new_balance_orig,
               t.old_balance_dest, t.new_balance_dest, t.is_fraud, t.is_flagged_fraud,
               r.r_emptied, r.r_high, r.r_dest, s.score
        FROM clean.transactions t
        JOIN dw.dim_transaction_type ty ON ty.transaction_type = t.transaction_type
        JOIN dw.dim_account_category co ON co.category_code = LEFT(t.name_orig, 1)
        JOIN dw.dim_account_category cd ON cd.category_code = LEFT(t.name_dest, 1)
        CROSS APPLY (
            SELECT
              CASE WHEN t.transaction_type IN (N'TRANSFER', N'CASH_OUT')
                    AND t.new_balance_orig = 0 AND t.old_balance_orig > 0 THEN 1 ELSE 0 END AS r_emptied,
              CASE WHEN t.transaction_type IN (N'TRANSFER', N'CASH_OUT')
                    AND t.amount >= @th_high THEN 1 ELSE 0 END AS r_high,
              CASE WHEN t.transaction_type IN (N'TRANSFER', N'CASH_OUT')
                    AND t.old_balance_dest = 0 AND t.new_balance_dest = 0 THEN 1 ELSE 0 END AS r_dest
        ) r
        CROSS APPLY (
            SELECT r.r_emptied * @p_emptied + r.r_high * @p_high + r.r_dest * @p_dest AS score
        ) s
        JOIN dw.dim_risk_level lv ON s.score BETWEEN lv.min_score AND lv.max_score;

        SET @rows_written = @@ROWCOUNT;

        -- Contrôle de cohérence : aucune ligne perdue dans les jointures
        IF @rows_written <> @rows_read
            THROW 50001, 'Ecart entre clean.transactions et dw.fact_transaction : des lignes ont ete perdues.', 1;

        INSERT INTO audit.pipeline_log
            (pipeline_name, step_name, rows_read, rows_written, rows_rejected, status, started_at, ended_at)
        VALUES
            (N'pl_load_paysim', N'clean_to_star', @rows_read, @rows_written, 0,
             N'Succeeded', @started_at, SYSUTCDATETIME());
    END TRY
    BEGIN CATCH
        INSERT INTO audit.pipeline_log
            (pipeline_name, step_name, rows_read, rows_written, rows_rejected, status, started_at, ended_at)
        VALUES
            (N'pl_load_paysim', N'clean_to_star', @rows_read, NULL, NULL,
             N'Failed', @started_at, SYSUTCDATETIME());
        THROW;
    END CATCH
END;
GO

/* ---- Évaluation des règles : à lancer après l'exécution --------------
EXEC dw.usp_build_star;

SELECT l.risk_level,
       COUNT(*)                                  AS nb_transactions,
       SUM(CAST(f.is_fraud AS INT))              AS nb_fraudes,
       CAST(100.0 * SUM(CAST(f.is_fraud AS INT)) / COUNT(*) AS DECIMAL(6,2)) AS pct_fraude
FROM dw.fact_transaction f
JOIN dw.dim_risk_level l ON l.risk_level_key = f.risk_level_key
GROUP BY l.risk_level, l.min_score
ORDER BY l.min_score;
--------------------------------------------------------------------- */
