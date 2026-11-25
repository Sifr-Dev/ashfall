class AddSubjectRefToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :subject_ref, :string, null: false
    add_index :users, :subject_ref, unique: true
  end
end
