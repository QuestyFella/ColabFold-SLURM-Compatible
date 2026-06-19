#!/usr/bin/env bash
#SBATCH --job-name=colabfold
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=12:00:00
#SBATCH --gres=gpu:1

set -euo pipefail

if [[ -z "${INPUT_LIST:-}" ]]; then
  echo "INPUT_LIST must point to a newline-delimited list of FASTA files" >&2
  exit 2
fi

if [[ -z "${RESULTS_DIR:-}" ]]; then
  echo "RESULTS_DIR must point to the final output directory" >&2
  exit 2
fi

if [[ ! -f "${INPUT_LIST}" ]]; then
  echo "INPUT_LIST does not exist: ${INPUT_LIST}" >&2
  exit 2
fi

if [[ -n "${COLABFOLD_MODULES:-}" ]]; then
  if ! type module >/dev/null 2>&1 && [[ -f /etc/profile.d/modules.sh ]]; then
    # shellcheck disable=SC1091
    source /etc/profile.d/modules.sh
  fi
  # shellcheck disable=SC2086
  module load ${COLABFOLD_MODULES}
fi

if [[ -n "${COLABFOLD_ENV:-}" ]]; then
  if [[ -f "${COLABFOLD_ENV}/bin/activate" ]]; then
    # Python virtualenv path.
    # shellcheck disable=SC1091
    source "${COLABFOLD_ENV}/bin/activate"
  elif [[ -f "${COLABFOLD_ENV}" ]]; then
    # Shell setup file, for example a container/module activation script.
    # shellcheck disable=SC1090
    source "${COLABFOLD_ENV}"
  elif command -v conda >/dev/null 2>&1; then
    # Conda environment name.
    # shellcheck disable=SC1091
    source "$(conda info --base)/etc/profile.d/conda.sh"
    conda activate "${COLABFOLD_ENV}"
  else
    echo "COLABFOLD_ENV is set but could not be activated: ${COLABFOLD_ENV}" >&2
    exit 2
  fi
fi

COLABFOLD_BATCH="${COLABFOLD_BATCH:-colabfold_batch}"
read -r -a COLABFOLD_BATCH_CMD <<< "${COLABFOLD_BATCH}"
if ! command -v "${COLABFOLD_BATCH_CMD[0]}" >/dev/null 2>&1; then
  echo "Could not find ${COLABFOLD_BATCH_CMD[0]}. Load a module, activate an env, or set COLABFOLD_BATCH." >&2
  exit 127
fi

mapfile -t FASTA_FILES < "${INPUT_LIST}"
TASK_ID="${SLURM_ARRAY_TASK_ID:-1}"
INDEX=$((TASK_ID - 1))

if (( INDEX < 0 || INDEX >= ${#FASTA_FILES[@]} )); then
  echo "SLURM_ARRAY_TASK_ID=${TASK_ID} is outside INPUT_LIST length ${#FASTA_FILES[@]}" >&2
  exit 2
fi

INPUT_FASTA="${FASTA_FILES[$INDEX]}"
if [[ ! -f "${INPUT_FASTA}" ]]; then
  echo "Input FASTA does not exist: ${INPUT_FASTA}" >&2
  exit 2
fi

JOB_ROOT="${SLURM_TMPDIR:-${TMPDIR:-/tmp}}/colabfold_${SLURM_JOB_ID:-local}_${TASK_ID}"
WORK_INPUT="${JOB_ROOT}/input"
WORK_OUTPUT="${JOB_ROOT}/output"
mkdir -p "${WORK_INPUT}" "${WORK_OUTPUT}" "${RESULTS_DIR}"

FASTA_BASENAME="$(basename "${INPUT_FASTA}")"
cp "${INPUT_FASTA}" "${WORK_INPUT}/${FASTA_BASENAME}"

export TMPDIR="${SLURM_TMPDIR:-${TMPDIR:-/tmp}}"
export XLA_PYTHON_CLIENT_PREALLOCATE="${XLA_PYTHON_CLIENT_PREALLOCATE:-false}"
export XLA_PYTHON_CLIENT_MEM_FRACTION="${XLA_PYTHON_CLIENT_MEM_FRACTION:-0.85}"
export TF_FORCE_UNIFIED_MEMORY="${TF_FORCE_UNIFIED_MEMORY:-1}"
export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"

echo "Running ${COLABFOLD_BATCH} on ${INPUT_FASTA}"
echo "Temporary work directory: ${JOB_ROOT}"
echo "Final results directory: ${RESULTS_DIR}"

COLABFOLD_ARGS=()
if [[ -n "${COLABFOLD_DATA:-}" ]]; then
  COLABFOLD_ARGS+=(--data "${COLABFOLD_DATA}")
fi
if [[ -n "${COLABFOLD_EXTRA_ARGS:-}" ]]; then
  read -r -a EXTRA_ARGS <<< "${COLABFOLD_EXTRA_ARGS}"
  COLABFOLD_ARGS+=("${EXTRA_ARGS[@]}")
fi

"${COLABFOLD_BATCH_CMD[@]}" "${WORK_INPUT}/${FASTA_BASENAME}" "${WORK_OUTPUT}" "${COLABFOLD_ARGS[@]}"

DESTINATION="${RESULTS_DIR}/$(basename "${INPUT_FASTA}" .fasta)"
mkdir -p "${DESTINATION}"
cp -R "${WORK_OUTPUT}/." "${DESTINATION}/"

echo "Copied results to ${DESTINATION}"
