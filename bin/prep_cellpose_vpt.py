#!/usr/bin/env python3
"""
prep_cellpose_vpt.py - Convert a bespoke cellpose segmentation of a MERSCOPE region to
the three VPT output files create_spatialdata_cellpose.py reads.

Not a VPT run: this is the lab's own cellpose pipeline (area_cellpose.py per FOV, merge.py
to stitch), which writes numpy arrays where merscope() wants CSVs and a parquet. Writing
those here keeps one reader downstream.

Inputs, all in the merged segmentation directory:

    labels.npy                  (7, height, width) uint32 raw labels, full mosaic pixels
    <sample>-cellp-label-map.npz    raw label -> compact cell id, indexed by label - 1
    <sample>-cell-by-gene.npz   counts, row 0 is background
    <sample>-slicee.pkl         per-label bounding boxes, merge.py's find_objects output
    cell-coms.npz               (z, y, x) centre per cell, mosaic pixels
    cell-vols.npz               voxels per cell

None of the index conventions are recoverable from the files, so, from merge.py:

    compact_id = label_map[raw_label - 1]    0 means the label is absent
    counts     = cbg[compact_id]             row 0 is background, not a cell
    centre     = cell_coms[compact_id - 1]
    volume     = cell_vols[compact_id - 1]

label_map is indexed by `label - 1` because merge.py builds it over ndi.find_objects
output, whose element i describes label i + 1. Indexing by the label instead is off by one
wherever a label is absent, silently: it gives a cell its neighbour's counts. check_volumes
is what catches that before anything is written.

The segmentation is 3D over 7 planes and a store holds one, so each cell's boundary comes
from the plane it covers most; a cell centred near the top or bottom of the section still
gets one, and which plane lands in obs["z_plane"].

Writes <outdir>/cellpose_{cell_by_gene.csv,cell_metadata.csv,micron_space.parquet} plus a
timing TSV. Point create_spatialdata_cellpose.py --vpt_path at <outdir>.

Usage:
    prep_cellpose_vpt.py --sample b2r0_cellpose \\
        --path data/raw/MsTestis_B2/region_0 \\
        --cellpose_path data/cellpose/b2r0-051223 \\
        --outdir results/b2r0_cellpose/prep_cellpose_vpt
"""

import argparse
import pickle
from pathlib import Path

import geopandas as gpd
import numpy as np
import pandas as pd
import shapely
from shapely.geometry import MultiPolygon, Polygon
from skimage.measure import find_contours

from timer import timer, timing_summary

# merscope() keeps only ZIndex 0 out of whatever the boundary file holds, so every polygon
# is written at 0 whichever plane it was taken from.
BOUNDARY_Z_INDEX = 0

# Mosaic z spacing. The MERSCOPE records the pixel size but not this, so it cannot be read
# from the region; merge.py's anisotropy constant assumes the same. Only the volume column
# depends on it: wrong here, volumes scale and nothing else moves.
Z_STEP_MICRONS = 1.5

# The names create_spatialdata_cellpose.py looks for: a Vizgen cellpose delivery's, where
# all three carry the method. A stock VPT run prefixes only the boundaries.
OUTPUT_NAMES = {
    "cell_by_gene": "cellpose_cell_by_gene.csv",
    "cell_metadata": "cellpose_cell_metadata.csv",
    "cell_boundaries": "cellpose_micron_space.parquet",
}

# Written by merge.py under the sample's own prefix, which is not the sample id this
# pipeline uses -- matched by suffix instead of named.
LABEL_MAP_SUFFIX = "-cellp-label-map.npz"
COUNTS_SUFFIX = "-cell-by-gene.npz"


def find_one(directory, suffix):
    """Return the single file in directory ending in suffix."""
    matches = sorted(directory.glob(f"*{suffix}"))
    if len(matches) != 1:
        raise FileNotFoundError(
            f"Expected exactly one *{suffix} in {directory}, found {len(matches)}. "
            f"merge.py writes one per merged segmentation."
        )
    return matches[0]


def load_segmentation(cellpose_dir):
    """Read the merged segmentation arrays, checking they agree on how many cells there are."""
    labels = np.load(cellpose_dir / "labels.npy", mmap_mode="r")
    label_map = np.load(find_one(cellpose_dir, LABEL_MAP_SUFFIX))["label_map"]
    counts = np.load(find_one(cellpose_dir, COUNTS_SUFFIX))["cbg"]
    centres = np.load(cellpose_dir / "cell-coms.npz")["cell_coms"]
    volumes = np.load(cellpose_dir / "cell-vols.npz")["cell_vols"]

    n_cells = int(label_map.max())
    print(f"Labels:  {labels.shape} {labels.dtype}")
    print(f"Cells:   {n_cells:,}")

    if not (len(centres) == len(volumes) == n_cells):
        raise ValueError(
            f"Cell counts disagree: label_map.max()={n_cells:,}, "
            f"cell-coms={len(centres):,}, cell-vols={len(volumes):,}."
        )
    if len(counts) != n_cells + 1:
        raise ValueError(
            f"{find_one(cellpose_dir, COUNTS_SUFFIX).name} has {len(counts):,} rows; "
            f"expected {n_cells + 1:,} -- one per cell plus row 0 for background."
        )
    return labels, label_map, counts, centres, volumes


