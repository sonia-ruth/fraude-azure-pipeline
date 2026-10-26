/* ============================================================
   Projet : Pipeline de détection de transactions à risque
   Script : 02_clean_layer_procedure.sql
   Cible  : Azure SQL Database (sqldb-fraude)
   Rôle   : procédure clean.usp_load_transactions
            - applique 6 contrôles de qualité sur raw.paysim_transactions
            - écrit les lignes valides dans clean.transactions
            - écrit les lignes rejetées (avec le motif) dans clean.rejected_rows
            - journalise l'exécution dans audit.pipeline_log
   Rejouable : la procédure vide les tables clean avant de les recharger.
   ============================================================ */

CREATE OR ALTER PROCEDURE clean.usp_load_transactions
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @started_at DATETIME2(0) = SYSUTCDATETIME();
    DECLARE @rows_read BIGINT, @rows_rejected BIGINT, @rows_written BIGINT;

    BEGIN TRY
        SELECT @rows_read = COUNT_BIG(*) FROM raw.paysim_transactions;

        -- Rechargement complet : on repart de zéro
        TRUNCATE TABLE clean.transactions;
        TRUNCATE TABLE clean.rejected_rows;

        /* ---- 1. Lignes rejetées -------------------------------------
           Contrôles, dans l'ordre :
             1) valeur obligatoire manquante
             2) montant négatif
             3) type de transaction inconnu
             4) step invalide (inférieur à 1)
             5) indicateur de fraude différent de 0 ou 1
             6) doublon (ligne identique sur toutes les colonnes)       */
        ;WITH checked AS (
            SELECT r.*,
                   ROW_NUMBER() OVER (
                       PARTITION BY step, type, amount, nameOrig, oldbalanceOrg, newbalanceOrig,
                                    nameDest, oldbalanceDest, newbalanceDest, isFraud, isFlaggedFraud
                       ORDER BY (SELECT NULL)) AS rn
            FROM raw.paysim_transactions r
        ),
        reasoned AS (
            SELECT *,
                   CASE
                     WHEN step IS NULL OR type IS NULL OR amount IS NULL OR nameOrig IS NULL
                          OR nameDest IS NULL OR oldbalanceOrg IS NULL OR newbalanceOrig IS NULL
                          OR oldbalanceDest IS NULL OR newbalanceDest IS NULL
                          OR isFraud IS NULL OR isFlaggedFraud IS NULL
                          THEN N'Valeur obligatoire manquante'
                     WHEN amount < 0 THEN N'Montant négatif'
                     WHEN type NOT IN (N'CASH_IN', N'CASH_OUT', N'DEBIT', N'PAYMENT', N'TRANSFER')
                          THEN N'Type de transaction inconnu'
                     WHEN step < 1 THEN N'Step invalide'
                     WHEN isFraud NOT IN (0, 1) OR isFlaggedFraud NOT IN (0, 1)
                          THEN N'Indicateur de fraude invalide'
                     WHEN rn > 1 THEN N'Doublon'
                   END AS reject_reason
            FROM checked
        )
        INSERT INTO clean.rejected_rows (step, type, amount, nameOrig, nameDest, reject_reason)
        SELECT step, type, amount, nameOrig, nameDest, reject_reason
        FROM reasoned
        WHERE reject_reason IS NOT NULL;

        SET @rows_rejected = @@ROWCOUNT;

        /* ---- 2. Lignes valides -------------------------------------- */
        ;WITH checked AS (
            SELECT r.*,
                   ROW_NUMBER() OVER (
                       PARTITION BY step, type, amount, nameOrig, oldbalanceOrg, newbalanceOrig,
                                    nameDest, oldbalanceDest, newbalanceDest, isFraud, isFlaggedFraud
                       ORDER BY (SELECT NULL)) AS rn
            FROM raw.paysim_transactions r
        )
        INSERT INTO clean.transactions
            (step, transaction_type, amount, name_orig, old_balance_orig, new_balance_orig,
             name_dest, old_balance_dest, new_balance_dest, is_fraud, is_flagged_fraud)
        SELECT step, type, amount, nameOrig, oldbalanceOrg, newbalanceOrig,
               nameDest, oldbalanceDest, newbalanceDest,
               CAST(isFraud AS BIT), CAST(isFlaggedFraud AS BIT)
        FROM checked
        WHERE rn = 1
          AND step IS NOT NULL AND type IS NOT NULL AND amount IS NOT NULL
          AND nameOrig IS NOT NULL AND nameDest IS NOT NULL
          AND oldbalanceOrg IS NOT NULL AND newbalanceOrig IS NOT NULL
          AND oldbalanceDest IS NOT NULL AND newbalanceDest IS NOT NULL
          AND isFraud IS NOT NULL AND isFlaggedFraud IS NOT NULL
          AND amount >= 0
          AND type IN (N'CASH_IN', N'CASH_OUT', N'DEBIT', N'PAYMENT', N'TRANSFER')
          AND step >= 1
          AND isFraud IN (0, 1) AND isFlaggedFraud IN (0, 1);

        SET @rows_written = @@ROWCOUNT;

        /* ---- 3. Journal --------------------------------------------- */
        INSERT INTO audit.pipeline_log
            (pipeline_name, step_name, rows_read, rows_written, rows_rejected, status, started_at, ended_at)
        VALUES
            (N'pl_load_paysim', N'raw_to_clean', @rows_read, @rows_written, @rows_rejected,
             N'Succeeded', @started_at, SYSUTCDATETIME());
    END TRY
    BEGIN CATCH
        INSERT INTO audit.pipeline_log
            (pipeline_name, step_name, rows_read, rows_written, rows_rejected, status, started_at, ended_at)
        VALUES
            (N'pl_load_paysim', N'raw_to_clean', @rows_read, NULL, NULL,
             N'Failed', @started_at, SYSUTCDATETIME());
        THROW;
    END CATCH
END;
GO

/* ---- Contrôles après exécution (à lancer à la main) ----------------
EXEC clean.usp_load_transactions;

SELECT TOP 5 * FROM audit.pipeline_log ORDER BY log_id DESC;

SELECT reject_reason, COUNT(*) AS nb
FROM clean.rejected_rows
GROUP BY reject_reason;

SELECT COUNT(*) AS nb_lignes_propres FROM clean.transactions;
--------------------------------------------------------------------- */
