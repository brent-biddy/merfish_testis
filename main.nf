#!/usr/bin/env nextflow

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

    create_centroids(
        annotate_celltypes.out.artifacts.map { sample, publish_dir, zarr ->
            tuple(sample, zarr, "${publish_dir}/${zarr.name}")
        }
    )

    create_centroids.out.artifacts
        .map { sample, publish_dir, centroids, input_dir -> tuple(sample, centroids) }
        .join(annotate_celltypes.out.artifacts.map { sample, publish_dir, zarr -> tuple(sample, zarr) },
              remainder: true)
        .map { sample, centroids, zarr ->
            if (!centroids) error "Sample '${sample}' has no centroids: create_centroids did not produce one."
            if (!zarr)      error "Sample '${sample}' has no annotated zarr: annotate_celltypes did not produce one."
            tuple(sample, [centroids, zarr])
        }
        .set { report_rows } // tuple(sample, staged_paths)

    def report_inputs = renderSpecs(report_rows,
                                    file("${projectDir}/notebooks/celltype_report.qmd"),
                                    params.to, false)
    // tuple(publish_dir, stem, format, notebook, staged_paths), one element: the cohort render

    QUARTO_RENDER(
        report_inputs,
        file("${projectDir}/assets/ouhsc_ppt_template.pptx"),
        file("${projectDir}/assets/fold-code.lua"),
    )
}
