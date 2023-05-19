class AddSynchronyIdToJournals < Rails.version < '5.0' ? ActiveRecord::Migration : ActiveRecord::Migration[4.2]
  def change
    add_column :journals, :synchrony_id, :bigint
    add_index :journals, :synchrony_id
  end
end