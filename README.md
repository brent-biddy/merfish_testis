# merfish_testis

Analysis of Vizgen MERSCOPE (MERFISH) data from human testis.

## Setup

There is no project-specific environment. Everything in `bin/` runs in the shared
`python_spatial` container, the same image the other pipeline repos use:

```bash
apptainer exec docker://babiddy755/python_spatial:1.2.0 bin/create_spatialdata.py --help
```

## Running the pipeline

Two entry scripts, and they interoperate.

```bash
# One step at a time, while the analysis is being worked out.
nextflow run steps.nf -profile wsl --step create_spatialdata --samplesheet assets/samplesheet.csv

# The Vizgen path chained end to end, as one run.
nextflow run main.nf -profile wsl --samplesheet assets/samplesheet.csv
```

Steps are selected by name; `steps.nf` chains nothing, so any step can be rerun on its own.
`main.nf` calls the same module workflows in order — an example of the shape rather than a
settled analysis. Because every step writes the next one's samplesheet into `results/<run_id>/`,
a chained run leaves the same breadcrumbs a stepwise one does: run the whole thing, then re-run
a single step from what it wrote.

`nextflow run .` resolves to `main.nf`, so the default answer to "run this repo" is an
analysis rather than a usage error.

### Profiles

The defaults apply unconditionally, from `conf/defaults.config`, and a profile states only
its difference. There is deliberately no `standard` profile: Nextflow only auto-applies that
when `-profile` is omitted entirely, so naming one would mean `-profile wsl` silently dropped
the defaults with it.

| Invocation | What you get |
|---|---|
| *(none)* | local executor, the container, no GPU access |
| `-profile wsl` | the above, plus how a `label 'gpu'` process reaches a card under WSL2 |
| `-profile oscer` | SLURM, scratch and OURdisk paths, the GPU queue |

The cost is worth knowing: forgetting `-profile oscer` on the cluster no longer fails — it
runs everything on the login node.

Add `-stub` to check wiring without doing the work.

### How artifacts are named

Every artifact is `<sample>.<step>.<ext>` — `u2os_test.cluster_spatialdata_gpu.zarr`, not
`u2os_test.zarr`. Nothing then collides when files are staged flat: not two samples, and not
one step's input with its own output.

That is what lets a report notebook ask for a specific step —
`glob("*.annotate_celltypes.zarr")` — instead of `*.zarr` and hoping, and it is why the render
step can stage everything into one directory rather than numbered `input*/` subdirectories.

A `--group_by` run qualifies the stem rather than extending it —
`<sample>.<column>.centroids.h5ad` — so `.centroids` stays the last token before the extension
and one glob takes both.

Output publishes beside the code, so a result sits next to the analysis that produced it.
Each invocation gets its own directory under `results/`, named by a timestamp `run_id`:

```
<repo>/results/<run_id>/    published step output, not committed
<repo>/reports/<name>/    one directory per render, committed and pushed
```

The work dir and the image cache stay out of the repo, being large, churny, and
reproducible: under `~/merfish_testis_work/` by default, and
`/scratch/$USER/merfish_testis_work/` on `oscer`. Scratch deletes files 14 days after they
are created no matter how recently they were read, so nothing durable can live there — on
`oscer` the image cache sits on OURdisk for that reason.

Because runs never share an output directory, a `-stub` run cannot overwrite a real run's
results. Pass `--run_id <name>` to pin the directory, which `-resume` needs across
launches.

On `oscer` the repo itself lives on OURdisk, which is permanent and large but **never
backed up**. The code and `reports/` are safe because they are pushed to GitHub, and
`results/` is reproducible from them; `data/raw/` is neither, and is worth a second copy.

## Workflow

Steps run in this order. This table is the ordering contract — there are no numeric
filename prefixes.

