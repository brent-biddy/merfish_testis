#!/usr/bin/env python3
"""
annotate_celltypes.py - Correlate every cell against reference cell type centroids.

Spearman-correlates each cell's profile with each cell type in a reference centroid table
(assets/reference), writing one obs column per cell type plus the per-cell call:

    obs["corr_<cell type>"]     standardized correlation, one column per cell type
    obs["cell_type_per_cell"]   the cell type a cell correlates with most strongly

This is the metric a report reads. It makes no cluster-level call: a cluster's identity is
read off the composition of these per-cell calls, which is a judgment made by a person.

Writes <outdir>/<sample>.annotate_celltypes.zarr, a gene overlap TSV, and a timing TSV.

The step name is in the filename so every artifact in the project is uniquely named
by sample and step. Nothing collides when files are staged flat, which is what lets a
report notebook glob one step's output without the workflow naming its inputs.

Usage:
    annotate_celltypes.py --sample testis_01 \\
        --path results/testis_01/cluster_spatialdata_gpu/testis_01.zarr \\
        --reference assets/reference/shami_human_testis_centroids.csv.gz \\
        --outdir results/testis_01/annotate_celltypes
"""

import argparse
from pathlib import Path

import numpy as np
import pandas as pd
import spatialdata
from scipy.spatial.distance import cdist
from scipy.stats import rankdata

from timer import timer, timing_summary


def parse_args():
    parser = argparse.ArgumentParser(
        description="Correlate every cell against reference cell type centroids"
    )
    parser.add_argument("--sample", required=True, help="Sample identifier")
    parser.add_argument(
        "--path", required=True, help="Clustered SpatialData zarr from cluster_spatialdata_gpu"
    )
    parser.add_argument(
        "--reference",
        required=True,
        help="Reference centroid CSV: genes x cell types, with a leading # comment block",
    )
    parser.add_argument(
        "--outdir",
        default=".",
        help="Directory to write <sample>.annotate_celltypes.zarr into (default: current directory)",
    )
    return parser.parse_args()


def main():
    args = parse_args()

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    output_path = outdir / f"{args.sample}.annotate_celltypes.zarr"

    print(f"Sample:    {args.sample}")
    print(f"Input:     {args.path}")
    print(f"Reference: {args.reference}")
    print(f"Output:    {output_path}")

    with timer("Read reference"):
        reference = pd.read_csv(args.reference, comment="#", index_col=0)

        # Genes are matched case-insensitively, so a mouse panel's Acta2 finds a human
        # reference's ACTA2. A few symbols differ only by case and collide once uppercased;
        # nothing says which row a panel gene meant, so they are dropped.
        reference.index = reference.index.str.upper()
        collided = reference.index.duplicated(keep=False)
        if collided.any():
            print(f"Dropped {int(collided.sum())} reference rows whose symbols differ only by case.")
            reference = reference[~collided]

    print(f"Reference: {reference.shape[0]:,} genes x {reference.shape[1]} cell types")

    with timer("Read zarr"):
        sdata = spatialdata.read_zarr(args.path)

    with timer("Extract table"):
        adata = sdata.tables["table"]

    print(f"Table:     {adata.n_obs:,} cells x {adata.n_vars:,} genes")

    panel = pd.Index(adata.var_names)
    in_reference = panel.str.upper().isin(reference.index)
    shared = panel[in_reference]

    print(f"Shared:    {len(shared)} of {len(panel)} panel genes are in the reference")

    pd.DataFrame({"gene": panel, "in_reference": in_reference}).to_csv(
        outdir / f"{args.sample}.gene_overlap.tsv", sep="\t", index=False
    )

    with timer("Correlate"):
        # layers["counts"]: X holds scaled values after clustering. Any layer would give the
        # same answer -- normalizing and log1p are monotone within a cell, so they leave the
        # gene ranks Spearman uses untouched -- but counts is the one that needs no caveat.
        expression = np.asarray(adata[:, shared].layers["counts"])

        # Ranked first, so cdist's Pearson is Spearman; it returns a distance, hence 1 - .
        # scipy.stats.spearmanrho says this in one call, but broadcasts to a
        # cells x types x genes intermediate -- 15 GiB at 50k cells against 0.6 here.
        correlation = pd.DataFrame(
            1 - cdist(
                rankdata(expression, axis=1),
                rankdata(reference.loc[shared.str.upper()].to_numpy().T, axis=1),
                metric="correlation",
            ),
            index=adata.obs_names,
            columns=reference.columns,
        )

    with timer("Standardize"):
        # Within each cell, because everything downstream compares cells with each other. A
        # cell's correlation to every type rises with how many genes it captured, so the raw
        # values are comparable within a cell and not between two. This cannot change which
        # type is largest, so the calls are the same either way.
        correlation = correlation.sub(correlation.mean(axis=1), axis=0).div(
            correlation.std(axis=1), axis=0
        )

    for cell_type in correlation.columns:
        adata.obs[f"corr_{cell_type}"] = correlation[cell_type].to_numpy()

    adata.obs["cell_type_per_cell"] = pd.Categorical(
        correlation.idxmax(axis=1), categories=list(reference.columns)
    )

    # Recorded so a report reads what this step used rather than restating it.
    adata.uns["annotation_reference"] = Path(args.reference).name
    adata.uns["annotation_shared_genes"] = len(shared)

    print("\nPer-cell calls:")
    print(adata.obs["cell_type_per_cell"].value_counts().to_string())

    with timer("Write zarr"):
        sdata.write(output_path, overwrite=True)

    timing_summary(outdir / f"{args.sample}.annotate_celltypes.timing.tsv")


if __name__ == "__main__":
    main()
