class CreateInvitations < ActiveRecord::Migration[8.1]
  def change
    create_table :invitations do |t|
      t.string :state, default: "created", null: false
      t.string :code, null: false
      t.string :signature, null: false
      t.datetime :valid_from, null: false
      t.datetime :valid_to, null: false
      t.datetime :consumed_at

      t.timestamps
    end

    add_index :invitations, :state
    add_index :invitations, :code, unique: true
    add_index :invitations, :signature, unique: true
  end
end