| Step | Script | Samplesheet | Input | Output |
|------|--------|-------------|-------|--------|
| 1 | `bin/create_spatialdata.py` | `sample, path` | MERSCOPE region directory | `<sample>.<step>.zarr` |
| 1a | `bin/prep_cellpose_vpt.py` | `sample, path, cellpose_path` | MERSCOPE region directory and a merged bespoke cellpose segmentation | `cellpose_*.{csv,parquet}` |
| 1b | `bin/create_spatialdata_cellpose.py` | `sample, path, vpt_path` | MERSCOPE region directory and VPT cellpose output, from a VPT run or from step 1a | `<sample>.<step>.zarr` |
| 2 | `bin/cluster_spatialdata_gpu.py` | `sample, path` | zarr from step 1 or 1b | `<sample>.<step>.zarr` |
| 3 | `bin/annotate_celltypes.py` | `sample, path` | zarr from step 2 | `<sample>.<step>.zarr` |
| 4 | `bin/create_centroids.py` | `sample, path` | zarr from step 2 or 3 | `<sample>.centroids.h5ad` |
| 5 | `--notebook`, e.g. `notebooks/celltype_report.qmd` | `sample`, plus whatever path columns the notebook globs | for `celltype_report.qmd`: zarr from step 3 and centroids from step 4 | `reports/<notebook>_<run_id>[_<to>]/`, one directory per render — `render_sample` nests one per sample inside it |

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

### 1a. prep_cellpose_vpt

Converts a cellpose segmentation that was **not** run through VPT into the three files
step 1b reads, so a store built from it comes out of the same reader as every other
sample. Only needed for the lab's own cellpose pipeline — `area_cellpose.py` per FOV,
`merge.py` to stitch — which writes numpy arrays rather than CSVs and a parquet.

It reads the merged segmentation directory:

```
labels.npy                    (7, height, width) uint32 raw labels, full mosaic pixels
<sample>-cellp-label-map.npz  raw label -> compact cell id, indexed by label - 1
<sample>-cell-by-gene.npz     counts, row 0 is background
<sample>-slicee.pkl           per-label bounding boxes, from ndi.find_objects
cell-coms.npz                 (z, y, x) centre per cell, mosaic pixels
cell-vols.npz                 voxels per cell
```

None of the index conventions are recoverable from the files themselves, so they are
documented in the script's docstring and taken from `merge.py`:

```
compact_id = label_map[raw_label - 1]    0 means the label is absent
counts     = cbg[compact_id]             row 0 is background, not a cell
centre     = cell_coms[compact_id - 1]
volume     = cell_vols[compact_id - 1]
```

**`label_map` is indexed by `label - 1`, not by the label.** `merge.py` builds it over
`ndi.find_objects` output, whose element *i* describes label *i+1*. Indexing by the label
happens to agree wherever labels are contiguous and is off by one across every gap, which
is silent — it gives a cell its neighbour's counts. The step therefore checks the join
before writing anything: each label's voxels in the raster must equal the volume
`merge.py` recorded for the cell it maps to, exactly, or the run fails.

The segmentation is 3D over seven z planes and a store holds one, so **each cell's
boundary is taken from the plane it covers most**. Fixing a single plane instead would
leave the ~3.5% of cells centred near the top or bottom of the section with counts and a
centre but no polygon. The cost is that a tissue figure mixes depths rather than showing
one optical section; which plane each cell came from is written to the metadata and lands
in the table as `obs["z_plane"]`. Every polygon is written with `ZIndex` 0 regardless,
because that is the only value `merscope()` keeps.

Coordinates are converted with the region's own `micron_to_mosaic_pixel_transform.csv`
rather than a restated pixel size. Gene names come from the region's `cell_by_gene.csv`
header, since the counts array is bare integers — that the blank codewords carry ~20x
lower counts than real genes is what confirms the order applies.

```bash
nextflow run steps.nf -profile oscer --step prep_cellpose_vpt \
    --samplesheet assets/samplesheet_cellpose_prep.csv

nextflow run steps.nf -profile oscer --step create_spatialdata_cellpose \
    --samplesheet <run>/results/prep_cellpose_vpt_samplesheet.csv
```

