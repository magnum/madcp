class CreatePlanTypes < ActiveRecord::Migration[8.1]
  def change
    create_table :plan_types do |t|
      t.string :code
      t.string :name
      t.text :description
      t.decimal :price, precision: 10, scale: 2
      t.integer :days
      t.boolean :is_active
      t.boolean :is_default

      t.timestamps
    end

    add_index :plan_types, :code, unique: true
  end
end
