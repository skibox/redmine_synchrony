class AddSynchronyIdToAttachments < Rails.version < '5.0' ? ActiveRecord::Migration : ActiveRecord::Migration[4.2]
  def change
    add_column :attachments, :synchrony_id, :bigint
    add_index :attachments, :synchrony_id
  end
end