def plane_areas(labels, n_labels):
    """Return an (n planes, n labels + 1) array of pixels per raw label per z plane.

    A plane at a time, not a cell at a time: the raster is tens of GB, and per-plane reads
    it in the order it is stored.
    """
    areas = np.zeros((labels.shape[0], n_labels + 1), dtype=np.int64)
    for z in range(labels.shape[0]):
        plane = np.asarray(labels[z])
        # bincount takes intp, so it casts the whole plane -- twice the plane again on top
        # of the plane itself. In blocks that cast is a sixteenth, for identical counts.
        for block in np.array_split(plane.ravel(), 16):
            areas[z] += np.bincount(block, minlength=n_labels + 1)
        print(f"  z={z}: {int((areas[z][1:] > 0).sum()):,} labels present")
    return areas


def check_volumes(areas, label_map, volumes):
    """Fail unless each label's voxels match the volume recorded for the cell it maps to."""
    present = np.nonzero(label_map)[0]          # index into label_map, i.e. label - 1
    from_raster = areas[:, present + 1].sum(axis=0)
    recorded = volumes[label_map[present] - 1]

    mismatches = int((from_raster != recorded).sum())
    if mismatches:
        raise ValueError(
            f"{mismatches:,} of {len(present):,} cells have a raster volume that differs "
            f"from cell-vols.npz. The label map, the raster and the volumes are not from "
            f"one merge.py run, or its indexing has changed."
        )
    print(f"Volume check: {len(present):,} cells match cell-vols.npz exactly.")


def pixel_to_micron_transform(region_dir):
    """Return the affine taking mosaic pixels to microns, inverting the region's own."""
    path = region_dir / "images" / "micron_to_mosaic_pixel_transform.csv"
    if not path.exists():
        raise FileNotFoundError(
            f"No {path.name} in {path.parent}. It is what puts the segmentation's pixel "
            f"coordinates into the micron space the transcripts and images use."
        )
    micron_to_pixel = pd.read_csv(path, sep=r"\s+", header=None).values
    return np.linalg.inv(micron_to_pixel)


def to_microns(rows, columns, transform):
    """Map mosaic pixel (row, column) arrays to micron (x, y) arrays."""
    pixels = np.stack([columns, rows, np.ones_like(columns)])
    x, y, _ = transform @ pixels
    return x, y


def cell_polygon(mask, y_offset, x_offset, transform):
    """Return the MultiPolygon of a boolean cell mask, in microns, or None.

    Padded before tracing so a cell touching its bounding box still closes. Several pieces
    on one plane trace as several contours; under three vertices is not a ring.
    """
    contours = find_contours(np.pad(mask, 1), 0.5)

    parts = []
    for contour in contours:
        if len(contour) < 3:
            continue
        rows = contour[:, 0] - 1 + y_offset
        columns = contour[:, 1] - 1 + x_offset
        x, y = to_microns(rows, columns, transform)
        parts.append(Polygon(np.column_stack([x, y])))

    if not parts:
        return None

    # A hole traces as its own contour, so a cell with one comes back as nested shells:
    # invalid, and about half again too large. make_valid turns those into interior rings.
    shape = shapely.make_valid(MultiPolygon(parts))

    # MultiPolygon even for one piece: merscope() calls MultiPolygon(x.geoms) on every row,
    # and a bare Polygon has no .geoms. make_valid returns one whenever the cell is single.
    polygons = [part for part in getattr(shape, "geoms", [shape])
                if part.geom_type == "Polygon"]
    if not polygons:
        return None
    return MultiPolygon(polygons)


def build_boundaries(labels, slices, label_map, best_plane, transform):
    """Trace one polygon per cell, each from the plane it covers most, a plane at a time."""
    entity_ids = []
    geometries = []
    planes = []

    for z in range(labels.shape[0]):
        on_this_plane = np.nonzero(best_plane == z)[0]        # label - 1
        if not len(on_this_plane):
            continue

        print(f"  z={z}: tracing {len(on_this_plane):,} cells")
        plane = np.asarray(labels[z])

        for index in on_this_plane:
            _, rows, columns = slices[index]
            mask = plane[rows, columns] == index + 1
            polygon = cell_polygon(mask, rows.start, columns.start, transform)
            if polygon is None:
                continue

            entity_ids.append(int(label_map[index]))
            geometries.append(polygon)
            planes.append(z)

    boundaries = gpd.GeoDataFrame(
        {"EntityID": entity_ids, "ZIndex": BOUNDARY_Z_INDEX, "Geometry": geometries},
        geometry="Geometry",
    )
    return boundaries, pd.Series(planes, index=entity_ids, name="z_plane")


