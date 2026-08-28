// GPU-accelerated filter, normalize, and Leiden sweep on one sample's SpatialData zarr.
process CLUSTER_SPATIALDATA_GPU {
    tag "${sample}"

    // What this step needs, not where it gets it. Each site profile's `withLabel: 'gpu'` block
    // says how a card is reached there: --nv and --gres on real HPC, a /usr/lib/wsl bind under
    // WSL2. By label rather than by process name so config never learns what a step is called.
    label 'gpu'

    // publish_dir is an input rather than a helper call: the workflow builds it once and
    // carries it back out, so the location this publishes to and the location the next step
    // is told to read are the same string.
    publishDir { publish_dir }, mode: 'copy'

    input:
    // stageAs: the input store is named <sample>.zarr too, and would collide with the
    // output of the same name in the task work dir.
    tuple val(sample), val(publish_dir), path(zarr, stageAs: 'input.zarr')
    path 'timer.py'

    output:
    tuple val(sample), val(publish_dir), path("${sample}.zarr"), emit: artifacts
    path "${sample}.cluster_spatialdata_gpu.timing.tsv", emit: timings

    script:
    """
    cluster_spatialdata_gpu.py --sample ${sample} --path ${zarr} --outdir .
    """

    stub:
    """
    mkdir -p ${sample}.zarr
    touch ${sample}.cluster_spatialdata_gpu.timing.tsv
    """
}

workflow cluster_spatialdata_gpu {
    take:
    // tuple(sample, input path). Both entry points hand over the same shape: main.nf from a
    // samplesheet, the chained script from the previous step's artifacts.
    zarrs

    main:
    // The publish dir is built here and nowhere else. It goes into the process and comes back
    // out with the artifact, so no caller ever reconstructs it.
    zarrs.map { sample, input_path ->
            tuple(sample, "${params.outdir}/${sample}/cluster_spatialdata_gpu", input_path)
        }
        .set { inputs }

    CLUSTER_SPATIALDATA_GPU(inputs, file("${projectDir}/bin/timer.py"))

    // Handoff samplesheet, built from the channel rather than a row file the task printf'd.
    CLUSTER_SPATIALDATA_GPU.out.artifacts
        .map { sample, publish_dir, artifact -> "${sample},${publish_dir}/${artifact.name}" }
        .collectFile(name: 'cluster_spatialdata_gpu_samplesheet.csv', storeDir: params.outdir,
                     seed: 'sample,path', newLine: true, sort: true)

    emit:
    artifacts = CLUSTER_SPATIALDATA_GPU.out.artifacts
}
