# Hangten — Retail Sales Analytics Dashboard

A Phoenix LiveView dashboard for a small retail sales dataset, with a local
LLM (Ollama + qwen3:8b) as its primary interface. Built with Phoenix 1.8,
LiveView, Ecto/MySQL, and Chart.js.

## Requirements

- **Elixir 1.20** with **Erlang/OTP 28**
- **MySQL 8**
- **Ollama** with `qwen3:8b` — optional; only needed for the chat panel.
  The dashboard itself runs fine without it.

## Setup

Create the DB user the app expects (or edit `config/dev.exs`):

```sql
CREATE USER 'hangten'@'localhost' IDENTIFIED BY 'hangten';
GRANT ALL PRIVILEGES ON `hangten%`.* TO 'hangten'@'localhost';
```

Then:

```bash
mix setup          # fetch deps, compile, build assets
mix ecto.setup     # create DB, migrate, seed priv/repo/sales_data.csv (864 rows)
mix phx.server     # http://localhost:4000
```

For the chat:

```bash
ollama pull qwen3:8b
```

The Ollama endpoint/model are configured in `config/config.exs`
(`config :hangten, Hangten.LLM.Ollama, ...`).

## What to look at

| File | What's interesting |
|---|---|
| `lib/hangten/llm/ollama.ex` | Schema-constrained JSON contract: `reply`, `filters`, `sql`, `mutation`, `add_widgets`, `remove_widgets`, `reset_filters` — plus SQL validation, one retry on query errors, and prompt injection of schema/aggregates/alerts/widgets |
| `lib/hangten/llm.ex` + `llm/stub.ex` | Backend facade; the test stub keeps the suite deterministic |
| `lib/hangten/alerts.ex` | Deterministic anomaly detection (margin, duplicates, gaps, outliers, step changes) + scope consolidation ("All South stores") |
| `lib/hangten/sales.ex` | `aggregate/3` — generic dimension × metric rollup that powers LLM-added widgets |
| `lib/hangten_web/live/dashboard_live.ex` | Filters, KPIs, dynamic chart widgets, chat via streams + `start_async`, Apply/Dismiss mutation flow |
| `lib/hangten/seeds.ex` + `application.ex` | Reseeds the CSV on every boot — demo always starts clean |

## What the assistant can do

- **Apply dashboard filters** — "show me east footwear" sets the selects
- **Query real data** — emits a single SELECT (validated, `LIMIT`-wrapped,
  retried once on error); results render as tables in chat
- **Propose writes** — "fix E01's revenue on Jan 6" produces a mutation shown
  as a pending Apply/Dismiss action; nothing writes without a click
- **Reshape the dashboard** — "add a doughnut of margin by store" /
  "remove the region chart" adds/removes Chart.js widgets
- **Surface anomalies** — the alert list (tagged `data_entry` /
  `suspicious` / `business`) is injected into its prompt
- **Follow-ups** — sees the last ~10 messages, plus the on-screen widget list

The data reseeds from the CSV on every restart, so mutations and widget
changes are session-scoped — the demo always returns to a clean state.

## Tests

```bash
mix precommit    # format + warnings-as-errors compile + test
```
