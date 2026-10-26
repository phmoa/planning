#!/bin/ksh

############################################################################
# Reprise des plannings bloqués
#
# Paramètres
#   -u | --user      : Utilisateur Oracle                  (obligatoire)
#   -p | --password  : Mot de passe Oracle                 (obligatoire)
#   -d | --db        : Alias TNS ou EZConnect hote:port/service
#                      (optionnel si ORACLE_SID / TWO_TASK est positionné)
#   -y | --yes       : Validation automatique
############################################################################

AUTO_VALIDATION=0
DB_USER=""
DB_PASS=""
DB_TNS=""

usage() {
    echo "Usage : $0 -u <utilisateur> -p <mot_de_passe> [-d <base>] [-y]"
    echo "  -u | --user      : Utilisateur Oracle"
    echo "  -p | --password  : Mot de passe Oracle"
    echo "  -d | --db        : Alias TNS ou EZConnect (optionnel si ORACLE_SID est positionné)"
    echo "  -y | --yes       : Exécute automatiquement sans demander de validation"
    echo "  (Sans -y)        : Demande une confirmation interactive avant exécution"
}

while [ $# -gt 0 ]
do
    case "$1" in
        -u|--user)
            [ -z "$2" ] && { echo "Option $1 : valeur manquante"; usage; exit 1; }
            DB_USER="$2"
            shift 2
            ;;
        -p|--password)
            [ -z "$2" ] && { echo "Option $1 : valeur manquante"; usage; exit 1; }
            DB_PASS="$2"
            shift 2
            ;;
        -d|--db)
            [ -z "$2" ] && { echo "Option $1 : valeur manquante"; usage; exit 1; }
            DB_TNS="$2"
            shift 2
            ;;
        -y|--yes|-f|--force|auto|AUTO|[oO]|[oO][uU][iI]|[yY]|[yY][eE][sS])
            AUTO_VALIDATION=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Option non reconnue : $1"
            usage
            exit 1
            ;;
    esac
done

if [ -z "$DB_USER" ] || [ -z "$DB_PASS" ]
then
    echo "Erreur : l'utilisateur (-u) et le mot de passe (-p) sont obligatoires."
    usage
    exit 1
fi

############################################################################
# Initialisation des logs et rotation
############################################################################

DIR_LOGS="./logs"
if [ ! -d "$DIR_LOGS" ]
then
    mkdir -p "$DIR_LOGS" 2>/dev/null
fi

DATE_LOG=$(date +'%Y%m%d_%H%M%S')
LOG_FILE="${DIR_LOGS}/reprise_planning_${DATE_LOG}.log"
touch "$LOG_FILE"

# Rotation des logs : ne conserver que les 5 plus récents (le nouveau inclus)
ls -1t "$DIR_LOGS"/reprise_planning_*.log 2>/dev/null | tail -n +6 | while read -r OLD_LOG
do
    [ -n "$OLD_LOG" ] && rm -f "$OLD_LOG"
done

