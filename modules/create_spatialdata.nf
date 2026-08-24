include { validateAndParseSampleSheet } from './samplesheet'

// Published output directory for this step's per-sample artifacts. Used by the publishDir
// directive and the emitted samplesheet row, so the two cannot drift apart.
def createSpatialdataPublishDir(sample) {
    "${params.outdir}/${sample}/create_spatialdata"
}

// Convert one sample's MERSCOPE region directory to a SpatialData Zarr store.
process CREATE_SPATIALDATA {
    tag "${sample}"

    // pattern publishes the zarr store and the timing TSV; it leaves out
    // <sample>.samplesheet_row.csv.
    publishDir { createSpatialdataPublishDir(sample) },
        mode: 'copy',
        pattern: '*.{zarr,tsv}'

    input:
    tuple val(sample), path(region_dir)
    path 'timer.py'

    output:
    tuple val(sample), path("${sample}.zarr"), emit: artifacts
    path "${sample}.create_spatialdata.timing.tsv", emit: timings
    // One `sample,path` line pointing at the published zarr.
    // main.nf collects these into a handoff samplesheet.
    path "${sample}.samplesheet_row.csv", emit: samplesheet_row

    script:
    """
    create_spatialdata.py --sample ${sample} --path ${region_dir} --outdir .

    printf '%s' '${sample},${createSpatialdataPublishDir(sample)}/${sample}.zarr' > ${sample}.samplesheet_row.csv
    """

    stub:
    """
    mkdir -p ${sample}.zarr
    touch ${sample}.create_spatialdata.timing.tsv

    printf '%s' '${sample},${createSpatialdataPublishDir(sample)}/${sample}.zarr' > ${sample}.samplesheet_row.csv
    """
}

workflow create_spatialdata {
    validateAndParseSampleSheet(['sample', 'path'])
        .map { row -> tuple(row.sample, file(row.path)) }
        .set { regionDirs }          // tuple(sample, region_dir)

    CREATE_SPATIALDATA(regionDirs, file("${projectDir}/bin/timer.py"))

    // Handoff samplesheet of the per-sample zarrs, so the next step can be pointed
    // straight at it instead of hand-building a sample,path CSV.
    CREATE_SPATIALDATA.out.samplesheet_row
        .map { it.text }             // read row content so collectFile's sort is deterministic
        .collectFile(name: 'create_spatialdata_samplesheet.csv', storeDir: params.outdir,
                     seed: 'sample,path', newLine: true, sort: true)
}
