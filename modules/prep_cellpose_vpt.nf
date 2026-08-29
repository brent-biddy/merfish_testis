// Convert one sample's bespoke cellpose segmentation to VPT output files.
process PREP_CELLPOSE_VPT {
    tag "${sample}"

    // publish_dir is an input rather than a helper call: the workflow builds it once and
    // carries it back out, so the location this publishes to and the location the next step
    // is told to read are the same string. Here they are literally the same thing — the
    // published directory *is* the VPT directory the next step consumes.
    //
    // The outputs keep VPT's own fixed filenames rather than <sample>.<step>.<ext>: they are
    // read by name by VPT tooling, and they never leave this sample's directory.
    publishDir { publish_dir }, mode: 'copy'

    input:
    // region_path is the samplesheet's own path, carried through for the handoff row:
    // region_dir is the staged name, which says nothing about where the region lives.
    tuple val(sample), val(publish_dir), val(region_path), path(region_dir), path(cellpose_dir)
    path 'timer.py'

    output:
    tuple val(sample), val(publish_dir), val(region_path),
          path("cellpose_*.{csv,parquet}"), emit: artifacts
    path "${sample}.prep_cellpose_vpt.timing.tsv", emit: timings

    script:
    """
    prep_cellpose_vpt.py --sample ${sample} --path ${region_dir} \\
        --cellpose_path ${cellpose_dir} --outdir .
    """

    stub:
    """
    touch cellpose_cell_by_gene.csv cellpose_cell_metadata.csv cellpose_micron_space.parquet
    touch ${sample}.prep_cellpose_vpt.timing.tsv
    """
}

workflow prep_cellpose_vpt {
    take:
    // tuple(sample, region path, cellpose dir). The region path travels as a value as well
    // as a file: the handoff row has to forward where the region lives, and a staged name
    // says nothing about that.
    segmentations

    main:
    // The publish dir is built here and nowhere else.
    segmentations.map { sample, region_path, cellpose_dir ->
            tuple(sample, "${params.outdir}/${sample}/prep_cellpose_vpt",
                  region_path, file(region_path), cellpose_dir)
        }
        .set { inputs }

    PREP_CELLPOSE_VPT(inputs, file("${projectDir}/bin/timer.py"))

    // Handoff samplesheet in create_spatialdata_cellpose's own shape, so that step can be
    // pointed straight at it. vpt_path is this step's publish dir: the directory itself is
    // the artifact.
    PREP_CELLPOSE_VPT.out.artifacts
        .map { sample, publish_dir, region_path, files -> "${sample},${region_path},${publish_dir}" }
        .collectFile(name: 'prep_cellpose_vpt_samplesheet.csv', storeDir: params.outdir,
                     seed: 'sample,path,vpt_path', newLine: true, sort: true)

    emit:
    artifacts = PREP_CELLPOSE_VPT.out.artifacts
}
