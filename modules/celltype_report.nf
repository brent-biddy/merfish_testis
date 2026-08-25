// Cell type annotation report over the whole cohort. A terminal fan-in: one task over
// every sample, producing nothing another step consumes, so there is no publish-dir
// helper and no handoff samplesheet.
process CELLTYPE_REPORT {
    tag "CELLTYPE_REPORT"

    // No sample in the path -- one task over the cohort. 'copy' not 'link': the deck is
    // small and is the thing you scp off the cluster, so it should survive the work dir
    // being cleaned.
    publishDir "${params.outdir}/celltype_report", mode: 'copy'

    input:
    // Indexed stageAs is required, not cosmetic: every sample's zarr is published under
    // the same name, so a flat fan-in collides the moment there are two samples.
    path zarrs, stageAs: 'sample*.zarr'
    // The gene-level centroids the cluster similarity figure correlates. Paired back to
    // their zarr inside the notebook on the sample id each object carries, not on the
    // staged order.
    path centroids, stageAs: 'centroids*.h5ad'
    path notebook
    // Quarto resolves reference-doc and filters relative to the qmd's own directory, so
    // both have to land beside the staged notebook rather than at their repo paths.
    path template
    path filter

    output:
    path "celltype_report.pptx", emit: deck
    path "celltype_report.md", emit: document
    path "celltype_report_files", emit: figures

    script:
    """
    quarto render ${notebook} --output-dir .
    """

    stub:
    """
    touch celltype_report.pptx
    touch celltype_report.md
    mkdir -p celltype_report_files
    """
}

workflow celltype_report {
    channel
        .fromPath(params.samplesheet)
        .splitCsv(header: true)      // Map(sample, path, centroid_path)
        .set { rows }

    // Sorted on the sample id so the two lists stay in step with each other, and so the
    // deck's section order does not depend on which task finished first.
    rows.map { row -> tuple(row.sample, file(row.path)) }
        .toSortedList { a, b -> a[0] <=> b[0] }
        .map { pairs -> pairs.collect { it[1] } }
        .set { zarrs }

    rows.map { row -> tuple(row.sample, file(row.centroid_path)) }
        .toSortedList { a, b -> a[0] <=> b[0] }
        .map { pairs -> pairs.collect { it[1] } }
        .set { centroids }

    CELLTYPE_REPORT(
        zarrs,
        centroids,
        file("${projectDir}/notebooks/celltype_report.qmd"),
        file("${projectDir}/assets/ouhsc_ppt_template.pptx"),
        file("${projectDir}/assets/fold-code.lua"),
    )
}
