process ANNOTATE_CELLTYPES {
    tag "${sample}"

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
    zarrs

    main:
    zarrs.map { sample, input_path ->
            tuple(sample, "${params.outdir}/${sample}/annotate_celltypes", input_path)
        }
        .set { inputs } // tuple(sample, publish_dir, zarr)

    def reference = file(params.reference
        ?: "${projectDir}/assets/reference/shami_human_testis_centroids.csv.gz")

    ANNOTATE_CELLTYPES(inputs, reference, file("${projectDir}/bin/timer.py"))

    ANNOTATE_CELLTYPES.out.artifacts
        .map { sample, publish_dir, artifact -> "${sample},${publish_dir}/${artifact.name}" }
        .collectFile(name: 'annotate_celltypes_samplesheet.csv', storeDir: params.outdir,
                     seed: 'sample,path', newLine: true, sort: true)

    emit:
    artifacts = ANNOTATE_CELLTYPES.out.artifacts
}
