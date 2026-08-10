# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout

A monorepo of independently published gems, all released together at a single version (currently in each gem's `lib/sentry/**/version.rb`):

- `sentry-ruby` — the core SDK. Everything else builds on it.
- `sentry-rails`, `sentry-sidekiq`, `sentry-resque`, `sentry-delayed_job`, `sentry-opentelemetry` — integration gems.
- `sentry-raven` — the legacy SDK, in maintenance mode. Excluded from RuboCop (`.rubocop.yml`) and generally should not be modified.
- `sentry-ruby-core` — a metagem shell (same source tree, `sentry-ruby-core.gemspec`) that depends on `sentry-ruby` without `concurrent-ruby` pinning.

Integration gemspecs declare `spec.add_dependency "sentry-ruby", "~> <version>"`; `.scripts/batch_release.rb` bumps every version file and rewrites those constraints in lockstep, so never bump one gem alone.

## Commands

Each gem is its own bundle. Always work from inside the gem directory:

```bash
cd sentry-ruby && bundle install
bundle exec rake                    # default task: specs (+ isolated specs where defined)
bundle exec rspec spec/sentry/hub_spec.rb            # single file
bundle exec rspec spec/sentry/hub_spec.rb:42         # single example
bundle exec rspec spec/isolated/puma_spec.rb         # isolated spec, must run in its own process
```

RuboCop runs from the **repo root** across all gems: `bundle exec rubocop` (config inherits `rubocop-rails-omakase`).

`spec/isolated/**` is excluded from the `:spec` task because those specs need a pristine process. `sentry-ruby` runs them via `bundle exec rspec <file>`; `sentry-rails` via `bundle exec ruby <file>` (see each `Rakefile`).

### Dependency matrix env vars

Gemfiles read env vars to pick dependency versions — the same knobs CI uses:

- `sentry-ruby`: `RACK_VERSION` (default `3.0`; `0` means no Rack at all), `REDIS_RB_VERSION` (default `5.0`)
- `sentry-rails`: `RAILS_VERSION` (default `7.1.0`; `>= 7.2.0.alpha` pulls Rails from git)
- `sentry-sidekiq`: `SIDEKIQ_VERSION` (default `7.0`)
- `sentry-resque`: `BUNDLE_GEMFILE=Gemfile_with_rails.rb` for the with-Rails variant

Changing one of these requires re-running `bundle install`.

External services: a running **Redis** is needed for `sentry-ruby` (`spec_helper` requires `redis`) and `sentry-sidekiq`. `sentry-rails` specs need sqlite3 and ImageMagick (ActiveStorage variant tests).

CI also runs one matrix entry with `RUBYOPT="--enable-frozen-string-literal --debug=frozen-string-literal"`, so new core files should carry `# frozen_string_literal: true` and avoid mutating literals.

### Runnable examples

`sentry-ruby/examples/*`, `sentry-rails/examples/*`, `sentry-<gem>/example/*` are small apps for manual verification (replace the DSN first). `sentry-ruby/benchmarks` and `sentry-rails/benchmarks` hold benchmark-ips scripts.

## Core architecture (`sentry-ruby`)

### Hub / Scope / Client layering

`Sentry.init` (in `lib/sentry-ruby.rb`) builds a `Configuration`, applies patches, then constructs `Client` → `Scope` → `Hub` and stores the hub in a **thread variable** (`Thread.current.thread_variable_set(:sentry_hub, hub)`), also keeping it as `@main_hub`.

- `Hub` (`lib/sentry/hub.rb`) is a stack of `Layer` structs, each pairing a client and a scope. `push_scope`/`pop_scope` (and `with_scope`) dup the scope so mutations are undone on pop. New threads get a copy via `Sentry.clone_hub_to_current_thread` — without that, a spawned thread has no hub and top-level APIs are no-ops.
- `Scope` (`lib/sentry/scope.rb`) holds contextual data (tags, user, extra, contexts, breadcrumbs, fingerprint, transaction name, current span, propagation context) and merges it into events in `apply_to_event`, which is also where global + scope-level event processors run and where the `trace` context / dynamic sampling context is attached.
- `Client` (`lib/sentry/client.rb`) turns exceptions/messages into `Event`s, applies the scope, honors `sample_rate` / `before_send` / `before_send_transaction`, and hands off to the transport — usually asynchronously through `Sentry.background_worker`.
- `Transport` (`lib/sentry/transport.rb` + `transport/http_transport.rb`, `dummy_transport.rb`, `spotlight_transport.rb`) serializes events into `Envelope`s, enforces rate limits from Sentry's response headers, and records client reports (`record_lost_event`).

Every top-level `Sentry.*` API is a thin guard-and-delegate over the current hub and short-circuits with `return unless initialized?`. Keep that pattern when adding APIs.

### Event types

`Event` is the base; `ErrorEvent`, `TransactionEvent`, and `CheckInEvent` are the concrete kinds, each mapping to an envelope item data category. Interfaces under `lib/sentry/interfaces/` (exception, single_exception, mechanism, stacktrace, request, threads) build the payload sections; `StacktraceBuilder` + `LineCache` produce frames and source context.

### Tracing

`Transaction` (a root `Span`) and `Span` implement performance monitoring. When no transaction is active, `PropagationContext` still supplies trace ids so errors can be correlated; `Baggage` carries the dynamic sampling context. `sentry-trace` / `baggage` headers are read via `Sentry.continue_trace` and written via `get_trace_propagation_headers` / `get_trace_propagation_meta`. `config.instrumenter` selects `:sentry` or `:otel` — with `:otel`, spans come from `sentry-opentelemetry` instead of the SDK's own instrumentation.

### Background threads

Several long-lived workers are created in `Sentry.init` and torn down in `Sentry.close`: `BackgroundWorker` (event sending, `concurrent-ruby` thread pool sized from `background_worker_threads`), plus `ThreadedPeriodicWorker` subclasses `SessionFlusher`, `BackpressureMonitor`, and `Metrics::Aggregator`. `Profiler` uses stackprof. Tests that assert on send behavior normally set `background_worker_threads = 0` to make sending synchronous.

### Patches vs. integrations — two distinct mechanisms

**Patches** are opt-in monkey-patches of third-party libraries, registered at load time and applied during `Sentry.init`:

```ruby
Sentry.register_patch(:http, Sentry::Net::HTTP, Net::HTTP)   # prepend a module
Sentry.register_patch(:graphql) { |config| ... }             # or run arbitrary setup
```

Only keys present in `config.enabled_patches` are applied. `DEFAULT_PATCHES = %i[redis puma http]`; anything else (e.g. `:graphql`) must be added by the user via `config.enabled_patches += [...]`. Requires that may fail (`sentry/rake`, `sentry/rack`) are wrapped in `rescue LoadError`, so patch files must tolerate the target library being absent and warn rather than raise.

**Integrations** are the extension gems themselves. Per `EXTENSION.md`, an extension gem does:

```ruby
module Sentry
  module Rails
    extend Integrable
    register_integration name: "rails", version: Sentry::Rails::VERSION
  end
end
```

This generates `Sentry::Rails.capture_exception` / `.capture_message`, which tag events with `hint[:integration]` and the integration's SDK meta. **Integration code must capture through those generated helpers, not `Sentry.capture_exception`.** Integrations must be required *before* `Sentry.init` or the SDK logs a warning.

Integrations extend configuration by adding a nested config object plus a post-initialization callback (`Configuration.add_post_initialization_callback`), which is how `config.rails.*`, `config.sidekiq.*`, etc. appear — see `sentry-rails/lib/sentry/rails/configuration.rb`.

### Test helper

`Sentry::TestHelper` (`lib/sentry/test_helper.rb`) is shipped to users and used by the SDK's own specs (`config.include(Sentry::TestHelper)` in `sentry-ruby/spec/spec_helper.rb`). `setup_sentry_test` swaps in a dummy DSN + `DummyTransport` and pushes a scope layer; `teardown_sentry_test` pops it. Captured events are read with `sentry_events` / `last_sentry_event` / `sentry_envelopes`. Note that `sentry-rails` and the other integration gems do *not* include it globally — they set up clients per spec.

## `sentry-rails` specifics

`Sentry::Railtie` is where nearly all wiring lives:

- Middleware must be inserted in an `initializer` (can't be added after boot): `Sentry::Rails::CaptureExceptions` goes after `ActionDispatch::ShowExceptions` (so static-file requests don't create transactions), and `RescuedExceptionInterceptor` after `ActionDispatch::DebugExceptions` (to see exceptions Rails has rescued, including from middlewares).
- ActiveJob and ActionCable extensions are prepended in initializers `before: :eager_load!` — ordering matters so the SDK's `around_perform` registers before user callbacks.
- Everything else (project root, trusted proxies, cron timezone, controller methods, backtrace cleaner, breadcrumb loggers, tracing activation, Rails 7 `error_subscriber`) happens in `config.after_initialize`, guarded by `next unless Sentry.initialized?`.

Tracing uses `ActiveSupport::Notifications` subscribers under `lib/sentry/rails/tracing/` (`AbstractSubscriber` + per-component subscribers). Specs must leave no subscriptions behind — `spec_helper` asserts `Sentry::Rails::Tracing.subscribed_tracing_events` is empty after each example.

Specs run against a dummy Rails app assembled in `spec/dummy/test_rails_app/` rather than a generated app.

## Conventions

- **Changelog:** add entries to the **root `CHANGELOG.md`** under `## Unreleased`, with a PR link. Per-gem `CHANGELOG.md` files are deprecated and frozen — don't add to them.
- **Ruby support floor is 2.4** (plus JRuby 9.x), enforced in every gemspec. Avoid syntax and stdlib methods newer than that in shipped `lib/` code; version-gate with `RUBY_VERSION` checks when necessary (Gemfiles already do this for dev dependencies).
- Public API methods carry YARD docs; internal ones are marked `# @!visibility private`. Keep that distinction — the docs are published to rubydoc.info.
- Indent with 2 spaces; `editor.formatOnSave` is deliberately disabled for Ruby in `.vscode/settings.json` because ruby-lsp's formatter doesn't match this project's style.
- Commits are squashed on merge; PRs are expected to include tests and a changelog entry, and refactoring should be a separate commit.
