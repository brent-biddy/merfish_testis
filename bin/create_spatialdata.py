#!/usr/bin/env python3
"""
create_spatialdata.py - Convert a Vizgen MERSCOPE output directory to a SpatialData Zarr store.

Reads a MERSCOPE region directory (cell_by_gene.csv, cell_metadata.csv, the
cell boundary parquet, the detected transcripts, and the mosaic images) and
writes it out as a SpatialData Zarr store. No cells or genes are filtered here;
filtering happens in later steps.

Later steps read the Zarr store rather than the MERSCOPE directory.

Writes <outdir>/<sample>.zarr plus a timing TSV.

Usage:
    create_spatialdata.py --sample testis_01 \\
        --path data/raw/testis_01 \\
        --outdir results/testis_01/create_spatialdata
"""

import argparse
from pathlib import Path

import pandas as pd
from spatialdata_io import merscope

from timer import timer, timing_summary

# The function default, pinned here and recorded into the table below so downstream
# steps read which plane was loaded instead of assuming it.
Z_LAYER = 3


def aligned_region_dir(region_dir, staging_dir):
    """Return a region directory whose cell_metadata.csv matches cell_by_gene.csv row order.

    merscope() hands both CSVs straight to AnnData, which requires their indexes to match
    exactly. Some MERSCOPE versions write the two files in different orders, and the load
    then fails with "Index of obs must match index of X". Returns the input unchanged when
    the orders already agree.
    """
    counts = pd.read_csv(region_dir / "cell_by_gene.csv", index_col=0, dtype=str)
    metadata = pd.read_csv(region_dir / "cell_metadata.csv", index_col=0, dtype=str)

    if counts.index.equals(metadata.index):
        return region_dir

    print(f"Reordering cell_metadata.csv to match cell_by_gene.csv ({len(counts):,} cells).")

    # Symlink the rest of the region — the mosaic images are far too large to copy — and
    # write only the reordered metadata, so the instrument output is never modified.
    staging_dir.mkdir(parents=True, exist_ok=True)
    for entry in region_dir.iterdir():
        if entry.name != "cell_metadata.csv":
            link = staging_dir / entry.name
            if not link.exists():
                link.symlink_to(entry.resolve())

    metadata.loc[counts.index].to_csv(staging_dir / "cell_metadata.csv")
    return staging_dir


def parse_args():
    parser = argparse.ArgumentParser(
        description="Convert a Vizgen MERSCOPE output directory to a SpatialData Zarr store"
    )
    parser.add_argument("--sample", required=True, help="Sample identifier")
    parser.add_argument("--path", required=True, help="MERSCOPE region output directory")
    parser.add_argument(
        "--outdir",
        default=".",
        help="Directory to write <sample>.zarr into (default: current directory)",
    )
    return parser.parse_args()


def main():
    args = parse_args()

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    output_path = outdir / f"{args.sample}.zarr"

    print(f"Sample:  {args.sample}")
    print(f"Input:   {args.path}")
    print(f"Output:  {output_path}")
    print(f"Z-layer: {Z_LAYER}")

    region_dir = aligned_region_dir(Path(args.path), outdir / "aligned_region")

    # Element names are prefixed with the slide name, so pass the sample id to keep them
    # predictable rather than tied to the run directory name.
    with timer("Read MERSCOPE"):
        sdata = merscope(path=region_dir, slide_name=args.sample, z_layers=Z_LAYER)

    print("\nElements:")
    for name in sdata.images:
        print(f"  image   {name}")
    for name in sdata.labels:
        print(f"  labels  {name}")
    for name in sdata.shapes:
        print(f"  shapes  {name}")
    for name in sdata.points:
        print(f"  points  {name}")

    # Record the sample id in the object; the workflow stages files under indexed names,
    # so the filename is not a reliable source for it downstream.
    for name, table in sdata.tables.items():
        table.obs["sample"] = args.sample
        table.uns["z_layer"] = Z_LAYER
        print(f"  table   {name}: {table.n_obs:,} cells x {table.n_vars:,} genes")

    with timer("Write Zarr"):
        sdata.write(output_path, overwrite=True)

    timing_summary(outdir / f"{args.sample}.create_spatialdata.timing.tsv")


if __name__ == "__main__":
    main()
