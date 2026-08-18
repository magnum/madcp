import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["ok", "bad"]
  static values = { url: String }

  // Do not auto-refresh on connect: mutating badge nodes during text selection
  // can trip injected selectionchange handlers (extensions / IDE browser).

  async refresh() {
    if (!this.urlValue) return

    try {
      const url = new URL(this.urlValue, window.location.origin)
      url.searchParams.set("refresh", "1")

      const response = await fetch(url.toString(), {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
      })
      if (!response.ok) return

      const data = await response.json()
      this.applyAuthenticated(!!data.authenticated)
    } catch (_error) {
      // keep last painted state
    }
  }

  applyAuthenticated(authenticated) {
    // Avoid `hidden` + `inline-flex` together: Tailwind display utilities conflict.
    if (this.hasOkTarget) {
      this.okTarget.classList.toggle("hidden", !authenticated)
      this.okTarget.classList.toggle("inline-flex", authenticated)
    }
    if (this.hasBadTarget) {
      this.badTarget.classList.toggle("hidden", authenticated)
      this.badTarget.classList.toggle("inline-flex", !authenticated)
    }
  }
}