The handoff sheet it writes is already in step 1b's `sample, path, vpt_path` shape,
forwarding the region unchanged and naming this step's output as the VPT directory.

The label raster is about 7 GB per plane and the step holds one plane, the counts and the
traced polygons at once, so `nextflow.config` gives the process 64 GB on `oscer` rather
than letting the retry ladder find it. It is too large for the default memory request.

### 1b. create_spatialdata_cellpose

An alternative to step 1 for a region that has been re-segmented with cellpose, writing a
store of the same shape so steps 2 onward read it unchanged. Either step produces a `.zarr`
and a handoff sheet; a run uses one or the other, not both.

`--vpt_path` takes either a real VPT output directory or step 1a's output, which is
written in the same shape for exactly that reason.

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
nextflow run steps.nf -profile wsl --step create_spatialdata_cellpose \
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
`wsl` binds the WSL2 driver directory — and is set in the site config, not the module. The
process declares `label 'gpu'`; each site answers it.

```bash
nextflow run steps.nf -profile wsl --step cluster_spatialdata_gpu \
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
nextflow run steps.nf -profile wsl --step annotate_celltypes \
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
(`<sample>.<column>.centroids.h5ad`, and its own handoff sheet), so they publish beside a
sweep run rather than displacing it and the step can be re-run for each grouping you want.

A grouping that is a union of v1 clusters needs no run at all — sums are additive, so add
the rows.

```bash
nextflow run steps.nf -profile wsl --step create_centroids \
    --samplesheet <run>/results/cluster_spatialdata_gpu_samplesheet.csv

nextflow run steps.nf -profile wsl --step create_centroids --group_by cell_type \
    --samplesheet <run>/results/cluster_spatialdata_gpu_samplesheet.csv
```

### 5. render_cohort and render_sample

Renders the notebook named by `--notebook`. Terminal steps — nothing consumes them.

Two steps, one workflow. The step name says how rows are grouped — `render_cohort` renders
every row in one pass, `render_sample` renders one per row — and `--to` says which of the
formats the notebook declares comes out of it. Omitting `--to` renders every declared format
in one pass.

They are separate because the right grouping differs by format. A markdown document is
navigated by file, so fifteen samples in one page is an enormous scroll where a directory of
fifteen pages is browsable; a deck is read linearly in a meeting, where one file with fifteen
sections works and fifteen files is miserable.

```bash
--step render_cohort --to pptx    # one deck, every sample
--step render_sample --to gfm     # one page per sample
```

The notebook needs no conditional for this: it globs what was staged, so a cohort render finds
every sample and loops over them while a per-sample render finds one and loops once.

The step knows nothing about what it is rendering. It requires only a `sample` column and
stages every other column's path, one per directory; which of them a notebook wants, and
what it does with them, is the notebook's own business. **A new report is therefore a new
notebook and no Nextflow at all** — copy an existing `.qmd`, edit it, and render it.

Staging is the input contract: the workflow drops each samplesheet path into its own
flat beside the notebook and the notebook globs the step it wants, taking each
sample's id from inside its object rather than from the staged filename. One directory per
file because two samples publish their stores under the same name, and a step that names
no columns cannot pattern its way around the collision. Adding a sample needs no edit to
the notebook.

`notebooks/celltype_report.qmd` is the report this pipeline has today: a cohort deck and a
GitHub-readable document with a section per sample — its QC, the clustering, the per-cell
calls, what they compose to per cluster, and the calls on tissue. The rest of this section
describes that notebook rather than the step.

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

These are the only steps that publish into the repo. They write `reports/`, not
`results/<run_id>/`, because their product is the one that is source-controlled: the
markdown and its figures are committed, being what GitHub renders, and the deck is
gitignored, being the same content in a format git cannot diff.

Each render gets its own directory, `reports/<notebook>_<run_id>_<to>/`, holding the
document, the figure directory and the deck together. Quarto writes all three into
`--output-dir` and the document's links are relative to it, so the directory moves as a unit
and renders on GitHub wherever it sits. The notebook leads the name so a listing groups a
report type together; the run id names the render invocation, not the results tree it read —
those are different runs, since a render takes a samplesheet pointing at some earlier run's
published paths, and what a render was built from is in that samplesheet. The format is part
of it because the two packagings of one notebook are different artifacts produced by separate
runs, and sharing a name put the per-sample pages inside the cohort render's own directory;
it is appended only when `--to` is given, so a render of every declared format has no suffix.
A `render_sample` run nests one directory per sample inside that.
`--report_id` replaces the notebook and run id when a render deserves a name of its own —
the format is still appended:

```bash
# One deck over the cohort.
nextflow run steps.nf -profile wsl --step render_cohort --to pptx --run_id cellpose_cmp \
    --notebook notebooks/celltype_report.qmd \
    --samplesheet <run>/results/create_centroids_samplesheet.csv
