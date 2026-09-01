def isSamplesheet(input) {
    input instanceof java.nio.file.Path || input instanceof String
}

// sample first, then one file per remaining column, in the order given.
def samplesFrom(input, List columns) {
    if (!isSamplesheet(input)) return input
    channel.fromPath(input)
        .splitCsv(header: true)
        .map { row ->
            columns.each { c -> if (!row[c]) error "Samplesheet row missing '${c}': ${row}" }
            [row.sample] + columns.tail().collect { file(row[it]) }
        }
}

// Every column after sample, whatever a notebook's samplesheet happens to name them.
def samplesWithAnyPaths(input) {
    if (!isSamplesheet(input)) return input
    channel.fromPath(input)
        .splitCsv(header: true)
        .map { row ->
            if (!row.sample) error "Samplesheet row missing 'sample': ${row}"
            def sample = row.remove('sample')
            tuple(sample, row.values().collect { file(it) })
        }
}
