process CREATE_SPATIALDATA_CELLPOSE {
    tag "${sample}"

    publishDir { publish_dir }, mode: 'copy'

    input:
    tuple val(sample), val(publish_dir), path(region_dir), path(vpt_dir)
    path 'timer.py'

    output:
    tuple val(sample), val(publish_dir),
          path("${sample}.create_spatialdata_cellpose.zarr"), emit: artifacts
    path "${sample}.create_spatialdata_cellpose.timing.tsv", emit: timings

    script:
    """
    create_spatialdata_cellpose.py --sample ${sample} --path ${region_dir} \\
        --vpt_path ${vpt_dir} --outdir .
    """

    stub:
    """
    mkdir -p ${sample}.create_spatialdata_cellpose.zarr
    touch ${sample}.create_spatialdata_cellpose.timing.tsv
    """
}

workflow create_spatialdata_cellpose {
    take:
    // tuple(sample, region dir, vpt dir)
    regionDirs

    main:
    regionDirs.map { sample, region_dir, vpt_dir ->
            tuple(sample, "${params.outdir}/${sample}/create_spatialdata_cellpose",
                  region_dir, vpt_dir)
        }
        .set { inputs } // tuple(sample, publish_dir, region_dir, vpt_dir)

    CREATE_SPATIALDATA_CELLPOSE(inputs, file("${projectDir}/bin/timer.py"))

    CREATE_SPATIALDATA_CELLPOSE.out.artifacts
        .map { sample, publish_dir, zarr -> "${sample},${publish_dir}/${zarr.name}" }
        .collectFile(name: 'create_spatialdata_cellpose_samplesheet.csv', storeDir: params.outdir,
                     seed: 'sample,path', newLine: true, sort: true)

    emit:
    artifacts = CREATE_SPATIALDATA_CELLPOSE.out.artifacts
}