# -> reports/celltype_report_cellpose_cmp_pptx/celltype_report.pptx

# The same samples as one browsable page each, from a notebook whose prose was rewritten
# for that comparison, under a name of its own.
nextflow run steps.nf -profile wsl --step render_sample --to gfm \
    --report_id cellpose_cmp_pages \
    --notebook notebooks/celltype_report_cellpose.qmd \
    --samplesheet <run>/results/create_centroids_samplesheet.csv
# -> reports/cellpose_cmp_pages_gfm/<sample>/celltype_report_cellpose.md
```

The second renders a copy of the first notebook, with its prose rewritten for that
comparison. Commentary about one render belongs in the notebook it renders, next to the
figure it is about — which is why a variant is a copied `.qmd` rather than a note injected
from outside. The cost is that a fix to a shared figure has to land in each copy.

One collision is left on purpose: the same format in both modes — `render_cohort --to gfm`
alongside `render_sample --to gfm` — still shares a directory, since the grouping is not in
the name. The pairing above avoids it; making it impossible would mean naming the grouping
too, for a case nothing needs yet.

Because no two renders share a directory, nothing overwrites anything — which also means
`reports/` accumulates. Prune the ones not worth keeping before committing.

`reports/README.md` indexes the ones that were kept, and is what GitHub shows when anyone
browses the directory. It is written by hand: a render cannot say what it was for, and a
pipeline that wrote the file would overwrite the part worth reading. Add a row when you
commit a report.

Figure resolution is set per format in the notebook's frontmatter — 144 dpi for the
committed markdown, read in a ~900px column, and 200 for the projected deck. It cannot go
back into `rcParams`, which runs after quarto and would override both.

Two segmentations of one sample are compared by giving them distinct sample ids —
`testis_01_vizgen` and `testis_01_cellpose` — in one samplesheet. Both readers write the
id into `table.obs["sample"]`, and the notebook takes each section's id from inside the
object, so the two land as neighbouring sections of a single document with no edit to the
notebook and no collision in `results/`.

`error: true` is not set, so a failing cell fails the render rather than leaving an error
slide. Still worth inspecting the deck: `unzip -q reports/<dir>/celltype_report.pptx` and
check the slide count and titles.

## Layout

```
main.nf          a chained analysis; `nextflow run .` resolves here
steps.nf         step dispatch, for working one step at a time
nextflow.config  params, and which site profiles exist
conf/            defaults.config applies always; wsl and oscer state their difference
bin/             all executable code
modules/         one file per step: its process and its workflow
notebooks/       report notebooks
assets/          sample sheets, and the pptx template and lua filter a render needs
assets/reference/  cell type centroids to annotate against; see each file's header
data/raw/        raw instrument output (not committed)
results/<run_id>/  published step output (not committed)
reports/README.md  hand-written index of the renders worth keeping
reports/<notebook>_<run_id>[_<to>]/  one directory per render: markdown and figures
                 committed, the deck not; render_sample nests one dir per sample
```

`reports/` is the only output that is committed. Everything else under the repo is
gitignored and reproducible from `bin/` + `assets/` + `data/raw/`.
