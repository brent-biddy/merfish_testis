#!/usr/bin/env nextflow

include { create_spatialdata      } from './modules/create_spatialdata'
include { cluster_spatialdata_gpu } from './modules/cluster_spatialdata_gpu'
include { annotate_celltypes      } from './modules/annotate_celltypes'
include { create_centroids        } from './modules/create_centroids'
include { render                  } from './modules/render'
include { samplePathPairs         } from './modules/samplesheet'

workflow {
    create_spatialdata(samplePathPairs())
    cluster_spatialdata_gpu(create_spatialdata.out.zarr)
    annotate_celltypes(cluster_spatialdata_gpu.out.zarr)

    annotate_celltypes.out.artifacts
        .map { sample, publish_dir, zarr -> tuple(sample, zarr, "${publish_dir}/${zarr.name}") }
        .set { ch_centroid_inputs } // tuple(sample, zarr, input_dir)

    create_centroids(ch_centroid_inputs)

    create_centroids.out.centroids
        .join(annotate_celltypes.out.zarr)
        .map { sample, centroids, zarr -> tuple(sample, [centroids, zarr]) }
        .set { ch_report_samples } // tuple(sample, staged_paths)

    render(ch_report_samples, file("${projectDir}/notebooks/celltype_report.qmd"), params.to, false)
}
