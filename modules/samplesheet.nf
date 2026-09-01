// With a column list, sample first then one file per remaining column, in the order given.
// Without one, sample and every path its row named, which is what a notebook needs: it
// declares what it wants by globbing, so render cannot name the columns.
//
// A channel is returned untouched: steps.nf passes a samplesheet, main.nf a channel already
// carrying one tuple per sample.
def samplesFrom(input, List columns = null) {
    if (!(input instanceof Path || input instanceof String)) return input
    channel.fromPath(input)
        .splitCsv(header: true)
        .map { row ->
            def cols = columns ?: ['sample'] + (row.keySet() - 'sample').toList()
            cols.each { c -> if (!row[c]) error "Samplesheet row missing '${c}': ${row}" }
            def paths = cols.tail().collect { file(row[it]) }
            columns ? [row.sample] + paths : tuple(row.sample, paths)
        }
}
