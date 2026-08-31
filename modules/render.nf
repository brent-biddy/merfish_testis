process QUARTO_RENDER {
    tag "${stem}"

    publishDir { publish_dir }, mode: 'copy'

    input:
    tuple val(publish_dir), val(stem), val(format), path(notebook), path(inputs)
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

    def inputs
    if (per_sample) {
        inputs = rows.map { sample, paths ->
            tuple("${projectDir}/reports/${report_dir}", sample, format, notebook, paths)
        }
    }
    else {
        inputs = rows
            .toSortedList { a, b -> a[0] <=> b[0] }
            .map { sorted ->
                tuple("${projectDir}/reports", report_dir, format, notebook,
                      sorted.collectMany { it[1] })
            }
    }
    // tuple(publish_dir, stem, format, notebook, staged_paths)

    QUARTO_RENDER(inputs,
                  file("${projectDir}/assets/ouhsc_ppt_template.pptx"),
                  file("${projectDir}/assets/fold-code.lua"))

    emit:
    reports = QUARTO_RENDER.out.report
}
