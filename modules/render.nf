process QUARTO_RENDER {
    tag "${output_dir}"

    publishDir { publish_dir }, mode: 'copy'

    input:
    tuple val(output_dir), path(staged)
    val publish_dir
    val format
    path notebook
    path pptx_template_file
    path gfm_code_fold_filter

    output:
    path "${output_dir}", emit: report

    script:
    """
    quarto render ${notebook} --to ${format} --output-dir ${output_dir}
    """

    stub:
    """
    mkdir -p ${output_dir}/${notebook.baseName}_files
    touch ${output_dir}/${notebook.baseName}.pptx
    touch ${output_dir}/${notebook.baseName}.md
    """
}

workflow render {
    take:
    ch_samples
    val_qmd_file
    val_quarto_format
    val_per_sample

    main:
    // <qmd basename>_<run_id>_<format>, e.g. celltype_report_20260831_143022_pptx
    def report_name = "${file(val_qmd_file).baseName}_${params.run_id}_${val_quarto_format}"

    if (val_per_sample) {   // -> reports/<report_name>/<sample>/, one render per sample
        publish_dir = "${projectDir}/reports/${report_name}"
        ch_samples.set { ch_quarto_render_inputs } // tuple(output_dir, staged_paths)
    }
    else {                  // -> reports/<report_name>/, one render over all samples
        publish_dir = "${projectDir}/reports"
        ch_samples.toSortedList { a, b -> a[0] <=> b[0] }
            .map { sorted -> tuple(report_name, sorted.collectMany { it[1] }) }
            .set { ch_quarto_render_inputs } // tuple(output_dir, staged_paths)
    }

    QUARTO_RENDER(ch_quarto_render_inputs, publish_dir, val_quarto_format, val_qmd_file,
                  file("${projectDir}/assets/ouhsc_ppt_template.pptx"),
                  file("${projectDir}/assets/fold-code.lua"))

    emit:
    reports = QUARTO_RENDER.out.report
}
