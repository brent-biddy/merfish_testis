include { validateAndParseSampleSheet } from './samplesheet'

// Basename of both artifacts this step writes. A --group_by run publishes beside a sweep
// run rather than displacing it, so the column goes in the name. Single-sourced because
// the output block, the samplesheet row and the stub must all agree, and a --group_by run
// changes all of them at once.
def centroidStem(sample) {
    params.group_by ? "${sample}.centroids_${params.group_by}" : "${sample}.centroids"
}

// Published output directory for this step's per-sample artifacts. Used by the publishDir
// directive and the emitted samplesheet row, so the two cannot drift apart.
def createCentroidsPublishDir(sample) {
    "${params.outdir}/${sample}/create_centroids"
}

// Build per-cluster centroids from one sample's clustered zarr.
process CREATE_CENTROIDS {
    tag "${sample}"

    // pattern publishes the centroid store and the timing TSV; it leaves out
    // <sample>.samplesheet_row.csv.
    publishDir { createCentroidsPublishDir(sample) },
        mode: 'copy',
        pattern: '*.{h5ad,tsv}'

    input:
    tuple val(sample), path(zarr)
    path 'timer.py'

    output:
    tuple val(sample), path("${centroidStem(sample)}.h5ad"), emit: artifacts
    path "${centroidStem(sample)}.timing.tsv", emit: timings
    // One `sample,path` line pointing at the published centroid store.
    path "${sample}.samplesheet_row.csv", emit: samplesheet_row

    script:
    def centroidArgs = ["--sample ${sample}", "--path ${zarr}", "--outdir ."]
    // Omitted when unset, so the default stays defined in the script.
    if (params.group_by) centroidArgs << "--group_by ${params.group_by}"
    def published = "${createCentroidsPublishDir(sample)}/${centroidStem(sample)}.h5ad"
    """
    create_centroids.py ${centroidArgs.join(' ')}

    printf '%s' '${sample},${published}' > ${sample}.samplesheet_row.csv
    """

    stub:
    """
    touch ${centroidStem(sample)}.h5ad
    touch ${centroidStem(sample)}.timing.tsv

    printf '%s' '${sample},${createCentroidsPublishDir(sample)}/${centroidStem(sample)}.h5ad' > ${sample}.samplesheet_row.csv
    """
}

workflow create_centroids {
    validateAndParseSampleSheet(['sample', 'path'])
        .map { row -> tuple(row.sample, file(row.path)) }
        .set { zarrs }               // tuple(sample, clustered zarr)

    CREATE_CENTROIDS(zarrs, file("${projectDir}/bin/timer.py"))

    // Handoff samplesheet of the per-sample centroid stores. Named for the grouping like
    // the artifacts are, so a --group_by run does not overwrite the sweep's sheet.
    def sheet = params.group_by ? "create_centroids_${params.group_by}" : 'create_centroids'

    CREATE_CENTROIDS.out.samplesheet_row
        .map { it.text }             // read row content so collectFile's sort is deterministic
        .collectFile(name: "${sheet}_samplesheet.csv", storeDir: params.outdir,
                     seed: 'sample,path', newLine: true, sort: true)
}
