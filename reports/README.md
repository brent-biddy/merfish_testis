# Reports

One directory per render. Each holds the document, its figures and its deck together, and
is self-contained — the links inside a document are relative to its own directory, so a
directory can be renamed or moved without breaking anything in it.

The markdown and the figures are committed, being what GitHub renders. The deck is not,
being the same content in a format git cannot diff; rebuild it by re-rendering.

A render publishes into `reports/<notebook>_<run_id>/`, or into `reports/<report_id>/`
when `--report_id` is given. Nothing overwrites anything, which also means this directory
accumulates: prune the renders not worth keeping before committing them.

## Index

Written by hand. A render cannot say what it was for, and a pipeline that wrote this file
would overwrite the part that matters. Add a row when you commit a report.

| Report | Samples | Segmentation | What it was for |
|--------|---------|--------------|-----------------|
| | | | |

<!-- Row format — the link points at the document inside the directory:
| [celltype_report_cellpose_cmp](celltype_report_cellpose_cmp/celltype_report.md) | testis_01 | cellpose | Comparison against the Vizgen boundaries before settling on one |
-->
