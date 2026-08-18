# frozen_string_literal: true

require "administrate/base_dashboard"

class InvitationDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    code: Field::String,
    signature: Field::String,
    valid_from: Field::DateTime,
    valid_to: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime,
    state: Field::Aasm.with_options(searchable: true, searchable_field: :name),
    consumed_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    state
    code
    valid_from
    valid_to
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    state
    code
    signature
    valid_from
    valid_to
    created_at
    updated_at
    consumed_at
  ].freeze

  FORM_ATTRIBUTES = %i[
    valid_from
    valid_to
    code
  ].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(invitation)
    "Invitation ##{invitation.id} (#{invitation.code})"
  end
end
