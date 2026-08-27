include { validateAndParseSampleSheet } from './samplesheet'

// Published output directory for this step's per-sample artifacts. Used by the publishDir
// directive and the emitted samplesheet row, so the two cannot drift apart.
def prepCellposeVptPublishDir(sample) {
    "${params.outdir}/${sample}/prep_cellpose_vpt"
}

// Convert one sample's bespoke cellpose segmentation to VPT output files.
process PREP_CELLPOSE_VPT {
    tag "${sample}"

    // Two patterns rather than one '*.csv': the samplesheet row is a .csv too, and it is
    // collected into the handoff sheet rather than published beside the outputs.
    publishDir { prepCellposeVptPublishDir(sample) }, mode: 'copy', pattern: 'cellpose_*'
    publishDir { prepCellposeVptPublishDir(sample) }, mode: 'copy', pattern: '*.timing.tsv'

    input:
    // region_path is the samplesheet's own path, carried through for the emitted row:
    // region_dir is the staged name, which says nothing about where the region lives.
    tuple val(sample), val(region_path), path(region_dir), path(cellpose_dir)
    path 'timer.py'

    output:
    tuple val(sample), path("cellpose_*.{csv,parquet}"), emit: artifacts
    path "${sample}.prep_cellpose_vpt.timing.tsv", emit: timings
    // One `sample,path,vpt_path` line: the region unchanged, and this step's output as
    // the VPT directory. main.nf collects these into a handoff samplesheet.
    path "${sample}.samplesheet_row.csv", emit: samplesheet_row

    script:
    """
    prep_cellpose_vpt.py --sample ${sample} --path ${region_dir} \\
        --cellpose_path ${cellpose_dir} --outdir .

    printf '%s' '${sample},${region_path},${prepCellposeVptPublishDir(sample)}' > ${sample}.samplesheet_row.csv
    """

    stub:
    """
    touch cellpose_cell_by_gene.csv cellpose_cell_metadata.csv cellpose_micron_space.parquet
    touch ${sample}.prep_cellpose_vpt.timing.tsv

    printf '%s' '${sample},${region_path},${prepCellposeVptPublishDir(sample)}' > ${sample}.samplesheet_row.csv
    """
}

workflow prep_cellpose_vpt {
    validateAndParseSampleSheet(['sample', 'path', 'cellpose_path'])
        .map { row -> tuple(row.sample, row.path, file(row.path), file(row.cellpose_path)) }
        .set { segmentations }       // tuple(sample, region_path, region_dir, cellpose_dir)

    PREP_CELLPOSE_VPT(segmentations, file("${projectDir}/bin/timer.py"))

    // Handoff samplesheet in create_spatialdata_cellpose's own shape, so that step can be
    // pointed straight at it instead of hand-building a sample,path,vpt_path CSV.
    PREP_CELLPOSE_VPT.out.samplesheet_row
        .map { it.text }             // read row content so collectFile's sort is deterministic
        .collectFile(name: 'prep_cellpose_vpt_samplesheet.csv', storeDir: params.outdir,
                     seed: 'sample,path,vpt_path', newLine: true, sort: true)
}
