
// Basename of both artifacts this step writes. A --group_by run publishes beside a sweep run
// rather than displacing it, so the column goes in the name -- qualifying the stem rather
// than extending it, so `.centroids` stays the last token before the extension and one glob
// takes both. Single-sourced because the output block and the stub must agree.
def centroidStem(sample) {
    params.group_by ? "${sample}.${params.group_by}.centroids" : "${sample}.centroids"
}

// Build per-cluster centroids from one sample's clustered zarr.
process CREATE_CENTROIDS {
    tag "${sample}"

    // publish_dir is an input rather than a helper call: the workflow builds it once and
    // carries it back out, so the location this publishes to and the location the next step
    // is told to read are the same string. A directive is a closure evaluated after inputs
    // are bound, which is why it can reference one — the same reason `tag` above can.
    publishDir { publish_dir }, mode: 'copy'

    input:
    // input_dir rides along as a val because inside the task `zarr` resolves to a staged
    // symlink that means nothing outside this work dir, and the handoff row has to forward a
    // location the next step can still resolve. celltype_report needs both artifacts -- the
    // centroids for gene-level numbers, the zarr for obs and the embeddings.
    //
    // Chained, it arrives as the upstream step's own publish_dir rather than being rebuilt
    // from params.outdir at the call site. That is the whole point of carrying it out.
    tuple val(sample), val(publish_dir), path(zarr), val(input_dir)
    path 'timer.py'

    output:
    tuple val(sample), val(publish_dir), path("${centroidStem(sample)}.h5ad"), val(input_dir), emit: artifacts
    path "${centroidStem(sample)}.timing.tsv", emit: timings

    script:
    def centroidArgs = ["--sample ${sample}", "--path ${zarr}", "--outdir ."]
    // Omitted when unset, so the default stays defined in the script.
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
    // tuple(sample, zarr, the zarr's published location). The third element is what the
    // handoff row forwards; a staged path means nothing outside the task that read it.
    zarrs

    main:
    // The publish dir is built here and nowhere else.
    zarrs.map { sample, zarr, input_dir ->
            tuple(sample, "${params.outdir}/${sample}/create_centroids", zarr, input_dir)
        }
        .set { inputs }

    CREATE_CENTROIDS(inputs, file("${projectDir}/bin/timer.py"))

    // Handoff samplesheet of the per-sample centroid stores. Named for the grouping like the
    // artifacts are, so a --group_by run does not overwrite the sweep's sheet.
    def sheet = params.group_by ? "create_centroids_${params.group_by}" : 'create_centroids'

    // Built from the channel, not from a row file the task printf'd. The published name comes
    // off the output itself, so it cannot drift from what was actually written.
    CREATE_CENTROIDS.out.artifacts
        .map { sample, publish_dir, centroids, input_dir ->
            "${sample},${input_dir},${publish_dir}/${centroids.name}"
        }
        .collectFile(name: "${sheet}_samplesheet.csv", storeDir: params.outdir,
                     seed: 'sample,path,centroid_path', newLine: true, sort: true)

    emit:
    artifacts = CREATE_CENTROIDS.out.artifacts
}
