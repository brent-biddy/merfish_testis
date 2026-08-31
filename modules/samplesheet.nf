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

def samplePathPairs() {
    validateAndParseSampleSheet(['sample', 'path'])
        .map { row -> tuple(row.sample, file(row.path)) }
}

def samplePathWithSource() {
    validateAndParseSampleSheet(['sample', 'path'])
        .map { row -> tuple(row.sample, file(row.path), row.path) }
}

def sampleRegionCellpose() {
    validateAndParseSampleSheet(['sample', 'path', 'cellpose_path'])
        .map { row -> tuple(row.sample, row.path, file(row.cellpose_path)) }
}

def sampleRegionVpt() {
    validateAndParseSampleSheet(['sample', 'path', 'vpt_path'])
        .map { row -> tuple(row.sample, file(row.path), file(row.vpt_path)) }
}
