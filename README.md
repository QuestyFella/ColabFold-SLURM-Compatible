# ColabFold SLURM Workflow

This repository now includes a SLURM workflow for running ColabFold on Digital Research Alliance of Canada / FIR-style clusters. It converts a multi-record FASTA into SLURM array tasks, stages each task on the node-local `$SLURM_TMPDIR`, runs `colabfold_batch`, and copies results back to a selected output directory.

## Files

- `scripts/submit_colabfold_slurm.sh`: prepares split FASTA inputs and submits the SLURM array.
- `scripts/colabfold_slurm_job.sh`: job script executed by each SLURM array task.
- `scripts/split_fasta.py`: small dependency-free FASTA splitter.
- `og-complexes_grouped.fasta`: example multi-complex FASTA input.

## Cluster Setup

Install or load ColabFold so `colabfold_batch` is available inside the job. The submit script supports any of these approaches:

- `--modules "..."` to load cluster modules.
- `--env /path/to/venv` to activate a Python virtualenv.
- `--env conda_env_name` to activate a conda environment when `conda` is available.
- `--batch-cmd /path/to/colabfold_batch` to run an explicit command or wrapper.
- `--batch-cmd "apptainer exec --nv /path/to/colabfold.sif colabfold_batch"` for containerized runs.

On Alliance clusters, keep large outputs under `$SCRATCH` and let the job use `$SLURM_TMPDIR` for temporary node-local I/O.

For Apptainer/Singularity runs, the submit script defaults `--data` to `$SCRATCH/colabfold_data`, creates it, and bind-mounts it plus `$SLURM_TMPDIR` into the container. If model weights have not been downloaded yet, the first submission is automatically limited to one array task to avoid all tasks downloading the same weights concurrently.

The job wrapper also clears host TLS certificate variables for container runs and sets the container CA bundle path to `/etc/ssl/certs/ca-certificates.crt`. This prevents host paths such as `/etc/pki/tls/certs/ca-bundle.crt` from breaking model-weight downloads inside the container.

## Submit Example

```bash
scripts/submit_colabfold_slurm.sh \
  --input og-complexes_grouped.fasta \
  --output "$SCRATCH/colabfold_results" \
  --account def-yourpi \
  --time 04:00:00 \
  --cpus 4 \
  --mem 16G \
  --gres gpu:h100_2g.20gb:1 \
  --modules "StdEnv/2023 gcc cuda" \
  --env "$HOME/venvs/colabfold" \
  --extra-args "--model-type alphafold2_multimer_v3 --num-recycle 3 --num-models 5"
```

## FIR Apptainer Quick Start

The Python virtualenv route can fail on FIR because the Alliance wheelhouse may not provide all TensorFlow/JAX wheels required by ColabFold. The tested path is to use the official ColabFold container:

```bash
module load apptainer
mkdir -p "$SCRATCH/containers" "$SCRATCH/colabfold_data"
apptainer pull "$SCRATCH/containers/colabfold.sif" docker://ghcr.io/sokrypton/colabfold:1.6.1-cuda12
```

Run a cheap preflight before submitting the array:

```bash
unset REQUESTS_CA_BUNDLE SSL_CERT_FILE CURL_CA_BUNDLE
export APPTAINERENV_REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export APPTAINERENV_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export APPTAINERENV_CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
apptainer exec --nv "$SCRATCH/containers/colabfold.sif" \
  python -c 'import requests; r=requests.get("https://storage.googleapis.com", timeout=20); print("TLS_OK", r.status_code)'
```

Submit the full-quality run:

```bash
scripts/submit_colabfold_slurm.sh \
  --input og-complexes_grouped.fasta \
  --output "$SCRATCH/colabfold_results" \
  --account def-yourpi \
  --data "$SCRATCH/colabfold_data" \
  --array-limit 1 \
  --batch-cmd "apptainer exec --nv $SCRATCH/containers/colabfold.sif colabfold_batch" \
  --extra-args "--model-type alphafold2_multimer_v3 --num-recycle 3 --num-models 5"
```

