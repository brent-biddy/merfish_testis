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

    // create_centroids also takes where its input was published, because the handoff row it
    // writes has to forward a location that resolves outside the task. That comes from the
    // upstream step's own publish_dir rather than being rebuilt from params.outdir here.
    create_centroids(
        annotate_celltypes.out.artifacts.map { sample, publish_dir, zarr ->
            tuple(sample, zarr, "${publish_dir}/${zarr.name}")
        }
    )

    // The report reads two steps' artifacts, joined into one row per sample. Joined on the
    // sample rather than mixed and collected, because renderSpecs sorts rows by sample to keep
    // a chained run's section order stable — and a flat list of paths has no sample to sort on.
    // Staged flat — every artifact is <sample>.<step>.<ext>, so the notebook globs the step it
    // wants rather than the workflow naming its inputs.
    // remainder: true because a plain join drops a sample present on only one side without
    // saying so, and a report quietly missing a sample is worse than a run that stops. A
    // clean run cannot hit this -- create_centroids consumes annotate_celltypes, so the two
    // carry the same ids -- but a sample that fails mid-run leaves one side short, and that
    // is exactly when the report should not be written.
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

    // Rendering calls the process rather than the module workflow, because that workflow reads
    // the mode off params.step and a pinned path has no --step. renderSpecs is the module's own
    // spec builder, so the report publish path is still defined once, in reportDir — and
    // --report_id and --to mean the same thing here as in a stepwise render.
    //
    // One cohort render today. Adding per-sample pages beside it is a second renderSpecs call
    // mixed into this channel, because the notebook and the format ride in the tuple.
    QUARTO_RENDER(
        renderSpecs(report_rows, file("${projectDir}/notebooks/celltype_report.qmd"),
                    params.to, false),
        file("${projectDir}/assets/ouhsc_ppt_template.pptx"),
        file("${projectDir}/assets/fold-code.lua"),
    )
}
