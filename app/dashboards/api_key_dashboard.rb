require "administrate/base_dashboard"

class ApiKeyDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    bearer: Field::Polymorphic.with_options(searchable: true, searchable_field: :email, associated_resource_name: "User"),
    common_token_prefix: Field::String,
    expires_at: Field::DateTime,
    random_token_prefix: Field::String,
    revoked_at: Field::DateTime,
    token_digest: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime,
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    bearer
    common_token_prefix
    expires_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    bearer
    common_token_prefix
    expires_at
    random_token_prefix
    revoked_at
    token_digest
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[
    bearer
    expires_at
    revoked_at
  ].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(api_key)
    "#{api_key.token_prefix}... (#{api_key.bearer_type})"
  end
end
