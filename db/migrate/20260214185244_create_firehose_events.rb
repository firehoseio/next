class CreateFirehoseEvents < ActiveRecord::Migration[8.2]
  def change
    create_table :firehose_channels do |t|
      t.text :name, null: false
      t.integer :sequence, null: false, default: 0
      t.integer :messages_count, null: false, default: 0
      t.timestamps
    end

    add_index :firehose_channels, :name, unique: true

    create_table :firehose_messages do |t|
      t.references :channel,
        null: false,
        foreign_key: { to_table: :firehose_channels, on_delete: :cascade }
      t.integer :sequence, null: false
      t.text :data, null: false
      t.datetime :created_at, null: false, default: -> { "now()" }
    end

    add_index :firehose_messages, [:channel_id, :sequence], unique: true
  end
end
