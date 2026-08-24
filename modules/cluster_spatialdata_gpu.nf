include { validateAndParseSampleSheet } from './samplesheet'

// Published output directory for this step's per-sample artifacts. Used by the publishDir
// directive and the emitted samplesheet row, so the two cannot drift apart.
def clusterSpatialdataGpuPublishDir(sample) {
    "${params.outdir}/${sample}/cluster_spatialdata_gpu"
}

// GPU-accelerated filter, normalize, and Leiden sweep on one sample's SpatialData zarr.
process CLUSTER_SPATIALDATA_GPU {
    tag "${sample}"

    // pattern publishes the zarr store and the timing TSV; it leaves out
    // <sample>.samplesheet_row.csv.
    publishDir { clusterSpatialdataGpuPublishDir(sample) },
        mode: 'copy',
        pattern: '*.{zarr,tsv}'

    input:
    // stageAs: the input store is named <sample>.zarr too, and would collide with the
    // output of the same name in the task work dir.
    tuple val(sample), path(zarr, stageAs: 'input.zarr')
    path 'timer.py'

    output:
    tuple val(sample), path("${sample}.zarr"), emit: artifacts
    path "${sample}.cluster_spatialdata_gpu.timing.tsv", emit: timings
    // One `sample,path` line pointing at the published zarr.
    // main.nf collects these into a handoff samplesheet.
    path "${sample}.samplesheet_row.csv", emit: samplesheet_row

    script:
    """
    cluster_spatialdata_gpu.py --sample ${sample} --path ${zarr} --outdir .

    printf '%s' '${sample},${clusterSpatialdataGpuPublishDir(sample)}/${sample}.zarr' > ${sample}.samplesheet_row.csv
    """

    stub:
    """
    mkdir -p ${sample}.zarr
    touch ${sample}.cluster_spatialdata_gpu.timing.tsv

    printf '%s' '${sample},${clusterSpatialdataGpuPublishDir(sample)}/${sample}.zarr' > ${sample}.samplesheet_row.csv
    """
}

workflow cluster_spatialdata_gpu {
    validateAndParseSampleSheet(['sample', 'path'])
        .map { row -> tuple(row.sample, file(row.path)) }
        .set { zarrs }               // tuple(sample, zarr)

    CLUSTER_SPATIALDATA_GPU(zarrs, file("${projectDir}/bin/timer.py"))

    // Handoff samplesheet of the per-sample clustered zarrs.
    CLUSTER_SPATIALDATA_GPU.out.samplesheet_row
        .map { it.text }             // read row content so collectFile's sort is deterministic
        .collectFile(name: 'cluster_spatialdata_gpu_samplesheet.csv', storeDir: params.outdir,
                     seed: 'sample,path', newLine: true, sort: true)
}
