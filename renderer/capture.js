() => {
  // Serialize the rendered DOM without scripts or embedded documents. Inline
  // <style> elements stay so the playground preview looks like the page; they
  // load nothing, and Rails sanitizes the preview again before showing it.
  const root = document.documentElement.cloneNode(true)
  root.querySelectorAll("script, link, iframe, object, embed, template, noscript").forEach((node) => node.remove())
  return { html: "<!doctype html>" + root.outerHTML, url: document.URL }
}
