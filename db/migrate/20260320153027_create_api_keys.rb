class CreateApiKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :api_keys do |t|
      t.references :bearer, polymorphic: true, null: false
      t.string :common_token_prefix, null: false
      t.string :random_token_prefix, null: false
      t.string :token_digest, null: false
      t.datetime :expires_at
      t.datetime :revoked_at

      t.timestamps
    end

    add_index :api_keys, :token_digest, unique: true
  end
end
