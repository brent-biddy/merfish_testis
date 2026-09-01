def isSamplesheet(input) {
    input instanceof java.nio.file.Path || input instanceof String
}

// sample first, then one file per remaining column, in the order given. Without a column
// list, every column a notebook's samplesheet happens to name, which render cannot know.
def samplesFrom(input, List columns = null) {
    if (!isSamplesheet(input)) return input
    channel.fromPath(input)
        .splitCsv(header: true)
        .map { row ->
            def cols = columns ?: ['sample'] + (row.keySet() - 'sample').toList()
            cols.each { c -> if (!row[c]) error "Samplesheet row missing '${c}': ${row}" }
            [row.sample] + cols.tail().collect { file(row[it]) }
        }
}
