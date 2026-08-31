def pathsOf(Map row) {
    row.findAll { column, value -> column != 'sample' }
       .values()
       .collect { value -> file(value) }
}

def renderSpecs(rows, notebook, format, per_sample) {
    def base = params.report_id ?: "${file(notebook).baseName}_${params.run_id}"
    def report_dir = format ? "${base}_${format}" : base

    if (per_sample) {
        return rows.map { row ->
            tuple("${projectDir}/reports/${report_dir}", row.sample, format, notebook, pathsOf(row))
        }
    }

    return rows
        .toSortedList { a, b -> a.sample <=> b.sample }
        .map { sorted -> sorted.collectMany { row -> pathsOf(row) } }
        .map { paths ->
            tuple("${projectDir}/reports", report_dir, format, notebook, paths)
        }
}

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

    main:
    def per_sample = params.step == 'render_sample'

    def inputs = renderSpecs(rows, file(params.notebook), params.to, per_sample)
    // tuple(publish_dir, stem, format, notebook, staged_paths)

    QUARTO_RENDER(inputs,
                  file("${projectDir}/assets/ouhsc_ppt_template.pptx"),
                  file("${projectDir}/assets/fold-code.lua"))

    emit:
    reports = QUARTO_RENDER.out.report
}
