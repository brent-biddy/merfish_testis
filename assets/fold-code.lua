-- Fold every code chunk behind a <details>, for the gfm render only.
--
-- Quarto's own code-fold option is HTML-only, but GitHub renders raw <details> in a
-- markdown file, so the fold is written here as raw HTML instead. A fenced block inside
-- <details> only renders as code if a blank line separates it from the <summary>, which
-- is what pandoc writes between two blocks anyway.
--
-- Registered under the gfm format in the frontmatter, so the pptx render never sees it.
-- cell-code is the class quarto puts on a chunk's source. The stdout a chunk prints is a
-- code block too, and belongs in the document unfolded, so the class is what separates them.
function CodeBlock(block)
  if not block.classes:includes("cell-code") then
    return nil
  end

  return {
    pandoc.RawBlock("html", "<details>\n<summary>Code</summary>"),
    block,
    pandoc.RawBlock("html", "</details>"),
  }
end