# Fonctions d'écriture simultanée écran et fichier de log
log() {
    if [ $# -eq 0 ]
    then
        echo ""
        echo "" >> "$LOG_FILE"
    else
        echo "$@"
        echo "$@" >> "$LOG_FILE"
    fi
}

log_printf() {
    printf "$@"
    printf "$@" >> "$LOG_FILE"
}

############################################################################
# Construction de la chaîne de connexion
############################################################################

# Mot de passe entre guillemets pour supporter les caractères spéciaux (@, /, ...)
chaine_de_connexion_as="${DB_USER}/\"${DB_PASS}\"${DB_TNS:+@${DB_TNS}}"

############################################################################
# Configuration des chemins et fichiers de travail
############################################################################

REPERTOIRE_LOG="/as_shared/log/batch"
REP_ENTREE="/export/SLE/ITF/EAM/Sortie/GPSEAM001/"
REP_ENCOURS="/as_shared/misc/batchs/gps/planning/encours/"
REP_ARCHIVE="/as_shared/misc/batchs/gps/planning/archive"

TMP_RAW="./liste_raw_$$.txt"
TMP_PROJ_SEEN="./projets_vus_$$.txt"
TMP_LIST="./liste_ids_$$.txt"
TMP_KEEP="./liste_ids_keep_$$.txt"
TMP_PROJETS="./liste_projets_$$.txt"
TMP_REP="./liste_repertoires_$$.txt"
LISTE_ARCHIVE="./liste_archivage_$$.txt"
LISTE_REJEU="./liste_rejeu_$$.txt"
SQL_FILE="./updates_$$.sql"

############################################################################
# Nettoyage
############################################################################

cleanup() {
    rm -f "$TMP_RAW" "$TMP_PROJ_SEEN" "$TMP_LIST" "$TMP_KEEP" "$TMP_PROJETS" "$TMP_REP" "$LISTE_ARCHIVE" "$LISTE_REJEU" "$SQL_FILE"
    unset chaine_de_connexion_as DB_PASS
}

trap cleanup EXIT

log "================================================================================"
log "                        REPRISE DES PLANNINGS BLOQUÉS"
log "Date d'exécution : $(date +'%Y-%m-%d %H:%M:%S')"
log "Fichier de log   : $LOG_FILE"
log "================================================================================"

############################################################################
# Recherche des identifiants en échec
############################################################################

sqlplus -s "${chaine_de_connexion_as}" <<EOF | \
sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
grep -v '^$' > "$TMP_RAW"

SET PAGESIZE 0
SET FEEDBACK OFF
SET HEADING OFF
SET VERIFY OFF
SET ECHO OFF
SET LINESIZE 32767
SET WRAP OFF

SELECT
    TRIM(bje.job_execution_id) || '|' || TRIM(bjep.STRING_VAL)
FROM
         batch_job_execution bje
    JOIN batch_job_instance         bji  ON bje.job_instance_id = bji.job_instance_id
    JOIN batch_job_execution_params bjep ON bje.job_execution_id = bjep.job_execution_id
    JOIN itf_gpat_projet_seq        gpat ON gpat.CODE_PROJET = bjep.STRING_VAL
WHERE
    bjep.key_name = 'codeProjet'
    and STATUS <> 'COMPLETED'
    and gpat.STATUT <> 'FINI'
    and bje.START_TIME < SYSDATE - INTERVAL '3' HOUR
ORDER BY
    bje.START_TIME DESC, bje.job_execution_id DESC
;

EXIT;
EOF

if [ ! -s "$TMP_RAW" ]
then
    log "Aucun identifiant candidat récupéré en base."
    exit 0
fi

############################################################################
# Filtrage des doublons : conservation de l'exécution la plus récente par projet
############################################################################

> "$TMP_PROJ_SEEN"
> "$TMP_LIST"

while IFS='|' read -r ID CODE_PRJ
do
    [ -z "$ID" ] && continue
    if grep -Fxq "$CODE_PRJ" "$TMP_PROJ_SEEN" 2>/dev/null
    then
        log "  [INFO] Doublon détecté pour le projet $CODE_PRJ : ancien Job ID $ID ignoré (seul le plus récent est conservé)."
    else
        echo "$CODE_PRJ" >> "$TMP_PROJ_SEEN"
        echo "$ID" >> "$TMP_LIST"
    fi
done < "$TMP_RAW"

rm -f "$TMP_RAW" "$TMP_PROJ_SEEN"

if [ ! -s "$TMP_LIST" ]
then
    log "Aucun identifiant valide après déduplication."
    exit 0
fi

############################################################################
# Filtrage selon présence du fichier de log et ancienneté > 10 min
############################################################################

> "$TMP_KEEP"

while read ID
do
    [ -z "$ID" ] && continue
    FOUND=0

    for FILE in $(find "$REPERTOIRE_LOG" -type f -name "*${ID}*" 2>/dev/null)
    do
        if find "$FILE" -mmin +10 | grep -q .
        then
            FOUND=1
            break
        fi
    done

    if [ $FOUND -eq 1 ]
    then
        echo "$ID" >> "$TMP_KEEP"
    fi

done < "$TMP_LIST"

if [ ! -s "$TMP_KEEP" ]
then
    log "Aucun identifiant valide après filtrage (aucun log inactif depuis plus de 10 min)."
    exit 0
fi

LISTE_IN=$(paste -sd, "$TMP_KEEP")
NB_IDS=$(wc -l < "$TMP_KEEP" | tr -d ' ')

############################################################################
# [ÉTAPE 1/3] Affichage des identifiants d'exécution concernés
############################################################################

log ""
log "[ÉTAPE 1/3] Identifiants d'exécution concernés"
log "--------------------------------------------------------------------------------"
log "Les jobs suivants sont en échec/bloqués et inactifs depuis plus de 10 min :"
while read ID
do
    [ -z "$ID" ] && continue
    log "  --> Job Execution ID : $ID"
done < "$TMP_KEEP"
log "Total : $NB_IDS exécution(s) retenue(s)."

############################################################################
# [ÉTAPE 2/3] Projets et séquences à redresser en base
############################################################################

sqlplus -s "${chaine_de_connexion_as}" <<EOF | \
sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
grep -v '^$' > "$TMP_PROJETS"

SET PAGESIZE 0
SET FEEDBACK OFF
SET HEADING OFF
SET VERIFY OFF
SET ECHO OFF
SET LINESIZE 32767
SET WRAP OFF

SELECT DISTINCT
    TRIM(gpat.CODE_PROJET) || '|' || TRIM(gpat.SEQUENCE_PROJET) || '|' || TRIM(TO_CHAR(CAST(gpat.SEQUENCE_PROJET AS INTEGER) - 1))
FROM
         batch_job_execution bje
    JOIN batch_job_instance         bji  ON bje.job_instance_id = bji.job_instance_id
    JOIN batch_job_execution_params bjep ON bje.job_execution_id = bjep.job_execution_id
    JOIN itf_gpat_projet_seq        gpat ON gpat.CODE_PROJET = bjep.STRING_VAL
WHERE
    bjep.key_name = 'codeProjet'
    and STATUS <> 'COMPLETED'
    and gpat.STATUT <> 'FINI'
    and bje.START_TIME < SYSDATE - INTERVAL '3' HOUR
    and bje.job_execution_id IN (${LISTE_IN})
;

EXIT;
EOF

> "$SQL_FILE"

log ""
log "[ÉTAPE 2/3] Projets et séquences à redresser en base"
log "--------------------------------------------------------------------------------"

if [ ! -s "$TMP_PROJETS" ]
then
    log "  (Aucun projet à redresser)"
else
    log_printf "%-15s | %-17s | %-17s | %-12s\n" "CODE PROJET" "SÉQUENCE ACTUELLE" "NOUVELLE SÉQUENCE" "STATUT CIBLE"
    log "----------------+-------------------+-------------------+-------------"
    while IFS='|' read -r CODE_PRJ SEQ_ACTU SEQ_NOUV
    do
        [ -z "$CODE_PRJ" ] && continue
        log_printf "%-15s | %-17s | %-17s | %-12s\n" "$CODE_PRJ" "$SEQ_ACTU" "$SEQ_NOUV" "FINI"
        echo "UPDATE itf_gpat_projet_seq SET STATUT = 'FINI', SEQUENCE_PROJET = '${SEQ_NOUV}' where CODE_PROJET = '${CODE_PRJ}' and STATUT='EN-COURS';" >> "$SQL_FILE"
    done < "$TMP_PROJETS"
fi

############################################################################
# [ÉTAPE 3/3] Actions prévues sur les fichiers
############################################################################

sqlplus -s "${chaine_de_connexion_as}" <<EOF | \
sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
grep -v '^$' > "$TMP_REP"

SET PAGESIZE 0
SET FEEDBACK OFF
SET HEADING OFF
SET VERIFY OFF
SET ECHO OFF

SELECT DISTINCT
    SUBSTR(TRIM(STRING_VAL), 5)
FROM
    batch_job_execution_params bjep
WHERE
    bjep.KEY_NAME = 'exchangeId'
    AND bjep.job_execution_id IN (${LISTE_IN})
;

EXIT;
EOF

> "$LISTE_ARCHIVE"
> "$LISTE_REJEU"

while read ELEMENT
do
    [ -z "$ELEMENT" ] && continue
    ELEMENT_REP_ENTREE=${ELEMENT%_*}
    FICHIER_REP_ENTREE=$(find "$REP_ENTREE" -type f -name "*${ELEMENT_REP_ENTREE}*" 2>/dev/null | head -1)
    FICHIER_REP_ENTREE_A_ARCHIVER=$(find "$REP_ENCOURS" -type d -name "*${ELEMENT%_*}*" 2>/dev/null | head -1)
    FICHIER_REP_ENCOURS=$(find "$REP_ENCOURS" -type d -name "*${ELEMENT}*" 2>/dev/null | head -1)

    if [ -n "$FICHIER_REP_ENTREE" ] && [ -n "$FICHIER_REP_ENCOURS" ]
    then
        [ -n "$FICHIER_REP_ENTREE_A_ARCHIVER" ] && echo "$FICHIER_REP_ENTREE_A_ARCHIVER" >> "$LISTE_ARCHIVE"
        continue
    fi

    if [ -n "$FICHIER_REP_ENCOURS" ]
    then
        echo "$FICHIER_REP_ENCOURS" >> "$LISTE_REJEU"
    fi

done < "$TMP_REP"

[ -s "$LISTE_ARCHIVE" ] && sort -u -o "$LISTE_ARCHIVE" "$LISTE_ARCHIVE"
[ -s "$LISTE_REJEU" ] && sort -u -o "$LISTE_REJEU" "$LISTE_REJEU"

log ""
log "[ÉTAPE 3/3] Actions prévues sur les fichiers"
log "--------------------------------------------------------------------------------"
log "  [REJEU] --> Répertoire remis en entrée ($REP_ENTREE) :"
if [ -s "$LISTE_REJEU" ]
then
    while read DOSSIER
    do
        [ -z "$DOSSIER" ] && continue
        log "      • $DOSSIER"
    done < "$LISTE_REJEU"
else
    log "      (Aucun)"
fi

log ""
log "  [ARCHIVAGE] --> Répertoire déplacé dans les archives ($REP_ARCHIVE) :"
log "      (Un fichier plus récent pour ce projet est déjà présent dans le répertoire d'entrée)"
if [ -s "$LISTE_ARCHIVE" ]
then
    while read DOSSIER
    do
        [ -z "$DOSSIER" ] && continue
        log "      • $DOSSIER"
    done < "$LISTE_ARCHIVE"
else
    log "      (Aucun)"
fi

############################################################################
# Demande de confirmation
############################################################################

if [ ! -s "$SQL_FILE" ] && [ ! -s "$LISTE_REJEU" ] && [ ! -s "$LISTE_ARCHIVE" ]
then
    log ""
    log "================================================================================"
    log "Aucune action (ni mise à jour SQL, ni déplacement de fichier) à effectuer."
    log "================================================================================"
    exit 0
fi

log ""
log "================================================================================"

if [ $AUTO_VALIDATION -eq 1 ]
then
    log "Mode automatique activé : exécution directe des actions sans demande de validation."
    log ""
    log "[EXÉCUTION]"
else
    log_printf "Voulez-vous exécuter ces actions (mises à jour SQL + déplacements fichiers) ? (y/n) : "
    read REPONSE
    echo "$REPONSE" >> "$LOG_FILE"

    case "$REPONSE" in
        y|Y)
            log ""
            log "[EXÉCUTION]"
            ;;
        *)
            log "Pas d'exécution. Traitement annulé."
            exit 0
            ;;
    esac
