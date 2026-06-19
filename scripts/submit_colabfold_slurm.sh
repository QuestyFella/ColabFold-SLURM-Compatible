#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Submit ColabFold FASTA jobs as a SLURM array.

Required:
  --input FASTA              Input FASTA file
  --output DIR               Final output directory, preferably under $SCRATCH

Common Alliance/FIR options:
  --account ACCOUNT          SLURM account, for example def-PI_NAME
  --time HH:MM:SS            Walltime (default: 04:00:00)
  --cpus N                   CPUs per task (default: 4)
  --mem SIZE                 Memory per task (default: 16G)
  --gres GRES                GPU request (default: gpu:h100_2g.20gb:1)
  --partition PARTITION      Optional SLURM partition
  --array-limit N            Max simultaneously running array tasks

ColabFold environment:
  --modules "MODULES"        Modules to load inside the job
  --env ENV                  Virtualenv path, conda env name, or shell setup file
  --batch-cmd CMD            colabfold_batch command, path, or container wrapper
  --data DIR                 ColabFold/AlphaFold parameter data directory
                             (container default: $SCRATCH/colabfold_data)
  --extra-args "ARGS"        Extra arguments appended to colabfold_batch

Input splitting:
  --records-per-file N       FASTA records per array task (default: 1)

Other:
  --job-name NAME            SLURM job name (default: colabfold)
  --dry-run                  Print sbatch command without submitting
  -h, --help                 Show this help

Example:
  scripts/submit_colabfold_slurm.sh \
    --input og-complexes_grouped.fasta \
    --output "$SCRATCH/colabfold_results" \
    --account def-yourpi \
    --modules "StdEnv/2023 gcc cuda" \
    --env "$HOME/venvs/colabfold" \
    --gres gpu:h100_2g.20gb:1 \
    --extra-args "--model-type alphafold2_multimer_v3 --num-recycle 3"
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SLURM_WRAPPER="${SCRIPT_DIR}/colabfold_slurm_job.sh"
SPLITTER="${SCRIPT_DIR}/split_fasta.py"

INPUT_FASTA=""
OUTPUT_DIR=""
ACCOUNT=""
PARTITION=""
TIME="04:00:00"
CPUS="4"
MEM="16G"
GRES="gpu:h100_2g.20gb:1"
ARRAY_LIMIT=""
MODULES=""
ENV_NAME=""
BATCH_CMD="colabfold_batch"
DATA_DIR=""
EXTRA_ARGS=""
RECORDS_PER_FILE="1"
JOB_NAME="colabfold"
DRY_RUN="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input) INPUT_FASTA="$2"; shift 2 ;;
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    --account) ACCOUNT="$2"; shift 2 ;;
    --partition) PARTITION="$2"; shift 2 ;;
    --time) TIME="$2"; shift 2 ;;
    --cpus) CPUS="$2"; shift 2 ;;
    --mem) MEM="$2"; shift 2 ;;
    --gres) GRES="$2"; shift 2 ;;
    --array-limit) ARRAY_LIMIT="$2"; shift 2 ;;
    --modules) MODULES="$2"; shift 2 ;;
    --env) ENV_NAME="$2"; shift 2 ;;
    --batch-cmd) BATCH_CMD="$2"; shift 2 ;;
    --data) DATA_DIR="$2"; shift 2 ;;
    --extra-args) EXTRA_ARGS="$2"; shift 2 ;;
    --records-per-file) RECORDS_PER_FILE="$2"; shift 2 ;;
    --job-name) JOB_NAME="$2"; shift 2 ;;
    --dry-run) DRY_RUN="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "${INPUT_FASTA}" || -z "${OUTPUT_DIR}" ]]; then
  usage >&2
  exit 2
fi

if [[ ! -f "${INPUT_FASTA}" ]]; then
  echo "Input FASTA does not exist: ${INPUT_FASTA}" >&2
  exit 2
fi

IS_CONTAINER_RUN="0"
if [[ " ${BATCH_CMD} " == *" apptainer "* || " ${BATCH_CMD} " == *" singularity "* ]]; then
  IS_CONTAINER_RUN="1"
