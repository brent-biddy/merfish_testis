process CLUSTER_SPATIALDATA_GPU {
    tag "${sample}"

    label 'gpu'

    publishDir { publish_dir }, mode: 'copy'

    input:
    tuple val(sample), val(publish_dir), path(zarr)
    path 'timer.py'

    output:
    tuple val(sample), val(publish_dir), path("${sample}.cluster_spatialdata_gpu.zarr"), emit: artifacts
    path "${sample}.cluster_spatialdata_gpu.timing.tsv", emit: timings

    script:
    """
    cluster_spatialdata_gpu.py --sample ${sample} --path ${zarr} --outdir .
    """

    stub:
    """
    mkdir -p ${sample}.cluster_spatialdata_gpu.zarr
    touch ${sample}.cluster_spatialdata_gpu.timing.tsv
    """
}

workflow cluster_spatialdata_gpu {
    take:
    // tuple(sample, input path). Both entry points hand over the same shape: main.nf from a
    zarrs

    main:
    zarrs.map { sample, input_path ->
            tuple(sample, "${params.outdir}/${sample}/cluster_spatialdata_gpu", input_path)
        }
        .set { inputs } // tuple(sample, publish_dir, zarr)

    CLUSTER_SPATIALDATA_GPU(inputs, file("${projectDir}/bin/timer.py"))

    CLUSTER_SPATIALDATA_GPU.out.artifacts
        .map { sample, publish_dir, artifact -> "${sample},${publish_dir}/${artifact.name}" }
        .collectFile(name: 'cluster_spatialdata_gpu_samplesheet.csv', storeDir: params.outdir,
                     seed: 'sample,path', newLine: true, sort: true)

    emit:
    artifacts = CLUSTER_SPATIALDATA_GPU.out.artifacts
}
