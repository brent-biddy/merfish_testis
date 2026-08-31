// Directory a render publishes into under reports/. The run id names the render invocation, not
// the results tree it read -- a render takes a samplesheet pointing at some earlier run's
// published paths. --report_id replaces it, giving up that uniqueness.
//
// The format is in the name because two packagings of one notebook are separate artifacts;
// sharing a name nested the fan-out's per-sample pages inside the fan-in's output directory.
//
// Arguments rather than params, because a chained run renders more than one notebook in a
// single invocation and there is then no single params.notebook or params.to to read.
def reportDir(notebook, format) {
    def base = params.report_id ?: "${file(notebook).baseName}_${params.run_id}"
    format ? "${base}_${format}" : base
}

// Every column of a samplesheet row except `sample`, as files to stage.
def pathsOf(Map row) {
    row.findAll { column, value -> column != 'sample' }
       .values()
       .collect { value -> file(value) }
}

// Render specs for one grouping and format, as a channel of QUARTO_RENDER input tuples.
//
// A function rather than a workflow, because only one of the two entry scripts invokes the
// process: a chained run mixes renders into a single QUARTO_RENDER call, which it could not do
// if this invoked the process itself.
//
// The two modes exist because the right grouping differs by format: fifteen samples in one
// markdown page is an enormous scroll where a directory of pages is browsable, and a deck read
// in a meeting wants the opposite. The notebook needs no conditional -- it globs what was
// staged, so a fan-in finds fifteen and a fan-out finds one.
def renderSpecs(rows, notebook, format, per_sample) {
    if (per_sample) {
        // Rows are already one per sample, so fanning out is simply not collecting them.
        return rows.map { row ->
            def publish_dir = "${projectDir}/reports/${reportDir(notebook, format)}"
            tuple(publish_dir, row.sample, format, notebook, pathsOf(row))
        }
    }

    // Sorted rather than collected: `collect()` gathers in completion order, so a chained run
    // would order the report's sections differently from one run to the next on the same data.
    return rows
        .toSortedList { a, b -> a.sample <=> b.sample }
        .map { sorted -> sorted.collectMany { row -> pathsOf(row) } }
        .map { paths ->
            tuple("${projectDir}/reports", reportDir(notebook, format), format, notebook, paths)
        }
}

// Render one notebook. The step knows nothing about what it is rendering: a notebook globs what
// it wants out of the staged inputs, so a new report is a new .qmd and no Nextflow at all.
process QUARTO_RENDER {
    tag "${stem}"

    // Into the repo, not params.outdir: reports/ is committed where results/ is not. 'copy' so
    // git sees real files and the deck survives the work dir being cleaned.
    publishDir { publish_dir }, mode: 'copy'

    input:
    // Everything that varies per render is in the tuple, notebook and format included: one
    // invocation renders a cohort deck and per-sample pages, which params cannot express.
    // publishDir can reference publish_dir because a directive is a closure evaluated after
    // inputs are bound. Staged flat -- artifacts are <sample>.<step>.<ext>, so nothing collides.
    tuple val(publish_dir), val(stem), val(format), path(notebook), path(inputs)
    // Quarto resolves reference-doc and filters relative to the qmd's own directory, so both
    // have to land beside the staged notebook. Not in the tuple: the same two files every time.
    path template
    path filter

    output:
    // Quarto writes document, deck and figure directory into --output-dir together with relative
    // links between them, so the directory is what moves rather than any file in it.
    path "${stem}", emit: report

    script:
    // Omitted, quarto renders every format the notebook declares in one pass.
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
    // Only `sample` is required of a row; every other column is a path to stage.
    take:
    rows

    main:
    // Mode off the step name rather than a flag, so steps.nf stays pure dispatch.
    def per_sample = params.step == 'render_sample'

    QUARTO_RENDER(renderSpecs(rows, file(params.notebook), params.to, per_sample),
                  file("${projectDir}/assets/ouhsc_ppt_template.pptx"),
                  file("${projectDir}/assets/fold-code.lua"))

    emit:
    reports = QUARTO_RENDER.out.report
}
