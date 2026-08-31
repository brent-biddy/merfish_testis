# Reports

One directory per render. Each holds the document, its figures and its deck together, and
is self-contained — the links inside a document are relative to its own directory, so a
directory can be renamed or moved without breaking anything in it.

The markdown and the figures are committed, being what GitHub renders. The deck is not,
being the same content in a format git cannot diff; rebuild it by re-rendering.

A render publishes into `reports/<notebook>_<run_id>[_<to>]/`, or into
`reports/<report_id>[_<to>]/` when `--report_id` is given; the format is appended only when
`--to` is, and a `render_sample` run nests one directory per sample inside that.

An unnamed render cannot displace an earlier one, the run id being unique per invocation —
so this directory accumulates: prune the renders not worth keeping before committing them.
`--report_id` is what gives that up: two runs naming the same report and format publish into
one directory, and `publishDir` copies over what is there.

## Index

Written by hand. A render cannot say what it was for, and a pipeline that wrote this file
would overwrite the part that matters. Add a row when you commit a report.

| Report | Samples | Segmentation | What it was for |
|--------|---------|--------------|-----------------|
| | | | |

<!-- Row format — the link points at the document inside the directory:
| [celltype_report_cellpose_cmp](celltype_report_cellpose_cmp/celltype_report.md) | testis_01 | cellpose | Comparison against the Vizgen boundaries before settling on one |
-->
