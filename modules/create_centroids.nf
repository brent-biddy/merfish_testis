include { validateAndParseSampleSheet } from './samplesheet'

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
    tuple val(sample), path("${sample}.centroids.h5ad"), emit: artifacts
    path "${sample}.create_centroids.timing.tsv", emit: timings
    // One `sample,path` line pointing at the published centroid store.
    path "${sample}.samplesheet_row.csv", emit: samplesheet_row

    script:
    """
    create_centroids.py --sample ${sample} --path ${zarr} --outdir .

    printf '%s' '${sample},${createCentroidsPublishDir(sample)}/${sample}.centroids.h5ad' > ${sample}.samplesheet_row.csv
    """

    stub:
    """
    touch ${sample}.centroids.h5ad
    touch ${sample}.create_centroids.timing.tsv

    printf '%s' '${sample},${createCentroidsPublishDir(sample)}/${sample}.centroids.h5ad' > ${sample}.samplesheet_row.csv
    """
}

workflow create_centroids {
    validateAndParseSampleSheet(['sample', 'path'])
        .map { row -> tuple(row.sample, file(row.path)) }
        .set { zarrs }               // tuple(sample, clustered zarr)

    CREATE_CENTROIDS(zarrs, file("${projectDir}/bin/timer.py"))

    // Handoff samplesheet of the per-sample centroid stores.
    CREATE_CENTROIDS.out.samplesheet_row
        .map { it.text }             // read row content so collectFile's sort is deterministic
        .collectFile(name: 'create_centroids_samplesheet.csv', storeDir: params.outdir,
                     seed: 'sample,path', newLine: true, sort: true)
}
