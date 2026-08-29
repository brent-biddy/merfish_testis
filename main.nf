#!/usr/bin/env nextflow

// The Vizgen-segmentation path, chained end to end:
//
//   nextflow run main.nf -profile wsl --samplesheet assets/samplesheet.csv
//
// **This is an example of the shape, not a settled analysis.** The analysis this repo will
// eventually publish is not decided, so nothing here is pinned in the sense a paper needs.
// What it demonstrates is that the steps compose: the same module workflows steps.nf
// dispatches one at a time run as one invocation, with no code duplicated between them.
//
// It is main.nf because the analysis belongs at the front door: `nextflow run .` and
// `nextflow run <repo>` both resolve to this file, so what someone gets by default is a path
// that produces results, not the tooling that produces the path. Working a step at a time is
// steps.nf.
//
// The two are peers, not layers. You work a step at a time while the analysis is being figured
// out, because a step you can rerun on its own is what makes iterating cheap. Once a path is
// settled, it gets written down like this one so it can be replayed as one run — and there can
// be more than one, a file per analysis, named for what it produces.
//
// It has to sit here at the repo root: projectDir is the directory of the launched script, and
// that is what puts bin/ on PATH and resolves ${projectDir}/assets. One in a subdirectory
// breaks both. (Nextflow's -entry would have been the other way to do this; the strict syntax
// in 26.x no longer supports it.)
//
// It calls the module workflows, not the processes. Each one owns its publish dir and hands it
// back out with the artifact, so nothing here reconstructs a path a step already knows — and
// every step still writes its handoff samplesheet, so a run of this can be resumed from any
// single step afterwards with steps.nf.
//
// This is the Vizgen-segmentation path. The cellpose re-segmentation route
// (prep_cellpose_vpt -> create_spatialdata_cellpose) is a different analysis and would be its
// own entry script, not a flag here.

include { create_spatialdata      } from './modules/create_spatialdata'
include { cluster_spatialdata_gpu } from './modules/cluster_spatialdata_gpu'
include { annotate_celltypes      } from './modules/annotate_celltypes'
include { create_centroids        } from './modules/create_centroids'
include { QUARTO_RENDER           } from './modules/quarto_render'
include { samplePathPairs         } from './modules/samplesheet'

workflow {
    create_spatialdata(samplePathPairs())

    cluster_spatialdata_gpu(
        create_spatialdata.out.artifacts.map { sample, publish_dir, zarr -> tuple(sample, zarr) }
    )

    annotate_celltypes(
        cluster_spatialdata_gpu.out.artifacts.map { sample, publish_dir, zarr -> tuple(sample, zarr) }
    )

    // create_centroids also takes where its input was published, because the handoff row it
    // writes has to forward a location that resolves outside the task. That comes from the
    // upstream step's own publish_dir rather than being rebuilt from params.outdir here.
    create_centroids(
        annotate_celltypes.out.artifacts.map { sample, publish_dir, zarr ->
            tuple(sample, zarr, "${publish_dir}/${zarr.name}")
        }
    )

    // The report is a terminal fan-in over two steps' artifacts, so it calls the process
    // directly: there is no handoff for a module workflow to manage, and nothing consumes it.
    // Staged flat — every artifact is <sample>.<step>.<ext>, so the notebook globs the step it
    // wants rather than the workflow naming its inputs.
    create_centroids.out.artifacts
        .map { sample, publish_dir, centroids, input_dir -> centroids }
        .mix(annotate_celltypes.out.artifacts.map { sample, publish_dir, zarr -> zarr })
        .collect()
        .set { report_inputs }

    QUARTO_RENDER(
        "celltype_report_${params.run_id}",
        report_inputs,
        file("${projectDir}/notebooks/celltype_report.qmd"),
        file("${projectDir}/assets/ouhsc_ppt_template.pptx"),
        file("${projectDir}/assets/fold-code.lua"),
    )
}
