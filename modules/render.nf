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
    def report_name = "${file(notebook).baseName}_${params.run_id}"
    if (params.report_id) report_name = params.report_id
    if (format)           report_name = "${report_name}_${format}"

    if (per_sample) {
        publish_dir = "${projectDir}/reports/${report_name}"
        rows.set { specs } // tuple(stem, staged_paths)
    }
    else {
        publish_dir = "${projectDir}/reports"
        rows.toSortedList { a, b -> a[0] <=> b[0] }
            .map { sorted -> tuple(report_name, sorted.collectMany { it[1] }) }
            .set { specs } // tuple(stem, staged_paths)
    }

    QUARTO_RENDER(specs, publish_dir, format, notebook,
                  file("${projectDir}/assets/ouhsc_ppt_template.pptx"),
                  file("${projectDir}/assets/fold-code.lua"))

    emit:
    reports = QUARTO_RENDER.out.report
}
