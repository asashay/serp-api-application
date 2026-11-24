() => {
  const rejects = (node) => [...node.querySelectorAll("button")]
    .some((button) => /^\s*reject all\s*$/i.test(button.textContent || ""))
  const dialogs = [...document.querySelectorAll('[role="dialog"], [aria-modal="true"]')].filter(rejects)
  if (!dialogs.length) return false

  const results = document.querySelector("#rso")
  dialogs.forEach((dialog) => dialog.remove())
  // The dialog's backdrop: a fixed layer over the whole viewport.
  for (const node of [...document.body.querySelectorAll("*")]) {
    if (!node.isConnected || (results && node.contains(results))) continue
    const style = getComputedStyle(node)
    const box = node.getBoundingClientRect()
    if (style.position === "fixed" && box.width >= innerWidth * 0.9 && box.height >= innerHeight * 0.9) node.remove()
  }
  // The page under a modal is hidden from assistive technology and cannot scroll.
  for (let node = results; node; node = node.parentElement) {
    node.removeAttribute("inert")
    if (node.getAttribute("aria-hidden") === "true") node.removeAttribute("aria-hidden")
  }
  for (const node of [document.documentElement, document.body]) {
    if (getComputedStyle(node).overflow === "hidden") node.style.overflow = "visible"
  }
  return true
}
