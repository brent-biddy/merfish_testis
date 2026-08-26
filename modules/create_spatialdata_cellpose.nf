include { validateAndParseSampleSheet } from './samplesheet'

// Published output directory for this step's per-sample artifacts. Used by the publishDir
// directive and the emitted samplesheet row, so the two cannot drift apart.
def createSpatialdataCellposePublishDir(sample) {
    "${params.outdir}/${sample}/create_spatialdata_cellpose"
}

// Convert one sample's cellpose re-segmentation to a SpatialData Zarr store.
process CREATE_SPATIALDATA_CELLPOSE {
    tag "${sample}"

    // pattern publishes the zarr store and the timing TSV; it leaves out
    // <sample>.samplesheet_row.csv.
    publishDir { createSpatialdataCellposePublishDir(sample) },
        mode: 'copy',
        pattern: '*.{zarr,tsv}'

    input:
    tuple val(sample), path(region_dir), path(vpt_dir)
    path 'timer.py'

    output:
    tuple val(sample), path("${sample}.zarr"), emit: artifacts
    path "${sample}.create_spatialdata_cellpose.timing.tsv", emit: timings
    // One `sample,path` line pointing at the published zarr.
    // main.nf collects these into a handoff samplesheet.
    path "${sample}.samplesheet_row.csv", emit: samplesheet_row

    script:
    """
    create_spatialdata_cellpose.py --sample ${sample} --path ${region_dir} \\
        --vpt_path ${vpt_dir} --outdir .

    printf '%s' '${sample},${createSpatialdataCellposePublishDir(sample)}/${sample}.zarr' > ${sample}.samplesheet_row.csv
    """

    stub:
    """
    mkdir -p ${sample}.zarr
    touch ${sample}.create_spatialdata_cellpose.timing.tsv

    printf '%s' '${sample},${createSpatialdataCellposePublishDir(sample)}/${sample}.zarr' > ${sample}.samplesheet_row.csv
    """
}

workflow create_spatialdata_cellpose {
    validateAndParseSampleSheet(['sample', 'path', 'vpt_path'])
        .map { row -> tuple(row.sample, file(row.path), file(row.vpt_path)) }
        .set { regionDirs }          // tuple(sample, region_dir, vpt_dir)

    CREATE_SPATIALDATA_CELLPOSE(regionDirs, file("${projectDir}/bin/timer.py"))

    // Handoff samplesheet of the per-sample zarrs, so the next step can be pointed
    // straight at it instead of hand-building a sample,path CSV.
    CREATE_SPATIALDATA_CELLPOSE.out.samplesheet_row
        .map { it.text }             // read row content so collectFile's sort is deterministic
        .collectFile(name: 'create_spatialdata_cellpose_samplesheet.csv', storeDir: params.outdir,
                     seed: 'sample,path', newLine: true, sort: true)
}
