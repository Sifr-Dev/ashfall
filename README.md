# Ashfall

Ashfall is a Rails application for planning verifiable data erasure and retention. It is a technical control for privacy workflows, **not legal advice or a compliance certification**.

The first product component is `Ashfall::Registry`: a validated declaration of which model fields contain personal data, what should happen to them, and why anything is retained. Its output is an immutable plan keyed by a subject token. Delete, pseudonymize, and retain are explicit actions; retained data must have a justification. Unknown or malformed declarations fail closed.

## Environment

- Ruby **4.0.10**, installed and locked through the existing `mise` configuration (`mise.toml`, `mise.lock`).
- Rails **8.1.4.1**, owned by Bundler (`Gemfile.lock`).
- PostgreSQL **18.7** system binaries. Development and test databases use a project-local cluster on port **55432**, not the system service.

The project does not require a second Ruby version manager, a global Rails gem, or a system PostgreSQL service.

## Setup

```sh
mise install --locked
mise exec -- bundle install
mkdir -p .local
initdb -D "$PWD/.local/pgdata" --encoding=UTF8 --locale=C.UTF-8 --auth=trust
pg_ctl -D "$PWD/.local/pgdata" -o "-p 55432 -k $PWD/.local" -l "$PWD/.local/pg.log" start
createdb -h "$PWD/.local" -p 55432 ashfall_development
createdb -h "$PWD/.local" -p 55432 ashfall_test
createdb -h "$PWD/.local" -p 55432 ashfall_queue
mise exec -- bin/rails db:prepare
```

Stop the project-local server when finished:

```sh
pg_ctl -D "$PWD/.local/pgdata" stop
```

`config/master.key` and `.local/` are not committed. The project-local cluster uses trust authentication only on a private Unix socket. Use appropriate authentication and a separate database for any deployed environment.

## Verify

```sh
mise exec -- bin/rails test
mise exec -- bin/rubocop
mise exec -- bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error
```

## Current scope

`config/erasure.example.yml` demonstrates the declaration format. The registry validates it and produces an action plan, but it does **not yet** prove complete schema coverage, delete data, traverse associations, process background jobs, or issue a legal-compliance certificate. Those capabilities need their own tested milestones.

`Ashfall::SchemaAudit` compares declared fields with actual model columns and reports unknown declarations and undeclared columns.

`Ashfall::ErasureExecution` is a trusted service-level workflow, not an unauthenticated web endpoint. Given an explicit subject reference and a validated declaration set, it requires full target-model coverage, applies delete/pseudonymize/retain actions in one PostgreSQL transaction, and returns an immutable receipt with an HMAC-based subject identifier, action outcomes, UTC timestamp, and schema fingerprint. The stored subject reference is replaced with the same pseudonymous token, so a repeat erasure request can use that token without retaining the original reference. A later write failure rolls back earlier changes. There is no association discovery, ActiveStorage erasure, background processing, or compliance certification yet.

`Ashfall::AssociationErasureExecution` adds a deliberately bounded `User has_many :notes` workflow: both model schemas must be fully declared before any write, related note fields are erased in the same transaction, and the receipt identifies the subject without note contents. It does not discover arbitrary associations or claim that `dependent: :destroy` callbacks are a substitute for declared erasure actions.

`Ashfall::ReceiptStore` persists append-only erasure receipts in PostgreSQL. Receipt writes share the erasure transaction, duplicate requests converge on the first evidence row through unique idempotency keys and plan fingerprints, and database triggers reject updates, deletes, and truncation. `Ashfall::DueForErasure` is a bounded internal query that reports when a plan's longest declared retention has elapsed; it is not an unauthenticated deletion endpoint or a legal-compliance decision engine. The receipt retains the plan fingerprint so a changed declaration cannot be mistaken for the plan that actually ran.

`Ashfall::DueForErasure` now verifies every stored receipt before reporting it and returns a `Report` with three explicit buckets: due `entries`, `undatable` receipts whose model is no longer declared, and `unverifiable` receipts that fail their own HMAC and fingerprint check (including a query run with the wrong secret). `Report#complete?` is the fail-closed signal: it is false whenever any evidence was skipped or the result was truncated, so an operator never sees "nothing due" when the honest answer is "cannot tell". The query reads the append-only table only; it never rewrites or deletes evidence.
