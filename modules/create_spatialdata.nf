// Convert one sample's MERSCOPE region directory to a SpatialData Zarr store.
process CREATE_SPATIALDATA {
    tag "${sample}"

    // publish_dir is an input rather than a helper call: the workflow builds it once and
    // carries it back out, so the location this publishes to and the location the next step
    // is told to read are the same string. A directive is a closure evaluated after inputs
    // are bound, which is why it can reference one — the same reason `tag` above can.
    publishDir { publish_dir }, mode: 'copy'

    input:
    tuple val(sample), val(publish_dir), path(region_dir)
    path 'timer.py'

    output:
    tuple val(sample), val(publish_dir), path("${sample}.zarr"), emit: artifacts
    path "${sample}.create_spatialdata.timing.tsv", emit: timings

    script:
    """
    create_spatialdata.py --sample ${sample} --path ${region_dir} --outdir .
    """

    stub:
    """
    mkdir -p ${sample}.zarr
    touch ${sample}.create_spatialdata.timing.tsv
    """
}

workflow create_spatialdata {
    take:
    // tuple(sample, input path). Both entry points hand over the same shape: main.nf from a
    // samplesheet, the chained script from the previous step's artifacts.
    regionDirs

    main:
    // The publish dir is built here and nowhere else. It goes into the process and comes back
    // out with the artifact, so no caller ever reconstructs it.
    regionDirs.map { sample, input_path ->
            tuple(sample, "${params.outdir}/${sample}/create_spatialdata", input_path)
        }
        .set { inputs }

    CREATE_SPATIALDATA(inputs, file("${projectDir}/bin/timer.py"))

    // Handoff samplesheet, built from the channel rather than a row file the task printf'd.
    CREATE_SPATIALDATA.out.artifacts
        .map { sample, publish_dir, artifact -> "${sample},${publish_dir}/${artifact.name}" }
        .collectFile(name: 'create_spatialdata_samplesheet.csv', storeDir: params.outdir,
                     seed: 'sample,path', newLine: true, sort: true)

    emit:
    artifacts = CREATE_SPATIALDATA.out.artifacts
}
