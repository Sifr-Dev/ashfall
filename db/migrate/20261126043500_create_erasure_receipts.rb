# frozen_string_literal: true

# Erasure receipts are the durable evidence that a declared erasure plan ran.
# Two unique indexes protect that evidence:
#
# * the plan key (subject token, model name, schema fingerprint) ensures one
#   receipt per executed plan, so a repeated request cannot inflate the record;
# * the idempotency key ensures one receipt per request, even if the plan
#   changed between retries.
#
# Triggers reject UPDATE and DELETE for every row, and reject TRUNCATE while
# the table still holds evidence (an empty table may be reset, which keeps test
# setup simple without weakening the guard for real data).
#
# The project uses db/structure.sql because these triggers and constraints are
# not representable in schema.rb; a schema.rb build would silently lose the
# append-only boundary.
class CreateErasureReceipts < ActiveRecord::Migration[8.1]
  def up
    create_table :erasure_receipts do |t|
      t.string :subject_token, null: false
      t.string :model, null: false
      t.string :schema_fingerprint, null: false
      t.string :idempotency_key, null: false
      t.jsonb :actions, null: false, default: []
      t.datetime :completed_at, null: false
      t.string :fingerprint, null: false
      t.string :signature, null: false

      t.timestamps
    end

    add_index :erasure_receipts, [ :subject_token, :model, :schema_fingerprint ], unique: true, name: "index_erasure_receipts_on_plan_key"
    add_index :erasure_receipts, :idempotency_key, unique: true

    add_check_constraint :erasure_receipts,
      "subject_token ~ '^ashfall:[0-9a-f]{64}$'",
      name: "erasure_receipts_subject_token_format"
    add_check_constraint :erasure_receipts,
      "model ~ '^[A-Z][A-Za-z0-9_:]*$'",
      name: "erasure_receipts_model_format"
    add_check_constraint :erasure_receipts,
      "schema_fingerprint ~ '^[0-9a-f]{64}$'",
      name: "erasure_receipts_schema_fingerprint_format"
    add_check_constraint :erasure_receipts,
      "idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$'",
      name: "erasure_receipts_idempotency_key_format"
    add_check_constraint :erasure_receipts,
      "fingerprint ~ '^[0-9a-f]{64}$'",
      name: "erasure_receipts_fingerprint_format"
    add_check_constraint :erasure_receipts,
      "signature ~ '^[0-9a-f]{64}$'",
      name: "erasure_receipts_signature_format"
    add_check_constraint :erasure_receipts,
      "jsonb_typeof(actions) = 'array'",
      name: "erasure_receipts_actions_array"

    execute <<~SQL
      CREATE FUNCTION ashfall_erasure_receipts_row_append_only()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        RAISE EXCEPTION 'erasure_receipts is append-only (% rejected)', TG_OP
          USING ERRCODE = 'restrict_violation';
      END;
      $$;

      CREATE TRIGGER erasure_receipts_row_append_only
        BEFORE UPDATE OR DELETE ON erasure_receipts
        FOR EACH ROW EXECUTE FUNCTION ashfall_erasure_receipts_row_append_only();

      CREATE FUNCTION ashfall_erasure_receipts_truncate_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF EXISTS (SELECT 1 FROM erasure_receipts) THEN
          RAISE EXCEPTION 'erasure_receipts holds evidence and cannot be truncated'
            USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN NULL;
      END;
      $$;

      CREATE TRIGGER erasure_receipts_truncate_guard
        BEFORE TRUNCATE ON erasure_receipts
        FOR EACH STATEMENT EXECUTE FUNCTION ashfall_erasure_receipts_truncate_guard();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS erasure_receipts_truncate_guard ON erasure_receipts;
      DROP TRIGGER IF EXISTS erasure_receipts_row_append_only ON erasure_receipts;
      DROP FUNCTION IF EXISTS ashfall_erasure_receipts_truncate_guard();
      DROP FUNCTION IF EXISTS ashfall_erasure_receipts_row_append_only();
    SQL
    drop_table :erasure_receipts
  end
end
