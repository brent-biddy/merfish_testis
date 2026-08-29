include { validateAndParseSampleSheet } from './samplesheet'

// Directory this render publishes into under reports/. Defaults to the notebook and the
// run that produced it: the notebook leads so a listing groups a report type together, and
// the run id ties the render to the results tree it was built from. --report_id replaces
// the whole name. Single-sourced because the output block and the stub must agree.
//
// The format is part of the name because the two packagings of one notebook are different
// artifacts -- a deck read straight through in a meeting, a directory of pages browsed on
// GitHub -- and they are produced by separate runs. Sharing a name put the fan-out's
// per-sample pages inside the fan-in's own output directory, where they only stayed intact
// because publishDir merges rather than prunes.
def reportDir() {
    def base = params.report_id ?: "${file(params.notebook).baseName}_${params.run_id}"
    params.to ? "${base}_${params.to}" : base
}

// Render one notebook over a cohort. A terminal fan-in: one task over every row of the
// samplesheet, producing nothing another step consumes, so there is no publish-dir helper
// and no handoff samplesheet.
//
// The step knows nothing about what it is rendering. Which inputs a notebook needs and
// what it does with them is the notebook's own contract -- it globs what it wants out of
// the staged input directories -- so a new report is a new notebook and no Nextflow at all.
process QUARTO_RENDER {
    tag "${stem}"

    // Into the repo rather than under params.outdir: this is the one step whose product is
    // source-controlled, and reports/ is committed where results/ is not. 'copy' not 'link'
    // so what git sees is real files, and so the deck survives the work dir being cleaned.
    publishDir { publish_dir }, mode: 'copy'

    input:
    // publish_dir and stem are passed in because the two modes differ only in these two
    // values -- see the workflow below. A directive is a closure evaluated after inputs are
    // bound, which is why publishDir can reference one.
    // Staged flat. Every artifact is named <sample>.<step>.<ext>, so nothing collides -- not
    // two samples, and not two steps -- and a notebook picks its inputs apart by globbing the
    // suffix it wants rather than the workflow naming them into subdirectories.
    tuple val(publish_dir), val(stem), path(inputs)
    path notebook
    // Quarto resolves reference-doc and filters relative to the qmd's own directory, so
    // both have to land beside the staged notebook rather than at their repo paths.
    path template
    path filter

    output:
    // The whole render as one directory. Quarto writes the document, the deck and the
    // figure directory into --output-dir together, and the links inside the document are
    // relative to it, so the directory is what moves rather than any file in it.
    path "${stem}", emit: report

    script:
    // --to selects one of the formats the notebook declares. Omitted, quarto renders every
    // one of them in a single pass, which is the old behaviour and still what you want for a
    // report read one way.
    //
    // It exists because the right grouping differs by format. A markdown document is navigated
    // by file, so fifteen samples in one page is an enormous scroll and a directory of fifteen
    // pages is browsable. A deck is read linearly in a meeting, where one file with fifteen
    // sections works and fifteen files is miserable. Same notebook, same content, packaged for
    // how it gets read:
    //
    //   --step render_cohort --to pptx    one deck, every sample
    //   --step render_sample --to gfm     one page per sample
    //
    // No conditional in the notebook: it globs what was staged, so fan-in finds fifteen and
    // loops fifteen times, fan-out finds one and loops once.
    def format = params.to ? "--to ${params.to}" : ""
    """
    quarto render ${notebook} ${format} --output-dir ${stem}
    """

    stub:
    """
    mkdir -p ${stem}/${notebook.baseName}_files
    touch ${stem}/${notebook.baseName}.pptx
    touch ${stem}/${notebook.baseName}.md
    """
}

// One workflow, two steps. The step name says how rows are grouped -- cohort or sample --
// and --to says what comes out of it, so a cohort markdown page or a per-sample deck need
// no new wiring, only the two words that already describe them.
workflow render {
    // Which mode is read off the step name rather than a flag: --step is where a step's
    // behaviour is documented, so deriving it here keeps steps.nf pure dispatch.
    def per_sample = params.step == 'render_sample'

    // Only `sample` is required. Every other column is a path to stage, because which inputs a
    // notebook wants is its own business -- naming them here would make this step specific to
    // one report again.
    validateAndParseSampleSheet(['sample']).set { rows }

    // Assigned in each branch rather than piped out of the if: `if` is a statement in Groovy,
    // not an expression, so it has no value to pipe.
    def renders
    if (per_sample) {
        // One render per row, the whole run grouped under one directory. Rows are already one
        // per sample, so fanning out is simply not collecting them.
        renders = rows.map { row ->
            tuple("${projectDir}/reports/${reportDir()}", row.sample, pathsOf(row))
        }
    } else {
        renders = rows
            .toSortedList { a, b -> a.sample <=> b.sample }
            .map { sorted -> sorted.collectMany { row -> pathsOf(row) } }
            .map { paths -> tuple("${projectDir}/reports", reportDir(), paths) }
    }

    QUARTO_RENDER(
        renders,
        file(params.notebook),
        file("${projectDir}/assets/ouhsc_ppt_template.pptx"),
        file("${projectDir}/assets/fold-code.lua"),
    )
}

// Every column of a samplesheet row except `sample`, as files to stage.
def pathsOf(Map row) {
    row.findAll { column, value -> column != 'sample' }
       .values()
       .collect { value -> file(value) }
}
