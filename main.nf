#!/usr/bin/env nextflow

// Single entry point for all pipeline steps.
// Select a step with: nextflow run main.nf --step <name> --samplesheet <path>
//
// Steps:
//   create_spatialdata       samplesheet: sample, path   (path = MERSCOPE region directory)
//   prep_cellpose_vpt        samplesheet: sample, path, cellpose_path
//                                             (path = MERSCOPE region directory,
//                                              cellpose_path = merged bespoke cellpose dir)
//   create_spatialdata_cellpose  samplesheet: sample, path, vpt_path
//                                             (path = MERSCOPE region directory,
//                                              vpt_path = its VPT cellpose output directory)
//   cluster_spatialdata_gpu  samplesheet: sample, path   (path = zarr from either create step)
//   annotate_celltypes       samplesheet: sample, path   (path = zarr from cluster_spatialdata_gpu)
//   create_centroids         samplesheet: sample, path   (path = zarr from either of the two above)
//   quarto_render            samplesheet: sample, and any path columns the notebook globs
//                            --notebook names the report to render
//
// Each step is independent: there is no chaining inside Nextflow. A step that consumes
// another's output takes a samplesheet pointing at the prior step's published paths, so
// any step can be rerun on its own without re-running what came before.

include { create_spatialdata      } from './modules/create_spatialdata'
include { prep_cellpose_vpt       } from './modules/prep_cellpose_vpt'
include { create_spatialdata_cellpose } from './modules/create_spatialdata_cellpose'
include { cluster_spatialdata_gpu } from './modules/cluster_spatialdata_gpu'
include { annotate_celltypes      } from './modules/annotate_celltypes'
include { create_centroids        } from './modules/create_centroids'
include { quarto_render           } from './modules/quarto_render'

workflow {
    def valid_steps = ['create_spatialdata', 'prep_cellpose_vpt',
                       'create_spatialdata_cellpose',
                       'cluster_spatialdata_gpu', 'annotate_celltypes',
                       'create_centroids', 'quarto_render']

    if (!params.samplesheet)           error "Please provide --samplesheet"
    if (!(params.step in valid_steps)) error "Please provide a valid --step. Valid steps: ${valid_steps.join(', ')}"
    // The render step has no notebook of its own -- that is the point of it.
    if (params.step == 'quarto_render' && !params.notebook)
        error "Please provide --notebook: the .qmd to render, e.g. notebooks/celltype_report.qmd"

    if      (params.step == 'create_spatialdata')      create_spatialdata()
    else if (params.step == 'prep_cellpose_vpt')       prep_cellpose_vpt()
    else if (params.step == 'create_spatialdata_cellpose') create_spatialdata_cellpose()
    else if (params.step == 'cluster_spatialdata_gpu') cluster_spatialdata_gpu()
    else if (params.step == 'annotate_celltypes')      annotate_celltypes()
    else if (params.step == 'create_centroids')        create_centroids()
    else if (params.step == 'quarto_render')           quarto_render()
}
