# Pipeline de détection de transactions à risque (Azure)

Projet personnel de bout en bout : ingestion de transactions bancaires synthétiques, transformation en modèle en étoile, scoring du risque et restitution Power BI avec sécurité par rôle (RLS).

> Statut : en cours (semaine 1 sur 4)

## 1. Contexte et objectif

- **Contexte :** [expliquez en 2 à 3 phrases pourquoi vous faites ce projet : passage d'Informatica PowerCenter vers une stack cloud Azure.]
- **Objectif :** construire un pipeline ELT reproductible sur Azure et un rapport Power BI qui identifie les clients à haut risque.
- **Hors périmètre :** pas de machine learning avancé ; le scoring repose sur des règles métier lisibles.

## 2. Données

- **Source :** jeu synthétique PaySim (Kaggle) : [lien vers la page, licence et date de téléchargement].
- Aucune donnée réelle ni issue d'une mission professionnelle n'est utilisée.
- **Colonnes principales :** step, type, amount, nameOrig, oldbalanceOrg, newbalanceOrig, nameDest, oldbalanceDest, newbalanceDest, isFraud.

## 3. Architecture

```
Fichier CSV -> Azure Data Lake (zone raw) -> Azure Data Factory -> Azure SQL -> Power BI -> Service fraude (RLS)
```

[Insérez ici un schéma exporté du cahier des charges : docs/architecture.png]

| Étape | Service | Rôle |
| --- | --- | --- |
| 1 | Fichier PaySim | Source des transactions |
| 2 | Azure Data Lake Gen2 | Zone brute, fichier déposé tel quel |
| 3 | Azure Data Factory | Ingestion, paramètres, déclencheur, journal |
| 4 | Azure SQL | Couches brute, nettoyée, modèle en étoile, contrôles qualité, scoring |
| 5 | Power BI | Mesures DAX, 3 pages, publication |
| 6 | Service fraude | Accès par rôle (RLS) |

## 3 bis. Environnement Azure

| Ressource | Nom | Région |
| --- | --- | --- |
| Groupe de ressources | rg-fraude-projet | France Central |
| Compte de stockage (Data Lake Gen2) | [nom] | France Central |
| Serveur et base Azure SQL | [nom] | [région] |
| Data Factory | [nom] | [région] |

Budget d'alerte : 10 USD par mois, alertes à 50 % et 80 %.

## 4. Journal d'avancement

Complétez après chaque étape : ce que vous avez fait, une capture d'écran, un choix et sa raison.

### Semaine 1 : socle
- [x] Compte Azure et abonnement
- [x] Budget d'alerte
- [x] Groupe de ressources
- [ ] Data Lake et conteneur `raw`
- [ ] Base Azure SQL
- [ ] Fichier PaySim déposé dans `raw`
- [ ] Dépôt GitHub

Décisions et difficultés : [...]

### Semaine 2 : ingestion
- [ ] Pipeline Data Factory
- [ ] Couches brute et nettoyée
- [ ] 5 contrôles de qualité et journal des rejets

### Semaine 3 : modèle
- [ ] Modèle en étoile (1 table de faits, au moins 3 dimensions)
- [ ] Règles et score de risque
- [ ] Premier rapport Power BI

### Semaine 4 : restitution
- [ ] Mesures DAX et RLS
- [ ] README final et schéma
- [ ] Présentation orale de 5 minutes

## 5. Règles de risque

| Règle | Description | Seuil |
| --- | --- | --- |
| Montant élevé | Transaction supérieure à un seuil, par type (TRANSFER, CASH_OUT) | [à définir] |
| Compte vidé | Solde nul après un transfert | |
| Fréquence anormale | Nombre de transactions sur une même période (step) | [à définir] |

Niveaux de risque : faible, moyen, élevé.

## 6. Contrôles de qualité

| Contrôle | Résultat attendu | Où sont journalisés les rejets |
| --- | --- | --- |
| Doublons | | |
| Valeurs nulles | | |
| Montants négatifs | | |
| [4e contrôle] | | |
| [5e contrôle] | | |

## 7. Résultats

[Captures du rapport Power BI, volumes traités, durée d'exécution du pipeline, nombre de clients par niveau de risque.]

## 8. Ce que j'ai appris

- [Ce qui a mal tourné et comment vous l'avez résolu.]
- [Ce que vous feriez différemment avec Informatica.]

## 9. Reproduire le projet

1. Créer un compte Azure et un groupe de ressources.
2. Déployer le Data Lake, Azure SQL et Data Factory.
3. Exécuter les scripts du dossier `sql/`.
4. Importer les pipelines du dossier `adf/`.
5. Ouvrir le rapport du dossier `powerbi/`.

## Sécurité

Aucun mot de passe, clé d'accès ni chaîne de connexion ne doit apparaître dans ce dépôt.

## Structure du dépôt

```
sql/        scripts SQL (couches et modèle en étoile)
adf/        exports des pipelines Data Factory
powerbi/    rapport et captures
docs/       schémas et captures
```
