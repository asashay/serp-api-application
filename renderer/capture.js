() => {
  // Serialize the rendered DOM without scripts or embedded documents. Inline
  // <style> elements stay so the playground preview looks like the page; they
  // load nothing, and Rails sanitizes the preview again before showing it.
  const root = document.documentElement.cloneNode(true)
  root.querySelectorAll("script, link, iframe, object, embed, template, noscript").forEach((node) => node.remove())

  // Structural facts about the live page for the render log: how it is shown
  // and where its styles come from. Counts, sizes and keywords only, never text.
  const shown = (element) => {
    if (!element) return "none"
    const style = getComputedStyle(element)
    return `${style.display}/${style.visibility}/${style.opacity}`
  }
  const height = (selector) => {
    const element = document.querySelector(selector)
    return element ? Math.round(element.getBoundingClientRect().height) : -1
  }
  let cssomRules = 0
  for (const sheet of document.styleSheets) {
    // Rules added through the CSSOM live only in the sheet, not in the HTML.
    if (sheet.ownerNode?.tagName === "STYLE" && !sheet.ownerNode.textContent.trim()) {
      try { cssomRules += sheet.cssRules.length } catch { /* cross-origin sheet */ }
    }
  }
  const probe = {
    html_shown: shown(document.documentElement),
    body_shown: shown(document.body),
    search_h: height("#search"),
    rso_h: height("#rso"),
    text_chars: document.body?.innerText.length ?? 0,
    styles: document.querySelectorAll("style").length,
    stylesheets: document.querySelectorAll("link[rel~=stylesheet]").length,
    cssom_rules: cssomRules,
    adopted_sheets: document.adoptedStyleSheets?.length ?? 0,
  }
  return { html: "<!doctype html>" + root.outerHTML, url: document.URL, probe }
}
