defmodule Hangten.LLM.Ollama do
  @moduledoc """
  Ollama chat backend. Prompts the model to reply as JSON matching the
  `Hangten.LLM` contract:

      {"reply": string, "filters": object | "reset" | null}

  Ollama's `format: "json"` constrains decoding to valid JSON, and
  `sanitize_filters/1` whitelists keys and canonicalizes enum values, so
  malformed model output degrades gracefully.
  """

  alias Hangten.Sales

  @filter_keys ~w(region category store_id from to)

  def answer(question, history \\ [], context \\ %{}) do
    case chat(question, history, context) do
      {:ok, %{content: content, thinking: thinking}} ->
        {:ok,
         content
         |> parse_response()
         |> Map.put(:thinking, thinking)
         |> maybe_retry(question)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_retry(%{query_result: %{error: _}} = response, question) do
    feedback = """
    Your answer to "#{question}" used this SQL:

    #{response.sql}

    It failed with: #{response.query_result.error}

    Emit a corrected query in "sql" following the same JSON schema.
    """

    case chat(feedback, []) do
      {:ok, content} ->
        retried = parse_response(content)

        case retried.query_result do
          %{error: _} ->
            response

          _ ->
            %{response | text: retried.text, query_result: retried.query_result, sql: retried.sql}
        end

      {:error, _reason} ->
        response
    end
  end

  defp maybe_retry(response, _question), do: response

  defp chat(question, history, context \\ %{}) do
    {base_url, model} = config()

    messages =
      [%{role: "system", content: system_prompt(context)}] ++
        Enum.take(history, -10) ++
        [%{role: "user", content: question}]

    body = %{
      model: model,
      think: true,
      stream: false,
      format: response_schema(),
      keep_alive: "30m",
      messages: messages
    }

    case Req.post("#{base_url}/api/chat", json: body, receive_timeout: 180_000) do
      {:ok, %{status: 200, body: %{"message" => message}}} ->
        {:ok, %{content: message["content"], thinking: message["thinking"]}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_response(content) do
    case Jason.decode(content) do
      {:ok, %{"reply" => reply} = decoded} when is_binary(reply) ->
        sql = decoded["sql"]

        %{
          text: reply,
          filters: parse_filters(decoded["filters"], decoded["reset_filters"]),
          sql: sql,
          query_result: run_query(sql),
          mutation: sanitize_mutation(decoded["mutation"]),
          add_widgets: sanitize_widgets(decoded["add_widgets"]),
          remove_widgets: sanitize_ids(decoded["remove_widgets"])
        }

      _ ->
        %{text: content, filters: nil}
    end
  end

  defp parse_filters(_filters, true), do: :reset

  defp parse_filters(filters, _reset) when is_map(filters) do
    filters
    |> Map.take(@filter_keys)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
    |> canonicalize(:region, Sales.list_regions())
    |> canonicalize(:category, Sales.list_categories())
    |> normalize_store_ids()
    |> case do
      empty when map_size(empty) == 0 -> nil
      filters -> filters
    end
  end

  defp parse_filters(_other, _reset), do: nil

  @dimensions ~w(region category store_id date)
  @metrics ~w(revenue margin cost rows)
  @date_metrics ~w(revenue margin)

  defp sanitize_widgets(widgets) when not is_list(widgets), do: []

  defp sanitize_widgets(widgets) do
    widgets
    |> Enum.map(&normalize_widget/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_widget(%{"title" => title} = w)
       when is_binary(title) and title != "" do
    dim = w["dimension"]
    metric = w["metric"]

    if dim in @dimensions and metric in @metrics and
         (dim != "date" or metric in @date_metrics) do
      %{
        title: title,
        dimension: String.to_existing_atom(dim),
        metric: String.to_existing_atom(metric),
        chart: normalize_chart(dim, w["chart"])
      }
    end
  end

  defp normalize_widget(_other), do: nil

  defp normalize_chart("date", _chart), do: "line"
  defp normalize_chart(_dim, chart) when chart in ["bar", "doughnut"], do: chart
  defp normalize_chart(_dim, _chart), do: "bar"

  defp sanitize_ids(ids) when is_list(ids) do
    ids |> Enum.filter(&is_binary/1) |> Enum.reject(&(&1 == ""))
  end

  defp sanitize_ids(_other), do: []

  @forbidden_sql ~r/\b(insert|update|delete|drop|alter|create|truncate|grant|revoke|replace|rename|into\s+outfile|load_file|call|exec)\b|;/i

  @allowed_mutation ~r/^\s*(update|insert|delete|replace)\b/i

  defp sanitize_mutation(mutation) when not is_binary(mutation), do: nil

  defp sanitize_mutation(mutation) do
    trimmed = String.trim(mutation)

    if trimmed == "" or not Regex.match?(@allowed_mutation, trimmed) or
         Regex.match?(@forbidden_sql, trimmed) do
      nil
    else
      trimmed
    end
  end

  defp run_query(sql) when not is_binary(sql), do: nil

  defp run_query(sql) do
    trimmed = String.trim(sql)

    if trimmed == "" or not String.match?(trimmed, ~r/^\s*(select|with)\b/i) or
         Regex.match?(@forbidden_sql, trimmed) do
      if trimmed == "", do: nil, else: %{error: "Rejected non-SELECT query"}
    else
      case Hangten.Repo.query("SELECT * FROM (#{trimmed}) AS q LIMIT 200") do
        {:ok, %{columns: columns, rows: rows}} ->
          %{columns: columns, rows: rows}

        {:error, error} ->
          %{error: Exception.message(error)}
      end
    end
  end

  defp canonicalize(filters, key, allowed) do
    case Map.fetch(filters, key) do
      :error ->
        filters

      {:ok, value} ->
        case Enum.find(allowed, &(String.downcase(&1) == String.downcase(value))) do
          nil -> Map.delete(filters, key)
          canonical -> Map.put(filters, key, canonical)
        end
    end
  end

  defp normalize_store_ids(filters) do
    stores = Sales.list_stores()

    case Map.fetch(filters, :store_id) do
      :error ->
        filters

      {:ok, value} ->
        ids =
          value
          |> List.wrap()
          |> Enum.map(fn id ->
            Enum.find(stores, &(String.downcase(&1) == String.downcase(id)))
          end)
          |> Enum.reject(&is_nil/1)

        if ids == [], do: Map.delete(filters, :store_id), else: Map.put(filters, :store_id, ids)
    end
  end

  defp response_schema do
    stores = Sales.list_stores()

    %{
      "type" => "object",
      "properties" => %{
        "reply" => %{"type" => "string"},
        "reset_filters" => %{"type" => "boolean"},
        "filters" => %{
          "type" => ["object", "null"],
          "properties" => %{
            "region" => %{"type" => "string", "enum" => Sales.list_regions()},
            "category" => %{"type" => "string", "enum" => Sales.list_categories()},
            "store_id" => %{
              "anyOf" => [
                %{"type" => "string", "enum" => stores},
                %{"type" => "array", "items" => %{"type" => "string", "enum" => stores}}
              ]
            },
            "from" => %{"type" => "string"},
            "to" => %{"type" => "string"}
          },
          "additionalProperties" => false
        },
        "sql" => %{"type" => ["string", "null"]},
        "mutation" => %{"type" => ["string", "null"]},
        "add_widgets" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "title" => %{"type" => "string"},
              "dimension" => %{
                "type" => "string",
                "enum" => ["region", "category", "store_id", "date"]
              },
              "metric" => %{
                "type" => "string",
                "enum" => ["revenue", "margin", "cost", "rows"]
              },
              "chart" => %{"type" => "string", "enum" => ["line", "bar", "doughnut"]}
            },
            "required" => ["title", "dimension", "metric", "chart"],
            "additionalProperties" => false
          }
        },
        "remove_widgets" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => [
        "reply",
        "filters",
        "reset_filters",
        "sql",
        "mutation",
        "add_widgets",
        "remove_widgets"
      ]
    }
  end

  defp system_prompt(context) do
    """
    You are the assistant inside "Hangten", a retail sales dashboard.

    The `sales` table has one row per store x category x day with columns:
    date, region, category, store_id, revenue, cost, margin.
    revenue is gross sales, cost is COGS, margin is revenue minus cost.

    - date range: #{Sales.date_bounds().min} to #{Sales.date_bounds().max}
    - regions: #{Enum.join(Sales.list_regions(), ", ")}
    - categories: #{Enum.join(Sales.list_categories(), ", ")}
    - store ids: #{Enum.join(Sales.list_stores(), ", ")}

    Full-dataset aggregates (revenue / margin):
    #{data_snapshot()}

    Known anomalies currently flagged by the system:
    #{alerts_summary()}

    Dashboard charts currently on screen (id = title):
    #{widgets_summary(context)}

    You must respond with a single JSON object and nothing else:

    {"reply": "<conversational answer>",
     "reset_filters": <true|false>,
     "filters": <object | null>}

    Rules:
    - "reset_filters" is true ONLY when the user asks to clear, remove, or
      reset filters, or to see everything/all data. Otherwise it is false.
    - When the user asks to see, show, or slice data (a region, category,
      store, or time period), ALWAYS put the selection in "filters", with
      "reset_filters": false. Allowed keys:
        "region" (one region string), "category" (one category string),
        "store_id" (string or array of store ids),
        "from" and "to" (YYYY-MM-DD dates, within the date range above).
      When asked about a month or period, set "from"/"to" to its date bounds.
    - When the user asks a question needing no filter change, use "filters": null.
    - "sql" is an optional single MySQL SELECT against the sales table. Emit it
      whenever the question needs data — especially numbers not in the
      aggregates above (filtered subsets, per-store totals, a period, etc.).
      It is executed read-only and the result is shown to the user. Rules:
      SELECT only, no comments, no LIMIT clause, aggregate appropriately.
    - "mutation" is an optional single MySQL write statement (UPDATE, INSERT,
      or DELETE). Emit it ONLY when the user explicitly asks to change,
      correct, add, or remove data. It is shown for approval and runs only
      if the user accepts it. Never emit it for read-only questions.
    - "add_widgets" adds charts to the dashboard. Each widget needs a "title",
      a "dimension" (region | category | store_id | date), a "metric"
      (revenue | margin | cost | rows), and a "chart" type (line | bar |
      doughnut). "date" renders as a revenue+margin time series (metrics
      revenue/margin only, always a line chart). "rows" counts sales rows.
    - "remove_widgets" is a list of chart ids from the on-screen list above.
    - Only emit widget ops when the user asks to add, remove, or change
      charts on the dashboard; otherwise both arrays are empty.
    - Keep "reply" to 1-3 sentences. When you set filters, say what you set.
      When you emit sql, briefly describe what the result shows rather than
      inventing the numbers yourself.

    Examples:
    User: show me east stores
    {"reply": "Filtering the dashboard to the East region.", "reset_filters": false, "filters": {"region": "East"}}

    User: what was footwear revenue in W01 and W02?
    {"reply": "Filtering to Footwear at stores W01 and W02.", "reset_filters": false, "filters": {"category": "Footwear", "store_id": ["W01", "W02"]}}

    User: revenue in March?
    {"reply": "Filtering to March 2025.", "reset_filters": false, "filters": {"from": "2025-03-01", "to": "2025-03-31"}, "sql": null}

    User: which store sold the most footwear?
    {"reply": "Querying Footwear revenue by store.", "reset_filters": false, "filters": null, "sql": "SELECT store_id, SUM(revenue) AS revenue FROM sales WHERE category = 'Footwear' GROUP BY store_id ORDER BY revenue DESC"}

    User: show everything again
    {"reply": "Clearing all filters.", "reset_filters": true, "filters": null, "sql": null}
    """
  end

  defp data_snapshot do
    total = Sales.summary()

    lines =
      ["All data: revenue #{money(total.revenue)}, margin #{money(total.margin)}"] ++
        ["By region:"] ++
        Enum.map(
          Sales.revenue_by_region(),
          &"  #{&1.name}: revenue #{money(&1.revenue)}, margin #{money(&1.margin)}"
        ) ++
        ["By category:"] ++
        Enum.map(
          Sales.revenue_by_category(),
          &"  #{&1.name}: revenue #{money(&1.revenue)}, margin #{money(&1.margin)}"
        ) ++
        ["By store:"] ++
        Enum.map(
          Sales.revenue_by_store(),
          &"  #{&1.name}: revenue #{money(&1.revenue)}, margin #{money(&1.margin)}"
        )

    Enum.join(lines, "\n")
  end

  defp widgets_summary(context) do
    case Map.get(context, :widgets, []) do
      [] -> "  none"
      widgets -> Enum.map_join(widgets, "\n", &"  - #{&1.id} = #{&1.title}")
    end
  end

  defp alerts_summary do
    alerts = Hangten.Alerts.scan()

    if alerts == [] do
      "  none"
    else
      ["  #{length(alerts)} alerts"] ++
        Enum.map(Enum.take(alerts, 10), &"  - #{&1.message}")
    end
    |> Enum.join("\n")
  end

  defp money(%Decimal{} = d) do
    whole =
      d
      |> Decimal.round(0)
      |> Decimal.to_integer()
      |> Integer.to_string()
      |> String.graphemes()
      |> Enum.reverse()
      |> Enum.chunk_every(3)
      |> Enum.map_join(",", &Enum.reverse/1)
      |> String.reverse()

    "$" <> whole
  end

  defp config do
    env = Application.get_env(:hangten, __MODULE__, [])

    {
      Keyword.get(env, :base_url, "http://localhost:11434"),
      Keyword.get(env, :model, "qwen3:8b")
    }
  end
end
