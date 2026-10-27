/* ============================================================
   Projet : Pipeline de détection de transactions à risque
   Script : 04_powerbi_views.sql
   Cible  : Azure SQL Database (sqldb-fraude)
   Rôle   : vues légères pour Power BI (évite d'importer 6,3 M lignes)
             - dw.vw_transactions_a_risque : transactions de niveau Moyen ou Élevé
             - dw.vw_synthese_risque       : synthèse par jour, type et niveau (toutes transactions)
             - dw.vw_comptes_destinataires : comptes destinataires ayant reçu des transactions Élevé
   ============================================================ */

CREATE OR ALTER VIEW dw.vw_transactions_a_risque
AS
SELECT f.transaction_id,
       tm.day_number,
       tm.hour_of_day,
       tm.is_night,
       ty.transaction_type,
       co.category_label AS orig_category,
       cd.category_label AS dest_category,
       f.name_orig,
       f.name_dest,
       f.amount,
       f.old_balance_orig,
       f.new_balance_orig,
       f.old_balance_dest,
       f.new_balance_dest,
       f.rule_account_emptied,
       f.rule_high_amount,
       f.rule_dest_no_balance_move,
       f.risk_score,
       l.risk_level,
       f.is_fraud
FROM dw.fact_transaction f
JOIN dw.dim_time tm              ON tm.time_key = f.time_key
JOIN dw.dim_transaction_type ty  ON ty.type_key = f.type_key
JOIN dw.dim_account_category co  ON co.category_key = f.orig_category_key
JOIN dw.dim_account_category cd  ON cd.category_key = f.dest_category_key
JOIN dw.dim_risk_level l         ON l.risk_level_key = f.risk_level_key
WHERE l.risk_level IN (N'Moyen', N'Élevé');
GO

CREATE OR ALTER VIEW dw.vw_synthese_risque
AS
SELECT tm.day_number,
       ty.transaction_type,
       l.risk_level,
       COUNT_BIG(*)                         AS nb_transactions,
       SUM(CAST(f.is_fraud AS INT))         AS nb_fraudes,
       SUM(f.amount)                        AS montant_total
FROM dw.fact_transaction f
JOIN dw.dim_time tm              ON tm.time_key = f.time_key
JOIN dw.dim_transaction_type ty  ON ty.type_key = f.type_key
JOIN dw.dim_risk_level l         ON l.risk_level_key = f.risk_level_key
GROUP BY tm.day_number, ty.transaction_type, l.risk_level;
GO

CREATE OR ALTER VIEW dw.vw_comptes_destinataires
AS
SELECT f.name_dest,
       COUNT_BIG(*)                         AS nb_transactions_elevees,
       SUM(f.amount)                        AS montant_total,
       MAX(f.risk_score)                    AS score_max,
       SUM(CAST(f.is_fraud AS INT))         AS nb_fraudes_confirmees
FROM dw.fact_transaction f
JOIN dw.dim_risk_level l ON l.risk_level_key = f.risk_level_key
WHERE l.risk_level = N'Élevé'
GROUP BY f.name_dest;
GO

/* ---- Contrôles (à lancer à la main) ----------------------------------
SELECT COUNT(*) AS nb_lignes FROM dw.vw_transactions_a_risque;   -- environ 162 000
SELECT COUNT(*) AS nb_lignes FROM dw.vw_synthese_risque;
SELECT TOP 10 * FROM dw.vw_comptes_destinataires ORDER BY montant_total DESC;
--------------------------------------------------------------------- */
