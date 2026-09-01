#!/usr/bin/env nextflow

//   nextflow run steps.nf -profile wsl --step <name> --samplesheet <path>
//
// Steps, and the samplesheet columns each reads. Both render steps also need --notebook.
//
//   create_spatialdata           sample, path=region dir
//   prep_cellpose_vpt            sample, path=region dir, cellpose_path=merged bespoke cellpose
//   create_spatialdata_cellpose  sample, path=region dir, vpt_path=its VPT cellpose output
//   cluster_spatialdata_gpu      sample, path=zarr from either create step
//   annotate_celltypes           sample, path=zarr from cluster_spatialdata_gpu
//   create_centroids             sample, path=zarr from either of the two above
//   render_cohort                sample, and any path columns the notebook globs
//   render_sample                same as render_cohort, one render per row

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

    def notebook = params.notebook ? file(params.notebook) : null

    if      (params.step == 'create_spatialdata')      create_spatialdata(samplePathPairs())
    else if (params.step == 'prep_cellpose_vpt')       prep_cellpose_vpt(sampleRegionCellpose())
    else if (params.step == 'create_spatialdata_cellpose') create_spatialdata_cellpose(sampleRegionVpt())
    else if (params.step == 'cluster_spatialdata_gpu') cluster_spatialdata_gpu(samplePathPairs())
    else if (params.step == 'annotate_celltypes')      annotate_celltypes(samplePathPairs())
    else if (params.step == 'create_centroids')        create_centroids(samplePathWithSource())
    else if (params.step == 'render_cohort')           render(sampleWithPaths(), notebook, params.to, false)
    else if (params.step == 'render_sample')           render(sampleWithPaths(), notebook, params.to, true)
}
