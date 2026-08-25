include { validateAndParseSampleSheet } from './samplesheet'

// Published output directory for this step's per-sample artifacts. Used by the publishDir
// directive and the emitted samplesheet row, so the two cannot drift apart.
def annotateCelltypesPublishDir(sample) {
    "${params.outdir}/${sample}/annotate_celltypes"
}

// Correlate one sample's cells against the reference cell type centroids.
process ANNOTATE_CELLTYPES {
    tag "${sample}"

    // pattern publishes the zarr store and the TSVs; it leaves out
    // <sample>.samplesheet_row.csv.
    publishDir { annotateCelltypesPublishDir(sample) },
        mode: 'copy',
        pattern: '*.{zarr,tsv}'

    input:
    // stageAs: the input store is named <sample>.zarr too, and would collide with the
    // output of the same name in the task work dir.
    tuple val(sample), path(zarr, stageAs: 'input.zarr')
    path reference
    path 'timer.py'

    output:
    tuple val(sample), path("${sample}.zarr"), emit: artifacts
    path "${sample}.gene_overlap.tsv", emit: gene_overlap
    path "${sample}.annotate_celltypes.timing.tsv", emit: timings
    // One `sample,path` line pointing at the published zarr.
    path "${sample}.samplesheet_row.csv", emit: samplesheet_row

    script:
    """
    annotate_celltypes.py --sample ${sample} --path ${zarr} --reference ${reference} --outdir .

    printf '%s' '${sample},${annotateCelltypesPublishDir(sample)}/${sample}.zarr' > ${sample}.samplesheet_row.csv
    """

    stub:
    """
    mkdir -p ${sample}.zarr
    touch ${sample}.gene_overlap.tsv
    touch ${sample}.annotate_celltypes.timing.tsv

    printf '%s' '${sample},${annotateCelltypesPublishDir(sample)}/${sample}.zarr' > ${sample}.samplesheet_row.csv
    """
}

workflow annotate_celltypes {
    validateAndParseSampleSheet(['sample', 'path'])
        .map { row -> tuple(row.sample, file(row.path)) }
        .set { zarrs }               // tuple(sample, clustered zarr)

    // The committed reference unless --reference names another. Resolved against
    // projectDir, so a run launched from outside the repo still finds it.
    def reference = file(params.reference
        ?: "${projectDir}/assets/reference/shami_human_testis_centroids.csv.gz")

    ANNOTATE_CELLTYPES(zarrs, reference, file("${projectDir}/bin/timer.py"))

    // Handoff samplesheet of the per-sample annotated zarrs.
    ANNOTATE_CELLTYPES.out.samplesheet_row
        .map { it.text }             // read row content so collectFile's sort is deterministic
        .collectFile(name: 'annotate_celltypes_samplesheet.csv', storeDir: params.outdir,
                     seed: 'sample,path', newLine: true, sort: true)
}
