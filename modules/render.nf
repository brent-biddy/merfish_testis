// Directory a render publishes into under reports/. The notebook leads so a listing groups a
// report type together; the run id names the render invocation, not the results tree it read
// -- those are different runs, since a render takes a samplesheet pointing at some earlier
// run's published paths. --report_id replaces both when a render deserves a name of its own,
// and gives up the uniqueness the run id provided; the format is still appended.
//
// The format is part of the name because the two packagings of one notebook are different
// artifacts -- a deck read straight through in a meeting, a directory of pages browsed on
// GitHub -- produced by separate runs. Sharing a name put the fan-out's per-sample pages
// inside the fan-in's own output directory, where they only stayed intact because publishDir
// merges rather than prunes.
//
// Notebook and format are arguments rather than read off params, because a chained run can
// render more than one notebook in a single invocation and there is then no single
// params.notebook or params.to to read.
def reportDir(notebook, format) {
    def base = params.report_id ?: "${file(notebook).baseName}_${params.run_id}"
    format ? "${base}_${format}" : base
}

// Render one notebook. The step knows nothing about what it is rendering: which inputs a
// notebook needs and what it does with them is the notebook's own contract -- it globs what it
// wants out of the staged inputs -- so a new report is a new .qmd and no Nextflow at all.
process QUARTO_RENDER {
    tag "${stem}"

    // Into the repo rather than under params.outdir: this is the one step whose product is
    // source-controlled, and reports/ is committed where results/ is not. 'copy' not 'link'
    // so what git sees is real files, and so the deck survives the work dir being cleaned.
    publishDir { publish_dir }, mode: 'copy'

    input:
    // Everything that varies per render is in the tuple, including the notebook and the
    // format: a chained run renders a cohort deck and per-sample pages in one invocation, and
    // either carried as a separate channel or read from params could not express two values in
    // one run. publish_dir and stem are here for the same reason -- the two modes differ only
    // in those. A directive is a closure evaluated after inputs are bound, which is why
    // publishDir can reference one.
    // Staged flat. Every artifact is named <sample>.<step>.<ext>, so nothing collides -- not
    // two samples, and not two steps -- and a notebook picks its inputs apart by globbing the
    // suffix it wants rather than the workflow naming them into subdirectories.
    tuple val(publish_dir), val(stem), val(format), path(notebook), path(inputs)
    // Quarto resolves reference-doc and filters relative to the qmd's own directory, so both
    // have to land beside the staged notebook rather than at their repo paths. Not in the
    // tuple: they are the same two files for every render.
    path template
    path filter

    output:
    // The whole render as one directory. Quarto writes the document, the deck and the figure
    // directory into --output-dir together, and the links inside the document are relative to
    // it, so the directory is what moves rather than any file in it.
    path "${stem}", emit: report

    script:
    // Omitted, quarto renders every format the notebook declares in one pass, which is still
    // what you want for a report read only one way.
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

// Render specs for one grouping and format, as a channel of QUARTO_RENDER input tuples.
//
// A function rather than a workflow, because only one of the two entry scripts invokes the
// process: a chained run mixes renders into a single QUARTO_RENDER call, which it could not do
// if this invoked the process itself. Building the specs here is what keeps reportDir the only
// definition of a report's publish path.
//
// The two modes exist because the right grouping differs by format. A markdown document is
// navigated by file, so fifteen samples in one page is an enormous scroll where a directory of
// fifteen pages is browsable; a deck is read linearly in a meeting, where one file with fifteen
// sections works and fifteen files is miserable. No conditional in the notebook: it globs what
// was staged, so a fan-in finds fifteen and loops fifteen times, a fan-out finds one and loops
// once.
def renderSpecs(rows, notebook, format, per_sample) {
    if (per_sample) {
        // One render per row, the whole run grouped under one directory. Rows are already one
        // per sample, so fanning out is simply not collecting them.
        return rows.map { row ->
            def publish_dir = "${projectDir}/reports/${reportDir(notebook, format)}"
            tuple(publish_dir, row.sample, format, notebook, pathsOf(row))
        }
    }

    // One render over every row. Sorted by sample rather than collected as they arrive:
    // `collect()` gathers in completion order, so a chained run -- where rows arrive as the
    // previous step's tasks finish -- would order the report's sections differently from one
    // run to the next on the same data.
    return rows
        .toSortedList { a, b -> a.sample <=> b.sample }
        .map { sorted -> sorted.collectMany { row -> pathsOf(row) } }
        .map { paths ->
            tuple("${projectDir}/reports", reportDir(notebook, format), format, notebook, paths)
        }
}

workflow render {
    // Only `sample` is required of a row. Every other column is a path to stage, because which
    // inputs a notebook wants is its own business -- naming them here would make this step
    // specific to one report again.
    take:
    rows

    main:
    // Which mode is read off the step name rather than a flag: --step is where a step's
    // behaviour is documented, so deriving it here keeps steps.nf pure dispatch.
    def per_sample = params.step == 'render_sample'

    QUARTO_RENDER(renderSpecs(rows, file(params.notebook), params.to, per_sample),
                  file("${projectDir}/assets/ouhsc_ppt_template.pptx"),
                  file("${projectDir}/assets/fold-code.lua"))

    emit:
    reports = QUARTO_RENDER.out.report
}

// Every column of a samplesheet row except `sample`, as files to stage.
def pathsOf(Map row) {
    row.findAll { column, value -> column != 'sample' }
       .values()
       .collect { value -> file(value) }
}
