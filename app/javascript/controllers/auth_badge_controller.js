import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["ok", "bad"]
  static values = { url: String }

  connect() {
    this.refresh()
  }

  async refresh() {
    if (!this.urlValue) return

    try {
      const response = await fetch(`${this.urlValue}?refresh=1`, {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
      })
      if (!response.ok) return

      const data = await response.json()
      const authenticated = !!data.authenticated
      if (this.hasOkTarget) this.okTarget.classList.toggle("hidden", !authenticated)
      if (this.hasBadTarget) this.badTarget.classList.toggle("hidden", authenticated)
    } catch (_error) {
      // keep last painted state
    }
  }
}
