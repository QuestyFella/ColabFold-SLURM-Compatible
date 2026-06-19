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

## Submit Example

```bash
scripts/submit_colabfold_slurm.sh \
  --input og-complexes_grouped.fasta \
  --output "$SCRATCH/colabfold_results" \
  --account def-yourpi \
  --time 12:00:00 \
  --cpus 8 \
  --mem 32G \
  --gres gpu:1 \
  --modules "StdEnv/2023 gcc cuda" \
  --env "$HOME/venvs/colabfold" \
  --extra-args "--model-type alphafold2_multimer_v3 --num-recycle 3 --num-models 5"
```

Use `--dry-run` first to verify the generated `sbatch` command:

```bash
scripts/submit_colabfold_slurm.sh \
  --input og-complexes_grouped.fasta \
  --output "$SCRATCH/colabfold_results" \
  --account def-yourpi \
  --dry-run
```

## FASTA Array Behavior

By default each FASTA record becomes one array task. Increase task size with `--records-per-file N` if you want each GPU job to process multiple sequences.

The included example contains complex inputs using `:` chain separators, which ColabFold supports for multimer predictions.

## MSA and Network Notes

`colabfold_batch` normally uses MMseqs2 for MSA generation unless you pass a different mode in `--extra-args`. Compute nodes on some Alliance systems may not have outbound internet access. If remote MMseqs2 cannot be reached, use one of these approaches:

- Pass `--extra-args "--msa-mode single_sequence ..."` for no MSA search.
- Precompute A3M files and run with ColabFold custom MSA inputs.
- Configure a local ColabFold/MMseqs database and pass the relevant `colabfold_batch` options through `--extra-args`.

If AlphaFold parameter weights are stored in a shared directory, pass it with `--data /path/to/params` or export `COLABFOLD_DATA`.

## Monitoring

The submit script creates per-run files under `.slurm/<job-name>_<timestamp>/`:

- `inputs/`: split FASTA files used by the array.
- `inputs.txt`: one FASTA path per array task.
- `logs/`: SLURM stdout/stderr files.

Results are copied to `<output>/<split-fasta-name>/` after each task completes.