fi

if [[ "${IS_CONTAINER_RUN}" == "1" && -z "${DATA_DIR}" ]]; then
  if [[ -z "${SCRATCH:-}" ]]; then
    echo "Container runs need --data DIR when SCRATCH is not set" >&2
    exit 2
  fi
  DATA_DIR="${SCRATCH}/colabfold_data"
fi

if [[ -n "${DATA_DIR}" ]]; then
  mkdir -p "${DATA_DIR}"
  if [[ ! -w "${DATA_DIR}" ]]; then
    echo "ColabFold data directory is not writable: ${DATA_DIR}" >&2
    exit 2
  fi
fi

RUN_ID="$(date +%Y%m%d_%H%M%S)"
WORK_DIR="${REPO_ROOT}/.slurm/${JOB_NAME}_${RUN_ID}"
SPLIT_DIR="${WORK_DIR}/inputs"
LOG_DIR="${WORK_DIR}/logs"
INPUT_LIST="${WORK_DIR}/inputs.txt"
mkdir -p "${SPLIT_DIR}" "${LOG_DIR}" "${OUTPUT_DIR}"

python3 "${SPLITTER}" "${INPUT_FASTA}" "${SPLIT_DIR}" \
  --records-per-file "${RECORDS_PER_FILE}" \
  --list-file "${INPUT_LIST}"

TASK_COUNT="$(wc -l < "${INPUT_LIST}" | tr -d ' ')"
if [[ "${TASK_COUNT}" == "0" ]]; then
  echo "No FASTA tasks were generated" >&2
  exit 2
fi

ARRAY_SPEC="1-${TASK_COUNT}"
if [[ -n "${ARRAY_LIMIT}" ]]; then
  ARRAY_SPEC="${ARRAY_SPEC}%${ARRAY_LIMIT}"
elif [[ -n "${DATA_DIR}" && ! -d "${DATA_DIR}/params" && "${TASK_COUNT}" != "1" ]]; then
  ARRAY_LIMIT="1"
  ARRAY_SPEC="${ARRAY_SPEC}%${ARRAY_LIMIT}"
  echo "No AlphaFold params found in ${DATA_DIR}/params; limiting first run to one array task."
  echo "After params download, rerun with --array-limit 2 or omit --array-limit."
fi

SBATCH_ARGS=(
  --job-name "${JOB_NAME}"
  --array "${ARRAY_SPEC}"
  --cpus-per-task "${CPUS}"
  --mem "${MEM}"
  --time "${TIME}"
  --gres "${GRES}"
  --output "${LOG_DIR}/%x_%A_%a.out"
  --error "${LOG_DIR}/%x_%A_%a.err"
  --export "ALL,INPUT_LIST=${INPUT_LIST},RESULTS_DIR=${OUTPUT_DIR},COLABFOLD_MODULES=${MODULES},COLABFOLD_ENV=${ENV_NAME},COLABFOLD_BATCH=${BATCH_CMD},COLABFOLD_DATA=${DATA_DIR},COLABFOLD_EXTRA_ARGS=${EXTRA_ARGS}"
)

if [[ -n "${ACCOUNT}" ]]; then
  SBATCH_ARGS+=(--account "${ACCOUNT}")
fi
if [[ -n "${PARTITION}" ]]; then
  SBATCH_ARGS+=(--partition "${PARTITION}")
fi

echo "Prepared ${TASK_COUNT} SLURM task(s)"
echo "Input list: ${INPUT_LIST}"
echo "Logs: ${LOG_DIR}"
if [[ -n "${DATA_DIR}" ]]; then
  echo "ColabFold data: ${DATA_DIR}"
fi

if [[ "${DRY_RUN}" == "1" ]]; then
  printf 'sbatch'
  printf ' %q' "${SBATCH_ARGS[@]}" "${SLURM_WRAPPER}"
  printf '\n'
  exit 0
fi

sbatch "${SBATCH_ARGS[@]}" "${SLURM_WRAPPER}"
