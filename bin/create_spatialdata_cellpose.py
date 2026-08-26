#!/usr/bin/env python3
"""
create_spatialdata_cellpose.py - Convert a cellpose re-segmentation of a MERSCOPE region
to a SpatialData Zarr store.

Reads two directories. The MERSCOPE region directory supplies the mosaic images and the
detected transcripts, which the re-segmentation does not replace. The VPT output directory
supplies the cells: the count matrix, the cell metadata, and the boundary polygons.

Both are named on the command line. Which segmentation a store came from is not
recoverable from its contents, so the VPT directory is recorded into the table.

The store is the same shape as the one create_spatialdata.py writes, so the clustering,
annotation and report steps read it unchanged.

Writes <outdir>/<sample>.zarr plus a timing TSV.

Usage:
    create_spatialdata_cellpose.py --sample b2r0_cellpose \\
        --path data/raw/MsTestis_B2/region_0 \\
        --vpt_path data/cellpose/MsTestis_B2/region_0/Cellpose \\
        --outdir results/b2r0_cellpose/create_spatialdata_cellpose
"""

import argparse
from pathlib import Path

import pandas as pd
from spatialdata_io import merscope

from timer import timer, timing_summary

# The function default, pinned here and recorded into the table below so downstream steps
# read which plane was loaded instead of assuming it.
Z_LAYER = 3

# Keyed by the names merscope()'s vpt_outputs dict takes. VPT prefixes its outputs with the
# segmentation method, so the directory form of vpt_outputs finds the boundaries and misses
# both CSVs; naming all three explicitly sidesteps the prefix.
VPT_FILES = {
    "cell_by_gene": "cellpose_cell_by_gene.csv",
    "cell_metadata": "cellpose_cell_metadata.csv",
    "cell_boundaries": "cellpose_micron_space.parquet",
}


def vpt_outputs(vpt_dir, staging_dir):
    """Return the vpt_outputs dict merscope() reads, reordering the metadata if needed.

    merscope() hands the counts and the metadata straight to AnnData, which requires their
    indexes to match exactly; VPT does not guarantee it writes them in the same order. A
    reordered copy is written to staging_dir rather than over the input.

    A missing boundary file is an error here. merscope() only warns and loads no polygons,
    leaving a store that clusters and annotates perfectly well and has nothing to draw a
    tissue figure from, which is not a thing to discover in the report step.
    """
    paths = {key: vpt_dir / name for key, name in VPT_FILES.items()}

    missing = [str(path) for path in paths.values() if not path.exists()]
    if missing:
        raise FileNotFoundError(
            f"Missing VPT output(s) in {vpt_dir}: {', '.join(missing)}. Expected the files "
            f"a cellpose VPT run writes; a watershed run names its boundaries "
            f"watershed_micron_space.parquet instead."
        )

    # Only the ids are needed, and cellpose_cell_by_gene.csv is hundreds of MB of counts.
    counts_index = pd.read_csv(
        paths["cell_by_gene"], index_col=0, usecols=[0], dtype=str
    ).index
    metadata = pd.read_csv(paths["cell_metadata"], index_col=0, dtype=str)

    if not counts_index.equals(metadata.index):
        print(f"Reordering cell metadata to match the counts ({len(counts_index):,} cells).")
        staging_dir.mkdir(parents=True, exist_ok=True)
        paths["cell_metadata"] = staging_dir / VPT_FILES["cell_metadata"]
        metadata.loc[counts_index].to_csv(paths["cell_metadata"])

    return paths


def parse_args():
    parser = argparse.ArgumentParser(
        description="Convert a cellpose re-segmentation of a MERSCOPE region to a "
                    "SpatialData Zarr store"
    )
    parser.add_argument("--sample", required=True, help="Sample identifier")
    parser.add_argument(
        "--path",
        required=True,
        help="MERSCOPE region output directory, for the images and transcripts",
    )
    parser.add_argument(
        "--vpt_path",
        required=True,
        help="VPT cellpose output directory, for the cells, counts and boundaries",
    )
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
    print(f"VPT:     {args.vpt_path}")
    print(f"Output:  {output_path}")
    print(f"Z-layer: {Z_LAYER}")

    region_dir = Path(args.path)
    vpt_dir = Path(args.vpt_path)
    paths = vpt_outputs(vpt_dir, outdir / "staged_vpt")

    # Elements are named <slide>_<region>. Both halves are passed rather than defaulted:
    # the slide would otherwise be the run directory's name, and the region the name of
    # whatever directory was read.
    with timer("Read MERSCOPE"):
        sdata = merscope(
            path=region_dir,
            vpt_outputs=paths,
            slide_name=args.sample,
            region_name=region_dir.name,
            z_layers=Z_LAYER,
        )

    print("\nElements:")
    for name in sdata.images:
        print(f"  image   {name}")
    for name in sdata.labels:
        print(f"  labels  {name}")
    for name in sdata.shapes:
        print(f"  shapes  {name}")
    for name in sdata.points:
        print(f"  points  {name}")

    # Record the sample id in the object; the workflow stages files under indexed names, so
    # the filename is not a reliable source for it downstream. The segmentation is recorded
    # beside it because two stores of the same region are otherwise indistinguishable.
    for name, table in sdata.tables.items():
        table.obs["sample"] = args.sample
        table.uns["z_layer"] = Z_LAYER
        table.uns["segmentation"] = "cellpose"
        table.uns["vpt_path"] = str(vpt_dir.resolve())
        print(f"  table   {name}: {table.n_obs:,} cells x {table.n_vars:,} genes")

    with timer("Write Zarr"):
        sdata.write(output_path, overwrite=True)

    timing_summary(outdir / f"{args.sample}.create_spatialdata_cellpose.timing.tsv")


if __name__ == "__main__":
    main()
