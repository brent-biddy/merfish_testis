include { samplesFrom; isSamplesheet } from './samplesheet'


def centroidStem(sample) {
    params.group_by ? "${sample}.${params.group_by}.centroids" : "${sample}.centroids"
}

process CREATE_CENTROIDS {
    tag "${sample}"

    publishDir { publish_dir }, mode: 'copy'

    input:
    tuple val(sample), val(publish_dir), path(zarr), val(input_dir)
    path 'timer.py'

    output:
    tuple val(sample), val(publish_dir), path("${centroidStem(sample)}.h5ad"), val(input_dir), emit: artifacts
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
    // a samplesheet, or tuple(sample, zarr, the zarr's published location) per sample. The
    // third element records where the zarr this run read is published: from a samplesheet it
    // is the path column itself, and main.nf builds it from the producing step's publish dir.
    input

    main:
    def ch_zarrs = isSamplesheet(input)
        ? samplesFrom(input, ['sample', 'path']).map { sample, zarr -> [sample, zarr, zarr.toString()] }
        : input

    ch_zarrs.map { sample, zarr, input_dir ->
            tuple(sample, "${params.outdir}/${sample}/create_centroids", zarr, input_dir)
        }
        .set { ch_create_centroids_inputs } // tuple(sample, publish_dir, zarr, input_dir)

    CREATE_CENTROIDS(ch_create_centroids_inputs, file("${projectDir}/bin/timer.py"))

    def sheet = params.group_by ? "create_centroids_${params.group_by}" : 'create_centroids'

    CREATE_CENTROIDS.out.artifacts
        .map { sample, publish_dir, centroids, input_dir ->
            "${sample},${input_dir},${publish_dir}/${centroids.name}"
        }
        .collectFile(name: "${sheet}_samplesheet.csv", storeDir: params.outdir,
                     seed: 'sample,path,centroid_path', newLine: true, sort: true)

    emit:
    artifacts = CREATE_CENTROIDS.out.artifacts
    centroids = CREATE_CENTROIDS.out.artifacts
        .map { sample, publish_dir, centroids, input_dir -> tuple(sample, centroids) }
}
