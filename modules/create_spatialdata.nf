process CREATE_SPATIALDATA {
    tag "${sample}"

    publishDir { publish_dir }, mode: 'copy'

    input:
    tuple val(sample), val(publish_dir), path(region_dir)
    path 'timer.py'

    output:
    tuple val(sample), val(publish_dir), path("${sample}.create_spatialdata.zarr"), emit: artifacts
    path "${sample}.create_spatialdata.timing.tsv", emit: timings

    script:
    """
    create_spatialdata.py --sample ${sample} --path ${region_dir} --outdir .
    """

    stub:
    """
    mkdir -p ${sample}.create_spatialdata.zarr
    touch ${sample}.create_spatialdata.timing.tsv
    """
}

workflow create_spatialdata {
    take:
    // tuple(sample, input path). Both entry points hand over the same shape: main.nf from a
    ch_region_dirs

    main:
    ch_region_dirs.map { sample, input_path ->
            tuple(sample, "${params.outdir}/${sample}/create_spatialdata", input_path)
        }
        .set { ch_create_spatialdata_inputs } // tuple(sample, publish_dir, region_dir)

    CREATE_SPATIALDATA(ch_create_spatialdata_inputs, file("${projectDir}/bin/timer.py"))

    CREATE_SPATIALDATA.out.artifacts
        .map { sample, publish_dir, artifact -> "${sample},${publish_dir}/${artifact.name}" }
        .collectFile(name: 'create_spatialdata_samplesheet.csv', storeDir: params.outdir,
                     seed: 'sample,path', newLine: true, sort: true)

    emit:
    artifacts = CREATE_SPATIALDATA.out.artifacts
}
