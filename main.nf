#!/usr/bin/env nextflow

// The Vizgen-segmentation path, chained end to end. An example of the shape, not a settled
// analysis:
//
//   nextflow run main.nf -profile wsl --samplesheet assets/samplesheet.csv
//
// One analysis per entry script, at the repo root: projectDir is the directory of the launched
// script, and that is what puts bin/ on PATH and resolves ${projectDir}/assets. (-entry would
// have been the alternative; 26.x strict syntax dropped it.) The cellpose re-segmentation route
// is a different analysis and would be its own file, not a flag here. Working a step at a time
// is steps.nf.

include { create_spatialdata      } from './modules/create_spatialdata'
include { cluster_spatialdata_gpu } from './modules/cluster_spatialdata_gpu'
include { annotate_celltypes      } from './modules/annotate_celltypes'
include { create_centroids        } from './modules/create_centroids'
include { QUARTO_RENDER; renderSpecs } from './modules/render'
include { samplePathPairs         } from './modules/samplesheet'

workflow {
    create_spatialdata(samplePathPairs())

    cluster_spatialdata_gpu(
        create_spatialdata.out.artifacts.map { sample, publish_dir, zarr -> tuple(sample, zarr) }
    )

    annotate_celltypes(
        cluster_spatialdata_gpu.out.artifacts.map { sample, publish_dir, zarr -> tuple(sample, zarr) }
    )

    // Also takes where its input was published: the handoff row it writes has to forward a
    // location that resolves outside the task.
    create_centroids(
        annotate_celltypes.out.artifacts.map { sample, publish_dir, zarr ->
            tuple(sample, zarr, "${publish_dir}/${zarr.name}")
        }
    )

    // Two steps' artifacts, one row per sample. Joined rather than mixed and collected because
    // renderSpecs sorts rows by sample for a stable section order, and a flat path list has no
    // sample to sort on. remainder: true because a plain join drops a one-sided sample silently;
    // only a mid-run failure can leave one side short, and that is when a report should not be
    // written at all.
    create_centroids.out.artifacts
        .map { sample, publish_dir, centroids, input_dir -> tuple(sample, centroids) }
        .join(annotate_celltypes.out.artifacts.map { sample, publish_dir, zarr -> tuple(sample, zarr) },
              remainder: true)
        .map { sample, centroids, zarr ->
            if (!centroids) error "Sample '${sample}' has no centroids: create_centroids did not produce one."
            if (!zarr)      error "Sample '${sample}' has no annotated zarr: annotate_celltypes did not produce one."
            [sample: sample, centroids: centroids, zarr: zarr]
        }
        .set { report_rows }

    // Calls the process, not the module workflow: that workflow reads the mode off params.step
    // and a pinned path has no --step. Per-sample pages would be a second renderSpecs call mixed
    // into this channel, since the notebook and format ride in the tuple.
    QUARTO_RENDER(
        renderSpecs(report_rows, file("${projectDir}/notebooks/celltype_report.qmd"),
                    params.to, false),
        file("${projectDir}/assets/ouhsc_ppt_template.pptx"),
        file("${projectDir}/assets/fold-code.lua"),
    )
}
