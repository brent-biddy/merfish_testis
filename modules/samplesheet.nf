// Rows of --samplesheet, erroring on any row missing one of `required`. Each step maps the
// rows into its own input tuple; only the column check is shared.
def validateAndParseSampleSheet(List required) {
    channel
        .fromPath(params.samplesheet)
        .splitCsv(header: true)
        .map { row ->
            required.each { column ->
                if (!row[column]) error "Samplesheet row missing '${column}': ${row}"
            }
            row
        }
}
