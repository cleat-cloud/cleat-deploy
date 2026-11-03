const STORAGE_KEY = "cleat-theme"
const LEGACY_KEY = "phoenix-paas-theme"

export function currentTheme() {
  try {
    const stored = localStorage.getItem(STORAGE_KEY) || localStorage.getItem(LEGACY_KEY)
    if (stored === "light" || stored === "dark") return stored
  } catch (_error) {
    // ignore
  }
  return "dark"
}

export function applyTheme(theme) {
  const next = theme === "light" ? "light" : "dark"
  document.documentElement.dataset.theme = next

  const meta = document.querySelector('meta[name="theme-color"]')
  if (meta) meta.setAttribute("content", next === "light" ? "#f4f5f8" : "#0a0c12")

  try {
    localStorage.setItem(STORAGE_KEY, next)
  } catch (_error) {
    // ignore
  }

  return next
}

export function toggleTheme() {
  return applyTheme(currentTheme() === "light" ? "dark" : "light")
}

export function initTheme() {
  applyTheme(currentTheme())
}

export const ThemeToggle = {
  mounted() {
    this.sync()
    this.el.addEventListener("click", (event) => {
      event.preventDefault()
      toggleTheme()
      this.sync()
    })
  },
  updated() {
    this.sync()
  },
  sync() {
    const theme = currentTheme()
    const light = theme === "light"
    this.el.setAttribute("aria-pressed", light ? "true" : "false")
    this.el.setAttribute("aria-label", light ? "Switch to dark mode" : "Switch to light mode")
    const sun = this.el.querySelector("[data-theme-icon='sun']")
    const moon = this.el.querySelector("[data-theme-icon='moon']")
    if (sun) sun.classList.toggle("hidden", light)
    if (moon) moon.classList.toggle("hidden", !light)
  },
}
