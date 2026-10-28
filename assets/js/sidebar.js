const STORAGE_KEY = "cleat-sidebar"

export function currentSidebar() {
  try {
    const stored = localStorage.getItem(STORAGE_KEY)
    if (stored === "hidden" || stored === "shown") return stored
  } catch (_error) {
    // ignore
  }
  return "shown"
}

export function applySidebar(state) {
  const next = state === "hidden" ? "hidden" : "shown"
  document.documentElement.dataset.sidebar = next

  try {
    localStorage.setItem(STORAGE_KEY, next)
  } catch (_error) {
    // ignore
  }

  return next
}

export function initSidebar() {
  applySidebar(currentSidebar())
}

export const SidebarToggle = {
  mounted() {
    this.apply(currentSidebar())
    this.el.addEventListener("click", (event) => {
      event.preventDefault()
      this.apply(currentSidebar() === "hidden" ? "shown" : "hidden")
    })
  },
  updated() {
    this.apply(currentSidebar())
  },
  apply(state) {
    const hidden = state === "hidden"
    const shell = document.getElementById("app-shell")
    if (shell) shell.classList.toggle("paas-shell--sidebar-collapsed", hidden)
    applySidebar(hidden ? "hidden" : "shown")
    const label = hidden ? "Show sidebar" : "Hide sidebar"
    this.el.setAttribute("aria-expanded", hidden ? "false" : "true")
    this.el.setAttribute("aria-label", label)
    this.el.setAttribute("title", label)
  },
}
