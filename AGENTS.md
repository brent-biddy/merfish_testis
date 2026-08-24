# Agent instructions

Rules for working in this repository. Everything here is true because it was decided, not
because of how the repo currently looks — **do not add anything that a refactor could
falsify.** A list of the current steps belongs in `README.md`, which is read by people who
will notice when it goes stale. This file is read by a tool that will not.

## The invariants

1. **All executable code lives in `bin/`.** No `scripts/`, no `src/`, no code in `notebooks/`.
2. **Every `bin/*.py` has a complete argparse CLI**, including `--outdir`, and reads and
   writes nothing outside the paths it was given. No hardcoded project paths, no globbing
   a directory the caller did not name.
3. **A step never recomputes a value an earlier step wrote.** It reads the column. If the
   column is missing, it fails and names the step that produces it — never a fallback that
   derives it, which is a second definition of the metric with nothing recording which one
   was used.
4. **Per-stage parameters are declared in the script that applies them** and recorded into
   the output object. Downstream code reads them from the object; it does not restate them.
5. **Adding or renaming a `bin/` script means updating the workflow table in `README.md` in
   the same commit.** That table is the ordering contract — there are no numeric filename
   prefixes to fall back on.
6. **The pipeline layer is additive.** Adding `modules/*.nf` must never require editing a
   script. If it does, the script violated rule 2 and the script is what to fix.

## Conventions

- Python: 4-space indent, `snake_case`, module docstring with a usage example on every script.
- Nextflow: processes `UPPER_SNAKE_CASE`, workflows `snake_case` matching `--step` exactly,
  `script:` blocks never `exec:`, a `stub:` on every process.
- Quarto: reports read metrics, never compute them; inputs are whatever the caller staged
  beside the notebook; the sample id comes from inside the object, never the filename.
- Comment the *why*, never the what. Non-obvious constraints, HPC quirks, format traps.

## Audience

Analysis code here is read by biologists. Prefer plain, legible code over dense idiom:
a loop over a comprehension when the loop is clearer, a named variable over an expression
nested in a call, a library built-in over a hand-written helper.
