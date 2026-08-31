process PREP_CELLPOSE_VPT {
    tag "${sample}"

    publishDir { publish_dir }, mode: 'copy'

    input:
    tuple val(sample), val(publish_dir), val(region_path), path(region_dir), path(cellpose_dir)
    path 'timer.py'

    output:
    tuple val(sample), val(publish_dir), val(region_path),
          path("cellpose_*.{csv,parquet}"), emit: artifacts
    path "${sample}.prep_cellpose_vpt.timing.tsv", emit: timings

    script:
    """
    prep_cellpose_vpt.py --sample ${sample} --path ${region_dir} \\
        --cellpose_path ${cellpose_dir} --outdir .
    """

    stub:
    """
    touch cellpose_cell_by_gene.csv cellpose_cell_metadata.csv cellpose_micron_space.parquet
    touch ${sample}.prep_cellpose_vpt.timing.tsv
    """
}

workflow prep_cellpose_vpt {
    take:
    // tuple(sample, region path, cellpose dir). The region path travels as a value as well
    segmentations

    main:
    segmentations.map { sample, region_path, cellpose_dir ->
            tuple(sample, "${params.outdir}/${sample}/prep_cellpose_vpt",
                  region_path, file(region_path), cellpose_dir)
        }
        .set { prep_cellpose_vpt_inputs } // tuple(sample, publish_dir, region_path, region_file, cellpose_dir)

    PREP_CELLPOSE_VPT(prep_cellpose_vpt_inputs, file("${projectDir}/bin/timer.py"))

    PREP_CELLPOSE_VPT.out.artifacts
        .map { sample, publish_dir, region_path, files -> "${sample},${region_path},${publish_dir}" }
        .collectFile(name: 'prep_cellpose_vpt_samplesheet.csv', storeDir: params.outdir,
                     seed: 'sample,path,vpt_path', newLine: true, sort: true)

    emit:
    artifacts = PREP_CELLPOSE_VPT.out.artifacts
}
