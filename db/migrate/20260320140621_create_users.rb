class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :firstname
      t.string :lastname
      t.string :email, null: false

      t.timestamps
    end

    add_index :users, :email, unique: true
  end
end
