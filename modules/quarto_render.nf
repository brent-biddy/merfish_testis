include { validateAndParseSampleSheet } from './samplesheet'

// Directory this render publishes into under reports/. Defaults to the notebook and the
// run that produced it: the notebook leads so a listing groups a report type together, and
// the run id ties the render to the results tree it was built from. --report_id replaces
// the whole name. Single-sourced because the output block and the stub must agree.
def reportDir() {
    params.report_id ?: "${file(params.notebook).baseName}_${params.run_id}"
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
    publishDir "${projectDir}/reports", mode: 'copy'

    input:
    // Passed in rather than read from params inside the process: a helper called from a
    // directive is resolved as a directive, so it has to be an in-scope variable here.
    val stem
    // Staged flat. Every artifact is named <sample>.<step>.<ext>, so nothing collides --
    // not two samples, and not two steps -- and a notebook picks its inputs apart by globbing
    // the suffix it wants rather than the workflow naming them into subdirectories.
    path inputs
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
    """
    quarto render ${notebook} --output-dir ${stem}
    """

    stub:
    """
    mkdir -p ${stem}/${notebook.baseName}_files
    touch ${stem}/${notebook.baseName}.pptx
    touch ${stem}/${notebook.baseName}.md
    """
}

workflow quarto_render {
    // Only `sample` is required. Every other column is a path to stage, because which
    // inputs a notebook wants is its own business -- naming them here would make this step
    // specific to one report again.
    validateAndParseSampleSheet(['sample'])
        .toSortedList { a, b -> a.sample <=> b.sample }
        .map { rows ->
            rows.collectMany { row ->
                row.findAll { column, value -> column != 'sample' }
                   .values()
                   .collect { value -> file(value) }
            }
        }
        .set { inputs }

    QUARTO_RENDER(
        reportDir(),
        inputs,
        file(params.notebook),
        file("${projectDir}/assets/ouhsc_ppt_template.pptx"),
        file("${projectDir}/assets/fold-code.lua"),
    )
}
