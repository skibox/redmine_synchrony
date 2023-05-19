class AddSynchronyIdToIssues < Rails.version < '5.0' ? ActiveRecord::Migration : ActiveRecord::Migration[4.2]
  def change
    add_column :issues, :synchrony_id, :bigint
    add_index :issues, :synchrony_id
  end
end