class CreatePlans < ActiveRecord::Migration[8.1]
  def change
    create_table :plans do |t|
      t.references :plan_type, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.date :valid_from
      t.date :valid_to

      t.timestamps
    end
  end
end
