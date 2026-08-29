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

// prep_cellpose_vpt's shape: the region as a value as well as a file, because its handoff
// row forwards where the region lives, plus the bespoke cellpose directory.
def sampleRegionCellpose() {
    validateAndParseSampleSheet(['sample', 'path', 'cellpose_path'])
        .map { row -> tuple(row.sample, row.path, file(row.cellpose_path)) }
}

// create_spatialdata_cellpose's shape: the region and the VPT directory prep produced.
def sampleRegionVpt() {
    validateAndParseSampleSheet(['sample', 'path', 'vpt_path'])
        .map { row -> tuple(row.sample, file(row.path), file(row.vpt_path)) }
}
