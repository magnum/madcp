# frozen_string_literal: true

require "administrate/base_dashboard"

class McpServerDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    code: Field::String,
    type: Field::String,
    name: Field::String,
    description: Field::Text,
    version: Field::String,
    allow_write: Field::Boolean,
    oauth_token_retrieval: Field::Boolean,
    created_at: Field::DateTime,
    updated_at: Field::DateTime,
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id code name allow_write].freeze
  SHOW_PAGE_ATTRIBUTES = %i[
    id code type name description version allow_write oauth_token_retrieval created_at updated_at
  ].freeze
  FORM_ATTRIBUTES = %i[name description version allow_write].freeze
  COLLECTION_FILTERS = {}.freeze
end
