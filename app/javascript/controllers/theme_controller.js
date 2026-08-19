import { Controller } from "@hotwired/stimulus"

const STORAGE_KEY = "emcp-theme"

export default class extends Controller {
  toggle() {
    const isDark = document.documentElement.classList.toggle("dark")
    try {
      localStorage.setItem(STORAGE_KEY, isDark ? "dark" : "light")
    } catch (_error) {
      // ignore quota / private mode
    }
  }
}
