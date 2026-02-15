class CreateFirehoseEvents < ActiveRecord::Migration[8.2]
  def change
    create_table :firehose_events do |t|
      t.text :stream, null: false
      t.text :data, null: false
      t.datetime :created_at, null: false, default: -> { "now()" }
    end

    add_index :firehose_events, [:stream, :id]
  end
end
