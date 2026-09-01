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

// sample first, then one file per remaining column, in the order given.
def sampleFiles(List columns) {
    validateAndParseSampleSheet(columns)
        .map { row -> [row.sample] + columns.tail().collect { file(row[it]) } }
}

def samplePathPairs()      { sampleFiles(['sample', 'path']) }
def sampleRegionCellpose() { sampleFiles(['sample', 'path', 'cellpose_path']) }
def sampleRegionVpt()      { sampleFiles(['sample', 'path', 'vpt_path']) }

def samplePathWithSource() {
    sampleFiles(['sample', 'path']).map { sample, path -> [sample, path, path.toString()] }
}

def sampleWithPaths() {
    validateAndParseSampleSheet(['sample'])
        .map { row ->
            def sample = row.remove('sample')
            tuple(sample, row.values().collect { file(it) })
        }
}
