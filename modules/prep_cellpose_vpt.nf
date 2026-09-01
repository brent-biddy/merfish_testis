include { samplesFrom } from './samplesheet'

process PREP_CELLPOSE_VPT {
    tag "${sample}"

    publishDir { publish_dir }, mode: 'copy'

    input:
    tuple val(sample), val(publish_dir), path(region_dir), path(cellpose_dir)
    path 'timer.py'

    output:
    tuple val(sample), val(publish_dir), path("cellpose_*.{csv,parquet}"), emit: artifacts
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
    // a samplesheet, or tuple(sample, region dir, cellpose dir) per sample
    input

    main:
    def ch_segmentations = samplesFrom(input, ['sample', 'path', 'cellpose_path'])

    ch_segmentations.map { sample, region_dir, cellpose_dir ->
            tuple(sample, "${params.outdir}/${sample}/prep_cellpose_vpt", region_dir, cellpose_dir)
        }
        .set { ch_prep_cellpose_vpt_inputs } // tuple(sample, publish_dir, region_dir, cellpose_dir)

    PREP_CELLPOSE_VPT(ch_prep_cellpose_vpt_inputs, file("${projectDir}/bin/timer.py"))

    // Rejoined rather than carried through the process, which never reads it: the region
    // staged into the task is a work dir, not where the caller pointed.
    PREP_CELLPOSE_VPT.out.artifacts
        .join(ch_segmentations.map { sample, region_dir, cellpose_dir -> tuple(sample, "${region_dir}") })
        .map { sample, publish_dir, files, region_path -> "${sample},${region_path},${publish_dir}" }
        .collectFile(name: 'prep_cellpose_vpt_samplesheet.csv', storeDir: params.outdir,
                     seed: 'sample,path,vpt_path', newLine: true, sort: true)

    emit:
    artifacts = PREP_CELLPOSE_VPT.out.artifacts
}
