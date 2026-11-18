defmodule HangtenWeb.DashboardLive do
  use HangtenWeb, :live_view

  alias Hangten.Sales

  @empty_filters %{region: nil, category: nil, store_id: [], from: nil, to: nil}
  @granularities %{"day" => :day, "week" => :week, "month" => :month}
  @palette ["#0ea5e9", "#f97316", "#22c55e", "#a855f7", "#eab308", "#ef4444"]
  @default_widgets [
    %{
      id: "revenue-chart",
      title: "Revenue over time",
      dimension: :date,
      metric: :revenue,
      chart: "line"
    },
    %{
      id: "region-chart",
      title: "Revenue by region",
      dimension: :region,
      metric: :revenue,
      chart: "bar"
    },
    %{
      id: "category-chart",
      title: "Revenue by category",
      dimension: :category,
      metric: :revenue,
      chart: "doughnut"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    bounds = Sales.date_bounds()

    {:ok,
     socket
     |> assign(:regions, Sales.list_regions())
     |> assign(:categories, Sales.list_categories())
     |> assign(:stores, Sales.list_stores())
     |> assign(:date_bounds, bounds)
     |> assign(:filters, @empty_filters)
     |> assign(:granularity, :month)
     |> assign(:filter_form, to_form(%{"granularity" => "month"}, as: :filters))
     |> assign(:asking, false)
     |> assign(:store_dropdown_open, false)
     |> assign(:question_form, to_form(%{"question" => ""}))
     |> assign(:input_nonce, 0)
     |> assign(:chat_history, [])
     |> assign(:alerts, Hangten.Alerts.scan())
     |> assign(:mutations, %{})
     |> assign(:widgets, @default_widgets)
     |> assign(:widget_counter, 1)
     |> stream(:chat_messages, [])
     |> assign_data()
     |> push_charts()}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters =
      params
      |> Map.take(["region", "category", "store_id", "from", "to"])
      |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
      |> Map.update(:store_id, [], &List.wrap/1)

    granularity = Map.get(@granularities, params["granularity"], :month)

    {:noreply,
     socket
     |> assign(:granularity, granularity)
     |> apply_filters(filters)}
  end

  def handle_event("ask", %{"question" => question}, socket) when question != "" do
    ref = System.unique_integer([:positive])
    history = socket.assigns.chat_history
    widgets = socket.assigns.widgets

    {:noreply,
     socket
     |> assign(:asking, true)
     |> stream_insert(:chat_messages, %{
       id: "user-#{ref}",
       role: :user,
       text: question,
       sql: nil,
       thinking: nil,
       result: nil,
       mutation: nil
     })
     |> assign(:question_form, to_form(%{"question" => ""}))
     |> update(:input_nonce, &(&1 + 1))
     |> update(:chat_history, &(&1 ++ [%{role: "user", content: question}]))
     |> start_async({:llm, ref}, fn ->
       Hangten.LLM.answer(question, history, %{widgets: widgets})
     end)}
  end

  def handle_event("ask", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_store_filter", _params, socket) do
    {:noreply, assign(socket, :store_dropdown_open, !socket.assigns.store_dropdown_open)}
  end

  def handle_event("close_store_filter", _params, socket) do
    {:noreply, assign(socket, :store_dropdown_open, false)}
  end

  def handle_event("apply_mutation", %{"id" => id}, socket) do
    case socket.assigns.mutations[id] do
      %{sql: sql, status: :pending} ->
        mutations =
          case Hangten.Repo.query(sql) do
            {:ok, _} ->
              put_in(socket.assigns.mutations, [id, :status], :applied)

            {:error, e} ->
              put_in(socket.assigns.mutations, [id, :status], {:error, Exception.message(e)})
          end

        {:noreply,
         socket
         |> assign(:mutations, mutations)
         |> assign(:alerts, Hangten.Alerts.scan())
         |> assign_data()
         |> push_charts()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("dismiss_mutation", %{"id" => id}, socket) do
    {:noreply,
     assign(socket, :mutations, put_in(socket.assigns.mutations, [id, :status], :dismissed))}
  end

  @impl true
  def handle_async({:llm, ref}, {:ok, {:ok, %{text: text} = response}}, socket) do
    socket =
      socket
      |> assign(:asking, false)
      |> update(:chat_history, &(&1 ++ [%{role: "assistant", content: text}]))
      |> stream_insert(:chat_messages, %{
        id: "assistant-#{ref}",
        role: :assistant,
        text: text,
        sql: response[:sql],
        thinking: response[:thinking],
        result: response[:query_result],
        mutation: response[:mutation]
      })

    socket =
      if response[:mutation] do
        update(socket, :mutations, fn mutations ->
          Map.put(mutations, "assistant-#{ref}", %{sql: response.mutation, status: :pending})
        end)
      else
        socket
      end

    socket =
      case response[:filters] do
        nil ->
          socket

        :reset ->
          apply_filters(socket, @empty_filters)

        filters ->
          apply_filters(
            socket,
            Map.merge(socket.assigns.filters, normalize_store_filter(filters))
          )
      end

    {:noreply, apply_widget_ops(socket, response)}
  end

  def handle_async({:llm, ref}, result, socket) do
    text =
      case result do
        {:ok, {:error, reason}} -> "LLM error: #{inspect(reason)}"
        {:exit, reason} -> "LLM request failed: #{inspect(reason)}"
      end

    {:noreply,
     socket
     |> assign(:asking, false)
     |> stream_insert(:chat_messages, %{id: "assistant-#{ref}", role: :assistant, text: text})}
  end

  defp apply_widget_ops(socket, response) do
    remove = response[:remove_widgets] || []
    add = response[:add_widgets] || []

    if remove == [] and add == [] do
      socket
    else
      {new, counter} =
        Enum.map_reduce(add, socket.assigns.widget_counter, fn spec, n ->
          {Map.put(spec, :id, "w#{n}"), n + 1}
        end)

      widgets =
        socket.assigns.widgets
        |> Enum.reject(&(&1.id in remove))
        |> Kernel.++(new)

      socket
      |> assign(:widgets, widgets)
      |> assign(:widget_counter, counter)
      |> push_charts()
    end
  end

  defp normalize_store_filter(%{store_id: value} = filters) when not is_list(value),
    do: Map.put(filters, :store_id, List.wrap(value))

  defp normalize_store_filter(filters), do: filters

  defp apply_filters(socket, filters) do
    form_params =
      filters
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value || ""} end)
      |> Map.put("granularity", Atom.to_string(socket.assigns.granularity))

    socket
    |> assign(:filters, filters)
    |> assign(:filter_form, to_form(form_params, as: :filters))
    |> assign_data()
    |> push_charts()
  end

  defp assign_data(socket) do
    filters = socket.assigns.filters

    socket
    |> assign(:kpis, Sales.summary(filters))
    |> assign(:store_rows, Sales.revenue_by_store(filters))
  end

  defp push_charts(socket) do
    if connected?(socket) do
      Enum.reduce(socket.assigns.widgets, socket, fn widget, socket ->
        push_event(socket, "chart:render", %{id: widget.id, config: widget_config(widget, socket)})
      end)
    else
      socket
    end
  end

  defp widget_config(%{dimension: :date}, socket) do
    series_chart(Sales.revenue_over_time(socket.assigns.filters, socket.assigns.granularity))
  end

  defp widget_config(%{chart: "doughnut"} = widget, socket) do
    doughnut_chart(
      Sales.aggregate(widget.dimension, widget.metric, socket.assigns.filters),
      metric_label(widget.metric)
    )
  end

  defp widget_config(widget, socket) do
    bar_chart(
      Sales.aggregate(widget.dimension, widget.metric, socket.assigns.filters),
      metric_label(widget.metric)
    )
  end

  defp metric_label(:revenue), do: "Revenue"
  defp metric_label(:margin), do: "Margin"
  defp metric_label(:cost), do: "Cost"
  defp metric_label(:rows), do: "Rows"

  defp series_chart(series) do
    %{
      type: "line",
      data: %{
        labels: Enum.map(series, &to_string(&1.period)),
        datasets: [
          %{
            label: "Revenue",
            data: Enum.map(series, &num(&1.revenue)),
            borderColor: "#0ea5e9",
            backgroundColor: "rgba(14, 165, 233, 0.15)",
            fill: true,
            tension: 0.3
          },
          %{
            label: "Margin",
            data: Enum.map(series, &num(&1.margin)),
            borderColor: "#22c55e",
            backgroundColor: "rgba(34, 197, 94, 0.1)",
            fill: true,
            tension: 0.3
          }
        ]
      },
      options: %{
        responsive: true,
        maintainAspectRatio: false,
        interaction: %{mode: "index", intersect: false}
      }
    }
  end

  defp bar_chart(rows, label) do
    %{
      type: "bar",
      data: %{
        labels: Enum.map(rows, & &1.name),
        datasets: [
          %{
            label: label,
            data: Enum.map(rows, &num(&1.value)),
            backgroundColor: Stream.cycle(@palette) |> Enum.take(length(rows))
          }
        ]
      },
      options: %{
        responsive: true,
        maintainAspectRatio: false,
        plugins: %{legend: %{display: false}}
      }
    }
  end

  defp doughnut_chart(rows, label) do
    %{
      type: "doughnut",
      data: %{
        labels: Enum.map(rows, & &1.name),
        datasets: [
          %{
            label: label,
            data: Enum.map(rows, &num(&1.value)),
            backgroundColor: Enum.take(@palette, length(rows))
          }
        ]
      },
      options: %{
        responsive: true,
        maintainAspectRatio: false
      }
    }
  end

  defp num(%Decimal{} = d), do: Decimal.to_float(d)
  defp num(n) when is_number(n), do: n

  defp store_filter_label(%{store_id: ids}) when is_list(ids) and ids != [],
    do: Enum.join(ids, ", ")

  defp store_filter_label(_filters), do: "All stores"

  defp severity_class(:high), do: "text-error"
  defp severity_class(:medium), do: "text-warning"
  defp severity_class(_severity), do: "text-info"

  defp kind_badge_class(:suspicious), do: "badge-warning"
  defp kind_badge_class(:business), do: "badge-info"
  defp kind_badge_class(_kind), do: "badge-ghost"

  defp fmt_money(%Decimal{} = d) do
    f = Decimal.to_float(d)

    cond do
      abs(f) >= 1_000_000 -> "$#{Float.round(f / 1_000_000, 2)}M"
      abs(f) >= 1_000 -> "$#{Float.round(f / 1_000, 1)}K"
      true -> "$#{Float.round(f, 2)}"
    end
  end

  defp fmt_money_full(%Decimal{} = d) do
    {whole, frac} =
      d
      |> Decimal.round(2)
      |> Decimal.to_string(:normal)
      |> String.split(".")
      |> then(fn
        [w, f] -> {w, f}
        [w] -> {w, "00"}
      end)

    whole = Regex.replace(~r/\B(?=(\d{3})+(?!\d))/, whole, ",")
    "$#{whole}.#{String.pad_trailing(frac, 2, "0")}"
  end

  defp fmt_pct(%Decimal{} = margin, %Decimal{} = revenue) do
    if Decimal.eq?(revenue, 0) do
      "—"
    else
      pct = margin |> Decimal.div(revenue) |> Decimal.mult(100) |> Decimal.round(1)
      "#{pct}%"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col lg:h-[calc(100vh-4rem)]">
        <div class="flex flex-col lg:flex-row flex-1 min-h-0">
          <div class="flex-1 overflow-y-auto px-4 sm:px-6 py-6 space-y-6">
            <div class="flex items-end justify-between">
              <div>
                <h1 class="text-2xl font-bold">Sales Dashboard</h1>
                <p class="text-sm text-base-content/60">
                  {@date_bounds.min} – {@date_bounds.max}
                </p>
              </div>
            </div>

            <.form
              for={@filter_form}
              id="filter-form"
              phx-change="filter"
              class="flex flex-wrap items-end gap-3"
            >
              <.input
                field={@filter_form[:region]}
                type="select"
                label="Region"
                prompt="All regions"
                options={@regions}
              />
              <.input
                field={@filter_form[:category]}
                type="select"
                label="Category"
                prompt="All categories"
                options={@categories}
              />
              <div class="fieldset mb-2">
                <span class="label mb-1">Stores</span>
                <div
                  class="relative"
                  phx-click-away={@store_dropdown_open && "close_store_filter"}
                >
                  <button
                    type="button"
                    id="store-filter-button"
                    phx-click="toggle_store_filter"
                    class="select w-44 flex items-center justify-between gap-2"
                  >
                    <span class="truncate">{store_filter_label(@filters)}</span>
                  </button>
                  <div
                    :if={@store_dropdown_open}
                    id="store-filter-menu"
                    class="absolute z-20 mt-1 max-h-64 w-44 overflow-y-auto rounded-lg border border-base-300 bg-base-100 p-1 shadow-lg"
                  >
                    <label
                      :for={store <- @stores}
                      class="flex cursor-pointer items-center gap-2 rounded px-2 py-1.5 text-sm hover:bg-base-200"
                    >
                      <input
                        type="checkbox"
                        name="filters[store_id][]"
                        value={store}
                        checked={store in List.wrap(@filters.store_id)}
                        class="checkbox checkbox-sm"
                      />
                      {store}
                    </label>
                  </div>
                </div>
              </div>
              <.input field={@filter_form[:from]} type="date" label="From" />
              <.input field={@filter_form[:to]} type="date" label="To" />
              <.input
                field={@filter_form[:granularity]}
                type="select"
                label="Group by"
                options={[{"Daily", "day"}, {"Weekly", "week"}, {"Monthly", "month"}]}
              />
            </.form>

            <div class="card bg-base-100 border border-base-300">
              <div class="card-body p-4 overflow-auto max-h-72">
                <h2 class="card-title text-sm">
                  Alerts <span class="badge badge-sm badge-warning">{length(@alerts)}</span>
                </h2>
                <ul class="space-y-1 text-xs">
                  <li :for={alert <- @alerts}>
                    <span class={severity_class(alert.severity)}>●</span> {alert.message}
                    <span class={["badge badge-xs", kind_badge_class(alert.kind)]}>
                      {alert.kind}
                    </span>
                  </li>
                  <li :if={@alerts == []} class="text-base-content/50">
                    No anomalies detected
                  </li>
                </ul>
              </div>
            </div>

            <div class="grid grid-cols-2 gap-4">
              <.kpi_card label="Revenue" value={fmt_money(@kpis.revenue)} />
              <.kpi_card label="Gross margin" value={fmt_money(@kpis.margin)} />
              <.kpi_card label="Margin %" value={fmt_pct(@kpis.margin, @kpis.revenue)} />
              <.kpi_card label="Rows" value={@kpis.rows} />
            </div>

            <div class="grid lg:grid-cols-2 gap-4">
              <div
                :for={widget <- @widgets}
                class={[
                  "card bg-base-100 border border-base-300",
                  widget.dimension == :date && "lg:col-span-2"
                ]}
              >
                <div class="card-body p-4">
                  <h2 class="card-title text-sm">{widget.title}</h2>
                  <div class="h-64">
                    <canvas id={widget.id} phx-hook="Chart" phx-update="ignore"></canvas>
                  </div>
                </div>
              </div>
            </div>

            <div class="card bg-base-100 border border-base-300">
              <div class="card-body p-4 overflow-auto">
                <h2 class="card-title text-sm">Stores</h2>
                <table id="stores-table" class="table table-sm">
                  <thead>
                    <tr>
                      <th>Store</th>
                      <th class="text-right">Revenue</th>
                      <th class="text-right">Margin</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={row <- @store_rows}>
                      <td class="font-medium">{row.name}</td>
                      <td class="text-right tabular-nums">{fmt_money_full(row.revenue)}</td>
                      <td class="text-right tabular-nums">{fmt_money_full(row.margin)}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </div>

          <div class="lg:w-1/2 lg:shrink-0 flex flex-col border-t lg:border-t-0 lg:border-l border-base-300 bg-base-100">
            <div class="p-4 border-b border-base-300">
              <h2 class="font-semibold">Ask about your data</h2>
              <p class="text-xs text-base-content/60">
                Try "show me East", "filter to Footwear at store E01", or "clear filters"
              </p>
            </div>

            <div class="flex-1 overflow-y-auto min-h-64 p-4">
              <div id="chat-messages" phx-update="stream" class="space-y-3">
                <div
                  :for={{id, msg} <- @streams.chat_messages}
                  id={id}
                  class={[
                    "rounded-lg px-3 py-2 text-sm whitespace-pre-wrap",
                    msg.role == :user && "bg-primary/10 ml-8",
                    msg.role == :assistant && "bg-base-200 mr-8"
                  ]}
                >
                  {msg.text}
                  <details :if={msg[:thinking]} class="mt-1">
                    <summary class="cursor-pointer text-xs text-base-content/50">
                      thinking
                    </summary>
                    <pre class="mt-1 max-h-40 overflow-y-auto text-xs whitespace-pre-wrap text-base-content/60">{msg.thinking}</pre>
                  </details>
                  <code :if={msg[:sql]} class="mt-1 block font-mono text-xs text-base-content/50">
                    {msg.sql}
                  </code>
                  <div :if={msg.result} class="mt-2">
                    <%= cond do %>
                      <% msg.result[:error] -> %>
                        <div class="text-xs text-error">Query error: {msg.result.error}</div>
                      <% msg.result[:rows] && msg.result[:rows] != [] -> %>
                        <div class="overflow-x-auto rounded border border-base-300">
                          <table class="table table-xs">
                            <thead>
                              <tr>
                                <th :for={col <- msg.result.columns}>{col}</th>
                              </tr>
                            </thead>
                            <tbody>
                              <tr :for={row <- Enum.take(msg.result.rows, 20)}>
                                <td :for={cell <- row} class="tabular-nums">{cell}</td>
                              </tr>
                            </tbody>
                          </table>
                        </div>
                      <% true -> %>
                        <div class="text-xs text-base-content/60">Query returned no rows</div>
                    <% end %>
                  </div>
                  <div
                    :if={msg[:mutation] && @mutations[msg.id]}
                    class="mt-2 rounded border border-warning/50 bg-warning/10 p-2"
                  >
                    <code class="block font-mono text-xs">{msg.mutation}</code>
                    <%= case @mutations[msg.id].status do %>
                      <% :pending -> %>
                        <div class="mt-2 flex gap-2">
                          <.button
                            phx-click="apply_mutation"
                            phx-value-id={msg.id}
                            class="btn btn-xs btn-warning"
                          >
                            Apply
                          </.button>
                          <.button
                            phx-click="dismiss_mutation"
                            phx-value-id={msg.id}
                            class="btn btn-xs btn-ghost"
                          >
                            Dismiss
                          </.button>
                        </div>
                      <% :applied -> %>
                        <div class="mt-1 text-xs text-success">Applied</div>
                      <% :dismissed -> %>
                        <div class="mt-1 text-xs text-base-content/50">Dismissed</div>
                      <% {:error, err} -> %>
                        <div class="mt-1 text-xs text-error">{err}</div>
                    <% end %>
                  </div>
                </div>
              </div>
              <div :if={@asking} class="text-sm text-base-content/60 animate-pulse py-2">
                Thinking…
              </div>
            </div>

            <.form
              for={@question_form}
              id="chat-form"
              phx-submit="ask"
              class="flex gap-2 p-4 border-t border-base-300"
            >
              <div class="flex-1">
                <.input
                  field={@question_form[:question]}
                  id={"question-input-#{@input_nonce}"}
                  type="text"
                  autocomplete="off"
                  data-1p-ignore
                  data-lpignore="true"
                  data-bwignore
                  placeholder="e.g. Which region had the best margin in March?"
                  class="w-full"
                />
              </div>
              <.button disabled={@asking}>Ask</.button>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp kpi_card(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-300">
      <div class="card-body p-4">
        <div class="text-xs uppercase tracking-wide text-base-content/60">{@label}</div>
        <div class="text-2xl font-bold tabular-nums">{@value}</div>
      </div>
    </div>
    """
  end
end
