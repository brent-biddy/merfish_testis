#!/usr/bin/env nextflow

// Single entry point for all pipeline steps.
// Select a step with: nextflow run main.nf --step <name> --samplesheet <path>
//
// Steps:
//   create_spatialdata       samplesheet: sample, path   (path = MERSCOPE region directory)
//   cluster_spatialdata_gpu  samplesheet: sample, path   (path = zarr from create_spatialdata)
//   annotate_celltypes       samplesheet: sample, path   (path = zarr from cluster_spatialdata_gpu)
//   create_centroids         samplesheet: sample, path   (path = zarr from either of the two above)
//
// Each step is independent: there is no chaining inside Nextflow. A step that consumes
// another's output takes a samplesheet pointing at the prior step's published paths, so
// any step can be rerun on its own without re-running what came before.

include { create_spatialdata      } from './modules/create_spatialdata'
include { cluster_spatialdata_gpu } from './modules/cluster_spatialdata_gpu'
include { annotate_celltypes      } from './modules/annotate_celltypes'
include { create_centroids        } from './modules/create_centroids'

workflow {
    def valid_steps = ['create_spatialdata', 'cluster_spatialdata_gpu', 'annotate_celltypes',
                       'create_centroids']

    if (!params.samplesheet)           error "Please provide --samplesheet"
    if (!(params.step in valid_steps)) error "Please provide a valid --step. Valid steps: ${valid_steps.join(', ')}"

    if      (params.step == 'create_spatialdata')      create_spatialdata()
    else if (params.step == 'cluster_spatialdata_gpu') cluster_spatialdata_gpu()
    else if (params.step == 'annotate_celltypes')      annotate_celltypes()
    else if (params.step == 'create_centroids')        create_centroids()
}
