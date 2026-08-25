# merfish_testis

Analysis of Vizgen MERSCOPE (MERFISH) data from human testis.

## Setup

There is no project-specific environment. Everything in `bin/` runs in the shared
`python_spatial` container, the same image the other pipeline repos use:

```bash
apptainer exec docker://babiddy755/python_spatial:1.2.0 bin/create_spatialdata.py --help
```

## Running the pipeline

Steps are selected by name; there is no chaining inside Nextflow, so any step can be
rerun on its own.

```bash
nextflow run main.nf -profile local --step create_spatialdata --samplesheet assets/samplesheet.csv
```

`-profile` is required. There is no `standard` profile — the one Nextflow would fall back
to when it is omitted — so a run without it gets no container and no executor settings.
Use `local` on a workstation and `oscer` on the cluster.

Add `-stub` to check wiring without doing the work.

Each invocation gets its own directory, named by a timestamp `run_id`:

```
~/merfish_testis_out/<run_id>/results     published output
~/merfish_testis_out/<run_id>/work        dropped on success
~/merfish_testis_out/apptainer_cache      shared across runs
```

Nothing is published into the repo. Because runs never share an output directory, a
`-stub` run cannot overwrite a real run's results. Pass `--run_id <name>` to pin the
directory, which `-resume` needs across launches. On `oscer` the root is
`/scratch/$USER/merfish_testis_out` instead.

## Workflow

Steps run in this order. This table is the ordering contract — there are no numeric
filename prefixes.

| Step | Script | Samplesheet | Input | Output |
|------|--------|-------------|-------|--------|
| 1 | `bin/create_spatialdata.py` | `sample, path` | MERSCOPE region directory | `<sample>.zarr` |
| 2 | `bin/cluster_spatialdata_gpu.py` | `sample, path` | zarr from step 1 | `<sample>.zarr` |
| 3 | `bin/create_centroids.py` | `sample, path` | zarr from step 2 | `<sample>.centroids.h5ad` |

### 1. create_spatialdata

Reads a raw MERSCOPE output directory and writes it as a SpatialData Zarr store. The
sample id is written into `table.obs["sample"]` and the loaded z-plane into
`table.uns["z_layer"]`, so downstream steps read both from the object.

The store holds the mosaic image as a multiscale pyramid, the transcripts as 3D points,
the cell boundaries as polygons, and the count matrix as the table.

The script is a plain CLI and runs outside Nextflow unchanged:

```bash
apptainer exec docker://babiddy755/python_spatial:1.2.0 \
    python bin/create_spatialdata.py \
        --sample testis_01 \
        --path data/raw/testis_01 \
        --outdir results/testis_01/create_spatialdata
```

### 2. cluster_spatialdata_gpu

Filters cells, normalizes, runs PCA / neighbors / UMAP, and sweeps Leiden resolutions on
the GPU with rapids-singlecell. The sweep is 0.1 to 2.0 in steps of 0.1, set in the script.

Each resolution leaves two obs columns. `leiden_res_<r>_v0` is Leiden's own labelling,
kept so a cluster can be traced back. `leiden_res_<r>_v1` renumbers those clusters `1..k`
by descending cell count, so cluster 1 is always the largest. **v1 is what everything
downstream means by a cluster id** — Leiden's own numbers say nothing about size and are
not comparable between two resolutions, so a cluster named in a figure or a hand-written
annotation is named by its v1 id.

There is no highly-variable-gene selection — a MERFISH panel is a few hundred curated
markers, so every gene is used. Genes are not filtered either.

This step needs a CUDA GPU. Driver passthrough differs by profile — `oscer` uses `--nv`,
`local` binds the WSL2 driver directory — and is set in `nextflow.config`, not the module.

```bash
nextflow run main.nf -profile local --step cluster_spatialdata_gpu \
    --samplesheet <run>/results/create_spatialdata_samplesheet.csv
```

The samplesheet is the handoff sheet step 1 wrote.

### 3. create_centroids

Builds one row per cluster from the clustered zarr, at every resolution in the sweep, so
later steps and reports never open the counts matrix. Writes a small h5ad holding summed
CP10K in `X` and summed raw counts in `layers["counts"]`, with `n_cells` per row.

Everything is a **sum, not a mean**, because sums are additive: the profile of any union
of clusters is the row-wise sum of its members, and `n_cells` sums with it. The reference
centroids in `assets/reference` are `ln(mean + 1)`, so the comparable value built from
this store is `log1p(X / n_cells)`.

Its own step rather than part of step 2: Nextflow hashes the task script, so folding it in
would make a change to the centroid recipe re-run the GPU Leiden sweep.

`--group_by <column>` sums over one named obs column instead of the sweep. A grouping that
is a union of v1 clusters needs no run at all — sums are additive, so add the rows.

```bash
nextflow run main.nf -profile local --step create_centroids \
    --samplesheet <run>/results/cluster_spatialdata_gpu_samplesheet.csv
```

## Layout

```
main.nf          step dispatch
nextflow.config  profiles: local (workstation), oscer (slurm)
bin/             all executable code
modules/         one file per step: its process and its workflow
assets/          sample sheets
assets/reference/  cell type centroids to annotate against; see each file's header
data/raw/        raw instrument output (not committed)
```

Run outputs live outside the repo, under `~/merfish_testis_out/<run_id>/`.
