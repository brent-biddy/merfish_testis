#!/usr/bin/env nextflow

//   nextflow run steps.nf -profile wsl --step <name> --samplesheet <path>
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
//   render_cohort            samplesheet: sample, and any path columns the notebook globs
//                            one render over every row; --to picks one declared format
//   render_sample            same samplesheet and --notebook; one render per row
//                            --notebook names the report to render

include { create_spatialdata      } from './modules/create_spatialdata'
include { prep_cellpose_vpt       } from './modules/prep_cellpose_vpt'
include { create_spatialdata_cellpose } from './modules/create_spatialdata_cellpose'
include { cluster_spatialdata_gpu } from './modules/cluster_spatialdata_gpu'
include { annotate_celltypes      } from './modules/annotate_celltypes'
include { create_centroids        } from './modules/create_centroids'
include { render                  } from './modules/render'
include { sampleWithPaths; samplePathPairs; samplePathWithSource;
          sampleRegionCellpose; sampleRegionVpt } from './modules/samplesheet'

workflow {
    def valid_steps = ['create_spatialdata', 'prep_cellpose_vpt',
                       'create_spatialdata_cellpose',
                       'cluster_spatialdata_gpu', 'annotate_celltypes',
                       'create_centroids', 'render_cohort', 'render_sample']

    if (!params.samplesheet)           error "Please provide --samplesheet"
    if (!(params.step in valid_steps)) error "Please provide a valid --step. Valid steps: ${valid_steps.join(', ')}"
    if (params.step.startsWith('render') && !params.notebook)
        error "Please provide --notebook: the .qmd to render, e.g. notebooks/celltype_report.qmd"

    if      (params.step == 'create_spatialdata')      create_spatialdata(samplePathPairs())
    else if (params.step == 'prep_cellpose_vpt')       prep_cellpose_vpt(sampleRegionCellpose())
    else if (params.step == 'create_spatialdata_cellpose') create_spatialdata_cellpose(sampleRegionVpt())
    else if (params.step == 'cluster_spatialdata_gpu') cluster_spatialdata_gpu(samplePathPairs())
    else if (params.step == 'annotate_celltypes')      annotate_celltypes(samplePathPairs())
    else if (params.step == 'create_centroids')        create_centroids(samplePathWithSource())
    else                                               render(sampleWithPaths(), file(params.notebook),
                                                              params.to, params.step == 'render_sample')
}
