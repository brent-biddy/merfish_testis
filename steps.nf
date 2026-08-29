#!/usr/bin/env nextflow

// One step at a time, while the analysis is still being worked out:
//
//   nextflow run steps.nf -profile wsl --step <name> --samplesheet <path>
//
// The other entry script is main.nf, which replays the finished analysis as one run. These
// two are peers: this file is what you iterate with, main.nf is the result you keep. It is
// named steps.nf rather than main.nf so `nextflow run .` gives someone the analysis, not the
// tooling.
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
// Each step is independent: there is no chaining here. A step that consumes another's output
// takes a samplesheet pointing at the prior step's published paths — and every step writes the
// next one's samplesheet into params.outdir, so that path is something a run hands you rather
// than something you assemble. Any step can be rerun on its own without re-running what came
// before.
//
// This file only dispatches. A step's process and its workflow live together in its module,
// and each module workflow takes an input channel, so main.nf can call the same workflows.

include { create_spatialdata      } from './modules/create_spatialdata'
include { prep_cellpose_vpt       } from './modules/prep_cellpose_vpt'
include { create_spatialdata_cellpose } from './modules/create_spatialdata_cellpose'
include { cluster_spatialdata_gpu } from './modules/cluster_spatialdata_gpu'
include { annotate_celltypes      } from './modules/annotate_celltypes'
include { create_centroids        } from './modules/create_centroids'
include { quarto_render           } from './modules/quarto_render'
include { samplePathPairs; samplePathWithSource;
          sampleRegionCellpose; sampleRegionVpt } from './modules/samplesheet'

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

    if      (params.step == 'create_spatialdata')      create_spatialdata(samplePathPairs())
    else if (params.step == 'prep_cellpose_vpt')       prep_cellpose_vpt(sampleRegionCellpose())
    else if (params.step == 'create_spatialdata_cellpose') create_spatialdata_cellpose(sampleRegionVpt())
    else if (params.step == 'cluster_spatialdata_gpu') cluster_spatialdata_gpu(samplePathPairs())
    else if (params.step == 'annotate_celltypes')      annotate_celltypes(samplePathPairs())
    else if (params.step == 'create_centroids')        create_centroids(samplePathWithSource())
    else if (params.step == 'quarto_render')           quarto_render()
}
