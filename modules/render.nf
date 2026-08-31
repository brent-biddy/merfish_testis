process QUARTO_RENDER {
    tag "${stem}"

    publishDir { publish_dir }, mode: 'copy'

    input:
    tuple val(stem), path(staged)
    val publish_dir
    val format
    path notebook
    path template
    path filter

    output:
    path "${stem}", emit: report

    script:
    def to = format ? "--to ${format}" : ""
    """
    quarto render ${notebook} ${to} --output-dir ${stem}
    """

    stub:
    """
    mkdir -p ${stem}/${notebook.baseName}_files
    touch ${stem}/${notebook.baseName}.pptx
    touch ${stem}/${notebook.baseName}.md
    """
}

workflow render {
    take:
    rows
    notebook
    format
    per_sample

    main:
    def base = params.report_id ?: "${file(notebook).baseName}_${params.run_id}"
    def report_dir = format ? "${base}_${format}" : base

    def publish_dir
    def specs
    if (per_sample) {
        publish_dir = "${projectDir}/reports/${report_dir}"
        specs = rows
    }
    else {
        publish_dir = "${projectDir}/reports"
        specs = rows
            .toSortedList { a, b -> a[0] <=> b[0] }
            .map { sorted -> tuple(report_dir, sorted.collectMany { it[1] }) }
    }
    // tuple(stem, staged_paths)

    QUARTO_RENDER(specs, publish_dir, format ?: '', notebook,
                  file("${projectDir}/assets/ouhsc_ppt_template.pptx"),
                  file("${projectDir}/assets/fold-code.lua"))

    emit:
    reports = QUARTO_RENDER.out.report
}
