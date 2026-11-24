() => {
  // Serialize the rendered DOM. Rails only reads the title, description and headings,
  // so drop scripts, styles and embedded documents to keep the capture small.
  const root = document.documentElement.cloneNode(true)
  root.querySelectorAll("script, style, link, iframe, object, embed, template, noscript").forEach((node) => node.remove())
  return { html: "<!doctype html>" + root.outerHTML, url: document.URL }
}
