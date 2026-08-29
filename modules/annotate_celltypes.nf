// Correlate one sample's cells against the reference cell type centroids.
process ANNOTATE_CELLTYPES {
    tag "${sample}"

    // publish_dir is an input rather than a helper call: the workflow builds it once and
    // carries it back out, so the location this publishes to and the location the next step
    // is told to read are the same string.
    publishDir { publish_dir }, mode: 'copy'

    input:
    tuple val(sample), val(publish_dir), path(zarr)
    path reference
    path 'timer.py'

    output:
    tuple val(sample), val(publish_dir), path("${sample}.annotate_celltypes.zarr"), emit: artifacts
    path "${sample}.gene_overlap.tsv", emit: gene_overlap
    path "${sample}.annotate_celltypes.timing.tsv", emit: timings

    script:
    """
    annotate_celltypes.py --sample ${sample} --path ${zarr} --reference ${reference} --outdir .
    """

    stub:
    """
    mkdir -p ${sample}.annotate_celltypes.zarr
    touch ${sample}.gene_overlap.tsv
    touch ${sample}.annotate_celltypes.timing.tsv
    """
}

workflow annotate_celltypes {
    take:
    // tuple(sample, input path). Both entry points hand over the same shape: main.nf from a
    // samplesheet, the chained script from the previous step's artifacts.
    zarrs

    main:
    // The publish dir is built here and nowhere else. It goes into the process and comes back
    // out with the artifact, so no caller ever reconstructs it.
    zarrs.map { sample, input_path ->
            tuple(sample, "${params.outdir}/${sample}/annotate_celltypes", input_path)
        }
        .set { inputs }

    // The committed reference unless --reference names another. Resolved against projectDir,
    // so a run launched from outside the repo still finds it.
    def reference = file(params.reference
        ?: "${projectDir}/assets/reference/shami_human_testis_centroids.csv.gz")

    ANNOTATE_CELLTYPES(inputs, reference, file("${projectDir}/bin/timer.py"))

    // Handoff samplesheet, built from the channel rather than a row file the task printf'd.
    ANNOTATE_CELLTYPES.out.artifacts
        .map { sample, publish_dir, artifact -> "${sample},${publish_dir}/${artifact.name}" }
        .collectFile(name: 'annotate_celltypes_samplesheet.csv', storeDir: params.outdir,
                     seed: 'sample,path', newLine: true, sort: true)

    emit:
    artifacts = ANNOTATE_CELLTYPES.out.artifacts
}
