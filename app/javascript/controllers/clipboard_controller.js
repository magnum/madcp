import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["source", "button"]
  static values = { copiedLabel: { type: String, default: "Copied" } }

  copy() {
    const value = this.sourceTarget.value || this.sourceTarget.textContent
    if (!value) return

    navigator.clipboard.writeText(value.trim()).then(() => {
      if (!this.hasButtonTarget) return

      const original = this.buttonTarget.textContent
      this.buttonTarget.textContent = this.copiedLabelValue
      window.setTimeout(() => {
        this.buttonTarget.textContent = original
      }, 1500)
    })
  }

  selectAll() {
    if (this.sourceTarget.select) this.sourceTarget.select()
  }
}