Keep `--array-limit 1` for the first successful run so only one task downloads model weights into `$SCRATCH/colabfold_data`. After `$SCRATCH/colabfold_data/params` exists, use `--array-limit 2`, `--array-limit 4`, or omit it depending on queue pressure and allocation limits.

For a faster deadline run with lower accuracy, reduce the model count and recycle count:

```bash
scripts/submit_colabfold_slurm.sh \
  --input og-complexes_grouped.fasta \
  --output "$SCRATCH/colabfold_fast_results" \
  --account def-yourpi \
  --data "$SCRATCH/colabfold_data" \
  --array-limit 4 \
  --time 02:00:00 \
  --cpus 4 \
  --mem 24G \
  --batch-cmd "apptainer exec --nv $SCRATCH/containers/colabfold.sif colabfold_batch" \
  --extra-args "--model-type alphafold2_multimer_v3 --num-recycle 1 --num-models 1"
```

Use `--dry-run` first to verify the generated `sbatch` command:

```bash
scripts/submit_colabfold_slurm.sh \
  --input og-complexes_grouped.fasta \
  --output "$SCRATCH/colabfold_results" \
  --account def-yourpi \
  --dry-run
```

## Smaller MIG Jobs

The defaults are tuned for faster queueing with smaller jobs:

- `--gres gpu:h100_2g.20gb:1`
- `--time 04:00:00`
- `--cpus 4`
- `--mem 16G`

If FIR exposes a different MIG GRES name, check available GPU resources with `sinfo -o "%G"` and override the request with `--gres`, for example `--gres gpu:h100_1g.10gb:1` or the exact string shown by SLURM.

## FASTA Array Behavior

By default each FASTA record becomes one array task. Increase task size with `--records-per-file N` if you want each GPU job to process multiple sequences.

The included example contains complex inputs using `:` chain separators, which ColabFold supports for multimer predictions.

## MSA and Network Notes

`colabfold_batch` normally uses MMseqs2 for MSA generation unless you pass a different mode in `--extra-args`. Compute nodes on some Alliance systems may not have outbound internet access. If remote MMseqs2 cannot be reached, use one of these approaches:

- Pass `--extra-args "--msa-mode single_sequence ..."` for no MSA search.
- Precompute A3M files and run with ColabFold custom MSA inputs.
- Configure a local ColabFold/MMseqs database and pass the relevant `colabfold_batch` options through `--extra-args`.

If AlphaFold parameter weights are stored in a shared directory, pass it with `--data /path/to/params` or export `COLABFOLD_DATA`.

For the first container run on FIR, prefer:

```bash
scripts/submit_colabfold_slurm.sh \
  --input og-complexes_grouped.fasta \
  --output "$SCRATCH/colabfold_results" \
  --account def-yourpi \
  --batch-cmd "apptainer exec --nv $SCRATCH/containers/colabfold.sif colabfold_batch" \
  --extra-args "--model-type alphafold2_multimer_v3 --num-recycle 3 --num-models 5"
```

This will use `$SCRATCH/colabfold_data` for downloaded weights. After that directory contains `params/`, you can add `--array-limit 2` or omit `--array-limit` for more concurrency.

## Monitoring

The submit script creates per-run files under `.slurm/<job-name>_<timestamp>/`:

- `inputs/`: split FASTA files used by the array.
- `inputs.txt`: one FASTA path per array task.
- `logs/`: SLURM stdout/stderr files.

Results are copied to `<output>/<split-fasta-name>/` after each task completes.

Useful FIR monitoring commands:

```bash
squeue -u "$USER"
LATEST_LOG_DIR="$(ls -td .slurm/colabfold_*/logs | head -1)"
tail -f "$LATEST_LOG_DIR"/*.out "$LATEST_LOG_DIR"/*.err
du -sh "$SCRATCH/colabfold_data" "$SCRATCH/colabfold_results" 2>/dev/null
```

If a job fails, inspect only the newest log directory so old failed runs do not get mixed into the diagnosis:

```bash
LATEST_LOG_DIR="$(ls -td .slurm/colabfold_*/logs | head -1)"
tail -n 120 "$LATEST_LOG_DIR"/*.err
```
