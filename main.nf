#!/usr/bin/env nextflow

// Single entry point for all pipeline steps.
// Select a step with: nextflow run main.nf --step <name> --samplesheet <path>
//
// Steps:
//   create_spatialdata       samplesheet: sample, path   (path = MERSCOPE region directory)
//   cluster_spatialdata_gpu  samplesheet: sample, path   (path = zarr from create_spatialdata)
//
// Each step is independent: there is no chaining inside Nextflow. A step that consumes
// another's output takes a samplesheet pointing at the prior step's published paths, so
// any step can be rerun on its own without re-running what came before.

include { create_spatialdata      } from './modules/create_spatialdata'
include { cluster_spatialdata_gpu } from './modules/cluster_spatialdata_gpu'

workflow {
    def valid_steps = ['create_spatialdata', 'cluster_spatialdata_gpu']

    if (!params.samplesheet)           error "Please provide --samplesheet"
    if (!(params.step in valid_steps)) error "Please provide a valid --step. Valid steps: ${valid_steps.join(', ')}"

    if      (params.step == 'create_spatialdata')      create_spatialdata()
    else if (params.step == 'cluster_spatialdata_gpu') cluster_spatialdata_gpu()
}
