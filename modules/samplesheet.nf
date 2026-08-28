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

// The shape every per-sample step takes: tuple(sample, input path). Defined once so main.nf
// stays dispatch and each converted module's `take:` gets the same thing from either caller.
def samplePathPairs() {
    validateAndParseSampleSheet(['sample', 'path'])
        .map { row -> tuple(row.sample, file(row.path)) }
}

// create_centroids also needs the input's published location, because the handoff row it
// writes has to forward something that resolves outside the task that read it.
def samplePathWithSource() {
    validateAndParseSampleSheet(['sample', 'path'])
        .map { row -> tuple(row.sample, file(row.path), row.path) }
}