fi

############################################################################
# Exécution des déplacements de fichiers
############################################################################

log "  --> Déplacement des fichiers..."
NB_ACTIONS_FICHIERS=0

if [ -s "$LISTE_ARCHIVE" ]
then
    while read DOSSIER_ARCHIVE
    do
        [ -z "$DOSSIER_ARCHIVE" ] && continue
        if [ -d "$DOSSIER_ARCHIVE" ]
        then
            mv "$DOSSIER_ARCHIVE" "$REP_ARCHIVE"
            log "      [OK] Archivage : $(basename "$DOSSIER_ARCHIVE")"
            NB_ACTIONS_FICHIERS=$((NB_ACTIONS_FICHIERS + 1))
        fi
    done < "$LISTE_ARCHIVE"
fi

if [ -s "$LISTE_REJEU" ]
then
    while read DOSSIER_REJEU
    do
        [ -z "$DOSSIER_REJEU" ] && continue
        if [ -d "$DOSSIER_REJEU" ]
        then
            mv "${DOSSIER_REJEU}"/* "$REP_ENTREE" 2>/dev/null
            rmdir "${DOSSIER_REJEU}" 2>/dev/null
            log "      [OK] Rejeu : $(basename "$DOSSIER_REJEU")"
            NB_ACTIONS_FICHIERS=$((NB_ACTIONS_FICHIERS + 1))
        fi
    done < "$LISTE_REJEU"
fi

if [ $NB_ACTIONS_FICHIERS -eq 0 ]
then
    log "      (Aucun fichier à déplacer)"
fi

############################################################################
# Exécution des mises à jour SQL
############################################################################

if [ -s "$SQL_FILE" ]
then
    log "  --> Application des requêtes SQL..."
    sqlplus -s "${chaine_de_connexion_as}" <<EOF >> "$LOG_FILE" 2>&1
WHENEVER SQLERROR EXIT FAILURE

@${SQL_FILE}

COMMIT;

EXIT;
EOF

    if [ $? -eq 0 ]
    then
        log "      [OK] Mises à jour SQL validées (COMMIT)."
    else
        log "      [ERREUR] Échec lors de l'exécution des requêtes SQL."
        exit 1
    fi
else
    log "  --> Aucune mise à jour SQL à appliquer."
fi

log ""
log "================================================================================"
log "Traitement de reprise terminé avec succès."
log "Log complet : $LOG_FILE"
log "================================================================================"

exit 0
