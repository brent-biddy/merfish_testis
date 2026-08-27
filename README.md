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

Output publishes beside the code, so a result sits next to the analysis that produced it.
Each invocation gets its own directory under `results/`, named by a timestamp `run_id`:

```
<repo>/results/<run_id>/    published step output, not committed
```

The work dir and the image cache stay out of the repo, being large, churny, and
reproducible: under `~/merfish_testis_work/` on `local`, and
`/scratch/$USER/merfish_testis_work/` on `oscer`. Scratch deletes files 14 days after they
are created no matter how recently they were read, so nothing durable can live there — on
`oscer` the image cache sits on OURdisk for that reason.

Because runs never share an output directory, a `-stub` run cannot overwrite a real run's
results. Pass `--run_id <name>` to pin the directory, which `-resume` needs across
launches.

On `oscer` the repo itself lives on OURdisk, which is permanent and large but **never
backed up**. The code is safe because it is pushed to GitHub, and `results/` is
reproducible from it; `data/raw/` is neither, and is worth a second copy.

## Workflow

Steps run in this order. This table is the ordering contract — there are no numeric
filename prefixes.

| Step | Script | Samplesheet | Input | Output |
|------|--------|-------------|-------|--------|
| 1 | `bin/create_spatialdata.py` | `sample, path` | MERSCOPE region directory | `<sample>.zarr` |
| 1b | `bin/create_spatialdata_cellpose.py` | `sample, path, vpt_path` | MERSCOPE region directory and its VPT cellpose output | `<sample>.zarr` |
| 2 | `bin/cluster_spatialdata_gpu.py` | `sample, path` | zarr from step 1 or 1b | `<sample>.zarr` |
| 3 | `bin/annotate_celltypes.py` | `sample, path` | zarr from step 2 | `<sample>.zarr` |
| 4 | `bin/create_centroids.py` | `sample, path` | zarr from step 2 or 3 | `<sample>.centroids.h5ad` |
| 5 | `notebooks/celltype_report.qmd` | `sample, path, centroid_path` | zarr from step 3 and centroids from step 4 | `celltype_report.{pptx,md}` |

### 1. create_spatialdata

Reads a raw MERSCOPE output directory and writes it as a SpatialData Zarr store. The
sample id is written into `table.obs["sample"]` and the loaded z-plane into
`table.uns["z_layer"]`, so downstream steps read both from the object.

The store holds the mosaic image as a multiscale pyramid, the transcripts as 3D points,
the cell boundaries as polygons, and the count matrix as the table.

Elements are named `<sample>_<region dir>_<element>`, from the sample id and the raw
region directory's own name — never from the staged copy below, so staging a sample
leaves its element names exactly where reading it directly would.

Two things about a region directory are fixed before the read, into a staged copy that
symlinks everything it is not changing so the instrument output is never touched. A
`cell_metadata.csv` written in a different row order than `cell_by_gene.csv` is
reordered, since the reader hands both straight to AnnData. And boundaries written the
pre-VPT way — a `cell_boundaries/` directory of per-FOV HDF5 files rather than
`cell_boundaries.parquet` — are converted, at z-index 0, the only plane the reader keeps.

A region with neither form of boundary is an error here. The reader only warns and loads
no polygons, leaving a store that clusters and annotates perfectly well and has nothing to
draw a tissue figure from, which is not a thing to discover in step 5.

The script is a plain CLI and runs outside Nextflow unchanged:

```bash
apptainer exec docker://babiddy755/python_spatial:1.2.0 \
    python bin/create_spatialdata.py \
        --sample testis_01 \
        --path data/raw/testis_01 \
        --outdir results/testis_01/create_spatialdata
```

### 1b. create_spatialdata_cellpose

An alternative to step 1 for a region that has been re-segmented with cellpose, writing a
store of the same shape so steps 2 onward read it unchanged. Either step produces a `.zarr`
and a handoff sheet; a run uses one or the other, not both.

It reads two directories, because a re-segmentation replaces only the cells. The MERSCOPE
region directory supplies the mosaic images and the detected transcripts. The VPT output
directory supplies the count matrix, the cell metadata and the boundary polygons:

```
<region>/Cellpose/cellpose_cell_by_gene.csv
                  cellpose_cell_metadata.csv
                  cellpose_micron_space.parquet
```

`merscope()` reads this natively through its `vpt_outputs` argument, so nothing is
converted. VPT prefixes its outputs with the segmentation method, which is why all three
files are named explicitly rather than by pointing the reader at the directory — the
directory form finds the boundaries and misses both CSVs. A watershed run names its
boundaries `watershed_micron_space.parquet`; this step reads the cellpose ones.

The boundaries are already polygons in micron space, so unlike the pre-VPT HDF5 form step 1
converts, there is nothing to build. A missing boundary file is an error here for the same
reason it is there: the reader only warns.