def parse_args():
    parser = argparse.ArgumentParser(
        description="Convert a bespoke cellpose segmentation of a MERSCOPE region to VPT "
                    "output files"
    )
    parser.add_argument(
        "--sample",
        required=True,
        help="Sample identifier",
    )
    parser.add_argument(
        "--path",
        required=True,
        help="MERSCOPE region output directory, for the gene names and the micron transform",
    )
    parser.add_argument(
        "--cellpose_path",
        required=True,
        help="Merged cellpose segmentation directory, holding labels.npy and merge.py's arrays",
    )
    parser.add_argument(
        "--outdir",
        default=".",
        help="Directory to write the VPT files into (default: current directory)",
    )
    return parser.parse_args()


def main():
    args = parse_args()

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    region_dir = Path(args.path)
    cellpose_dir = Path(args.cellpose_path)

    print(f"Sample:   {args.sample}")
    print(f"Region:   {region_dir}")
    print(f"Cellpose: {cellpose_dir}")
    print(f"Output:   {outdir}")

    with timer("Load segmentation"):
        labels, label_map, counts, centres, volumes = load_segmentation(cellpose_dir)

    # Gene order is the region's own, since the counts array carries no column names.
    genes = pd.read_csv(region_dir / "cell_by_gene.csv", index_col=0, nrows=0).columns
    if len(genes) != counts.shape[1]:
        raise ValueError(
            f"{region_dir / 'cell_by_gene.csv'} names {len(genes):,} genes but the "
            f"segmentation counts have {counts.shape[1]:,} columns."
        )
    print(f"Genes:    {len(genes):,}")

    transform = pixel_to_micron_transform(region_dir)

    # merge.py already ran find_objects over the volume and pickled it; reuse, do not rebuild.
    slicee_path = find_one(cellpose_dir, "-slicee.pkl")
    with open(slicee_path, "rb") as handle:
        slices = pickle.load(handle)
    if len(slices) != len(label_map):
        raise ValueError(
            f"{slicee_path.name} has {len(slices):,} entries and the label map "
            f"{len(label_map):,}; both index raw label - 1 and must agree."
        )

    with timer("Areas per plane"):
        areas = plane_areas(labels, len(label_map))

    check_volumes(areas, label_map, volumes)

    # A label only exists because it has voxels, so none is absent everywhere -- but argmax
    # would quietly answer 0 if one were.
    per_label = areas[:, 1:]
    best_plane = per_label.argmax(axis=0)
    best_plane[label_map == 0] = -1

    with timer("Trace boundaries"):
        boundaries, cell_planes = build_boundaries(
            labels, slices, label_map, best_plane, transform
        )
    print(f"Traced {len(boundaries):,} cell boundaries.")

    # merscope() drops invalid geometries without warning, and the counts and metadata below
    # are written for every row here -- so the store would name cells it has no boundary for.
    invalid = int((~boundaries.geometry.is_valid).sum())
    if invalid:
        raise ValueError(
            f"{invalid:,} of {len(boundaries):,} traced polygons are invalid. merscope() "
            f"would drop them silently and leave their counts in the table."
        )

    # One order for all three, and only cells that got a polygon: merscope() hands the counts
    # and the metadata straight to AnnData, which requires their indexes to match.
    entity_ids = boundaries["EntityID"].to_numpy()
    order = np.argsort(entity_ids)
    entity_ids = entity_ids[order]

    with timer("Write counts"):
        cell_by_gene = pd.DataFrame(counts[entity_ids], index=entity_ids, columns=genes)
        cell_by_gene.index.name = "cell"
        cell_by_gene.to_csv(outdir / OUTPUT_NAMES["cell_by_gene"])

    with timer("Write metadata"):
        centre_x, centre_y = to_microns(
            centres[entity_ids - 1, 1], centres[entity_ids - 1, 2], transform
        )
        bounds = boundaries.geometry.bounds.to_numpy()[order]
        # merge.py counted voxels; a Vizgen cell_metadata.csv holds cubic microns, which is
        # what everything downstream reads this column expecting.
        voxel_microns = abs(np.linalg.det(transform[:2, :2])) * Z_STEP_MICRONS
        metadata = pd.DataFrame(
            {
                "EntityID": entity_ids,
                "volume": volumes[entity_ids - 1] * voxel_microns,
                "volume_voxels": volumes[entity_ids - 1],
                "center_x": centre_x,
                "center_y": centre_y,
                "min_x": bounds[:, 0],
                "min_y": bounds[:, 1],
                "max_x": bounds[:, 2],
                "max_y": bounds[:, 3],
                # Which plane the boundary came from; the parquet itself is all ZIndex 0.
                "z_plane": cell_planes.loc[entity_ids].to_numpy(),
            }
        ).set_index("EntityID")
        metadata.to_csv(outdir / OUTPUT_NAMES["cell_metadata"])

    with timer("Write boundaries"):
        boundaries.iloc[order].to_parquet(outdir / OUTPUT_NAMES["cell_boundaries"])

    print(f"\nWrote {len(entity_ids):,} cells:")
    for name in OUTPUT_NAMES.values():
        print(f"  {name}")

    timing_summary(outdir / f"{args.sample}.prep_cellpose_vpt.timing.tsv")


if __name__ == "__main__":
    main()
