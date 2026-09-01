include { samplesFrom } from './samplesheet'


// Where the producing step published the zarr this run read. Chained, the staged path is a
// work dir the run deletes; every module publishes to ${params.outdir}/<sample>/<step>, and
// <step> is the middle field of the <sample>.<step>.<ext> artifact name.
def publishedSource(sample, zarr) {
    def step = zarr.name.substring("${sample}".length() + 1, zarr.name.lastIndexOf('.'))
    "${params.outdir}/${sample}/${step}/${zarr.name}"
}

def centroidStem(sample) {
    params.group_by ? "${sample}.${params.group_by}.centroids" : "${sample}.centroids"
}

process CREATE_CENTROIDS {
    tag "${sample}"

    publishDir { publish_dir }, mode: 'copy'

    input:
    tuple val(sample), val(publish_dir), path(zarr)
    path 'timer.py'

    output:
    tuple val(sample), val(publish_dir), path("${centroidStem(sample)}.h5ad"), emit: artifacts
    path "${centroidStem(sample)}.timing.tsv", emit: timings

    script:
    def centroidArgs = ["--sample ${sample}", "--path ${zarr}", "--outdir ."]
    if (params.group_by) centroidArgs << "--group_by ${params.group_by}"
    """
    create_centroids.py ${centroidArgs.join(' ')}
    """

    stub:
    """
    touch ${centroidStem(sample)}.h5ad
    touch ${centroidStem(sample)}.timing.tsv
    """
}

workflow create_centroids {
    take:
    // a samplesheet, or tuple(sample, zarr) per sample
    input

    main:
    def ch_zarrs = samplesFrom(input, ['sample', 'path'])

    // A samplesheet's path column is already the published location; a chained run's is not.
    def ch_sources = input instanceof Path || input instanceof String
        ? ch_zarrs.map { sample, zarr -> tuple(sample, zarr.toString()) }
        : ch_zarrs.map { sample, zarr -> tuple(sample, publishedSource(sample, zarr)) }

    ch_zarrs.map { sample, zarr ->
            tuple(sample, "${params.outdir}/${sample}/create_centroids", zarr)
        }
        .set { ch_create_centroids_inputs } // tuple(sample, publish_dir, zarr)

    CREATE_CENTROIDS(ch_create_centroids_inputs, file("${projectDir}/bin/timer.py"))

    def sheet = params.group_by ? "create_centroids_${params.group_by}" : 'create_centroids'

    CREATE_CENTROIDS.out.artifacts
        .join(ch_sources)
        .map { sample, publish_dir, centroids, source ->
            "${sample},${source},${publish_dir}/${centroids.name}"
        }
        .collectFile(name: "${sheet}_samplesheet.csv", storeDir: params.outdir,
                     seed: 'sample,path,centroid_path', newLine: true, sort: true)

    emit:
    artifacts = CREATE_CENTROIDS.out.artifacts
    centroids = CREATE_CENTROIDS.out.artifacts
        .map { sample, publish_dir, centroids -> tuple(sample, centroids) }
}