Which segmentation a store came from is not recoverable from its contents, so
`table.uns["segmentation"]` and `table.uns["vpt_path"]` record it. Give the two stores
different sample ids if you want to keep both — they are otherwise indistinguishable in a
report, and element names are built from the sample id.

```bash
nextflow run main.nf -profile local --step create_spatialdata_cellpose \
    --samplesheet assets/samplesheet_cellpose.csv
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

### 3. annotate_celltypes

Spearman-correlates every cell against each cell type in a reference centroid table,
writing one `corr_<cell type>` obs column plus `cell_type_per_cell`, the type a cell
correlates with most strongly. Genes are matched case-insensitively, so a mouse panel's
`Acta2` finds a human reference's `ACTA2`; which panel genes were found is written to
`<sample>.gene_overlap.tsv`.

Correlations are standardized within each cell, because everything downstream compares
cells with each other and a cell's correlation to every type rises with how many genes it
captured. That cannot change which type is largest, so the calls are unaffected.

**This step makes no cluster-level call.** A cluster's identity is read off the composition
of these per-cell calls, which is a judgment made by a person — the reference reports where
a type would land, not that it was found.

`--reference` selects the table; it defaults to the one in `assets/reference`.

```bash
nextflow run main.nf -profile local --step annotate_celltypes \
    --samplesheet <run>/results/cluster_spatialdata_gpu_samplesheet.csv
```

### 4. create_centroids

Builds one row per cluster from the clustered zarr, at every resolution in the sweep, so
later steps and reports never open the counts matrix. Writes a small h5ad holding summed
CP10K in `X` and summed raw counts in `layers["counts"]`, with `n_cells` per row.

Everything is a **sum, not a mean**, because sums are additive: the profile of any union
of clusters is the row-wise sum of its members, and `n_cells` sums with it. The reference
centroids in `assets/reference` are `ln(mean + 1)`, so the comparable value built from
this store is `log1p(X / n_cells)`.

Its own step rather than part of step 2: Nextflow hashes the task script, so folding it in
would make a change to the centroid recipe re-run the GPU Leiden sweep.

`--group_by <column>` sums over one named obs column instead of the sweep — cell type,
once a later step has written it. Those runs are named for the column
(`<sample>.centroids_<column>.h5ad`, and its own handoff sheet), so they publish beside a
sweep run rather than displacing it and the step can be re-run for each grouping you want.

A grouping that is a union of v1 clusters needs no run at all — sums are additive, so add
the rows.

```bash
nextflow run main.nf -profile local --step create_centroids \
    --samplesheet <run>/results/cluster_spatialdata_gpu_samplesheet.csv

nextflow run main.nf -profile local --step create_centroids --group_by cell_type \
    --samplesheet <run>/results/cluster_spatialdata_gpu_samplesheet.csv
```

### 5. celltype_report

A cohort deck and a GitHub-readable document from one notebook, with a section per
sample: its QC, the clustering, the per-cell calls, what they compose to per cluster, and
the calls on tissue. A terminal step — nothing consumes it.

Staging is the input contract: the workflow drops every sample's zarr and its centroid
store beside the notebook and it globs them, taking each sample's id from inside its
object rather than from the staged filename. Adding a sample needs no edit to the
notebook.

It reads step 4's handoff sheet, which forwards both the zarr it consumed and the
centroids it wrote. The centroids are what the cluster similarity figure correlates, so
the notebook never opens a counts matrix.

Two knobs live at the top of the notebook, both judgments rather than computations. The
resolution the whole document reads, since the sweep writes twenty and one has to be
picked; and the share of a cluster's cells one type must take for the cluster to be
settled on it. A cluster below that is called Ambiguous rather than named on a split
vote, and gets a slide of its own laying out the evidence.

Clusters carry a second, render-only numbering: `v2` is position down the dendrogram, so
neighbouring numbers are transcriptionally adjacent and the heatmaps read as a block
diagonal. Figures are labelled `v1 (v2)`. **`v1` is what a call is written against** — it
is fixed in the object, while `v2` moves whenever the clustering or the gene set changes.

```bash
nextflow run main.nf -profile local --step celltype_report \
    --samplesheet <run>/results/create_centroids_samplesheet.csv
```

`error: true` is not set, so a failing cell fails the render rather than leaving an error
slide. Still worth inspecting the deck: `unzip -q celltype_report.pptx` and check the
slide count and titles.

## Layout

```
main.nf          step dispatch
nextflow.config  profiles: local (workstation), oscer (slurm)
bin/             all executable code
modules/         one file per step: its process and its workflow
notebooks/       report notebooks
assets/          sample sheets, and the pptx template and lua filter a render needs
assets/reference/  cell type centroids to annotate against; see each file's header
data/raw/        raw instrument output (not committed)
results/<run_id>/  published step output (not committed)
```

Everything under `results/` is gitignored and reproducible from `bin/` + `assets/` +
`data/raw/`.
