defmodule Hangten.Alerts do
  @moduledoc """
  Deterministic anomaly detection over the sales table.

  Each alert is `%{sale_id, type, kind, severity, message}` where `kind`
  is `:data_entry` (likely an input/integrity error), `:suspicious`
  (could be cooked books), or `:business` (a real operational signal).
  Nothing is persisted or auto-fixed.
  """

  import Ecto.Query
  alias Hangten.Repo
  alias Hangten.Sales.Sale

  @margin_low 0.10
  @margin_high 0.75
  @outlier_multiplier 3.0
  @step_ratio 2.0
  @max_gap_days 14
  @truncation_days 14
  @severity_rank %{high: 0, medium: 1, low: 2}
  @kind_rank %{suspicious: 0, business: 1, data_entry: 2}

  def scan do
    [
      negative_margin_alerts(),
      margin_pct_alerts(),
      outlier_alerts(),
      duplicate_alerts(),
      impossible_margin_alerts(),
      zero_margin_alerts(),
      costless_revenue_alerts(),
      future_date_alerts(),
      date_gap_alerts(),
      truncated_series_alerts(),
      step_change_alerts()
    ]
    |> Enum.concat()
    |> consolidate()
    |> Enum.sort_by(&{Map.fetch!(@kind_rank, &1.kind), Map.fetch!(@severity_rank, &1.severity)})
  end

  @doc false
  def consolidate(alerts) do
    stores_by_region =
      Sale
      |> distinct(true)
      |> select([s], {s.region, s.store_id})
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {region, stores} -> {region, MapSet.new(stores)} end)

    all_categories =
      Sale |> distinct(true) |> select([s], s.category) |> Repo.all() |> MapSet.new()

    {series, rows} = Enum.split_with(alerts, &is_nil(Map.get(&1, :store_id)))

    consolidated =
      rows
      |> Enum.group_by(& &1.type)
      |> Enum.flat_map(fn {type, group} ->
        consolidate_type(type, group, stores_by_region, all_categories)
      end)

    series ++ consolidated
  end

  # If every store in a region is flagged for the same issue, collapse the
  # rows into one "All {region} stores" alert; then do the same per store
  # when all of its categories are flagged.
  defp consolidate_type(type, alerts, stores_by_region, all_categories) do
    {region_consolidated, leftovers} =
      alerts
      |> Enum.group_by(& &1.region)
      |> Enum.reduce({[], []}, fn {region, list}, {cons, left} ->
        covered = list |> Enum.map(& &1.store_id) |> MapSet.new()

        if covered == Map.get(stores_by_region, region, MapSet.new()) and
             MapSet.size(covered) > 0 do
          {[consolidated_alert(type, "All #{region} stores", list) | cons], left}
        else
          {cons, list ++ left}
        end
      end)

    {store_consolidated, rest} =
      leftovers
      |> Enum.group_by(& &1.store_id)
      |> Enum.reduce({[], []}, fn {store, list}, {cons, left} ->
        covered = list |> Enum.map(& &1.category) |> MapSet.new()

        if covered == all_categories and MapSet.size(covered) > 0 do
          {[consolidated_alert(type, "All categories at #{store}", list) | cons], left}
        else
          {cons, list ++ left}
        end
      end)

    region_consolidated ++ store_consolidated ++ rest
  end

  defp consolidated_alert(type, scope, alerts) do
    worst = Enum.min_by(alerts, &Map.fetch!(@severity_rank, &1.severity)).severity

    %{
      sale_id: nil,
      type: type,
      kind: hd(alerts).kind,
      severity: worst,
      message: "#{scope}: #{type_label(type)} (#{length(alerts)} alerts)"
    }
  end

  defp type_label(:date_gap), do: "data gaps"
  defp type_label(:truncated_series), do: "series ends early"
  defp type_label(:step_change), do: "revenue step change"
  defp type_label(:duplicate), do: "duplicate rows"
  defp type_label(:negative_margin), do: "negative margin"
  defp type_label(:margin_pct), do: "margin outside normal range"
  defp type_label(:outlier), do: "revenue outliers"
  defp type_label(:impossible_margin), do: "impossible margin"
  defp type_label(:zero_margin), do: "revenue equals cost"
  defp type_label(:costless_revenue), do: "cost without revenue"
  defp type_label(:future_date), do: "future-dated rows"
  defp type_label(type), do: "#{type} issues"

  # --- row-level detectors -------------------------------------------------

  defp negative_margin_alerts do
    Sale
    |> where([s], s.margin < 0)
    |> select([s], %{
      sale_id: s.id,
      region: s.region,
      store_id: s.store_id,
      category: s.category,
      type: :negative_margin,
      kind: :business,
      severity: :high,
      message:
        fragment(
          "CONCAT(?, ' / ', ?, ' / ', ?, ' ', ?, ': negative margin $', ?)",
          s.store_id,
          s.region,
          s.category,
          s.date,
          s.margin
        )
    })
    |> Repo.all()
  end

  defp margin_pct_alerts do
    Sale
    |> where(
      [s],
      s.revenue > 0 and
        (s.margin / s.revenue < ^@margin_low or s.margin / s.revenue > ^@margin_high)
    )
    |> select([s], %{
      sale_id: s.id,
      region: s.region,
      store_id: s.store_id,
      category: s.category,
      type: :margin_pct,
      kind: :suspicious,
      severity: :medium,
      message:
        fragment(
          "CONCAT(?, ' / ', ?, ' / ', ?, ' ', ?, ': margin ', ?, '%')",
          s.store_id,
          s.region,
          s.category,
          s.date,
          fragment("ROUND(100 * ? / ?, 1)", s.margin, s.revenue)
        )
    })
    |> Repo.all()
  end

  defp outlier_alerts do
    avgs =
      from s in Sale,
        group_by: [s.store_id, s.category],
        select: %{
          store_id: s.store_id,
          category: s.category,
          avg_revenue: avg(s.revenue),
          n: count(s.id)
        }

    Sale
    |> join(:inner, [s], a in subquery(avgs),
      on: a.store_id == s.store_id and a.category == s.category
    )
    |> where(
      [s, a],
      a.n >= 10 and
        (s.revenue > a.avg_revenue * ^@outlier_multiplier or
           s.revenue < a.avg_revenue / ^@outlier_multiplier)
    )
    |> select([s, a], %{
      sale_id: s.id,
      region: s.region,
      store_id: s.store_id,
      category: s.category,
      type: :outlier,
      kind: :suspicious,
      severity: :medium,
      message:
        fragment(
          "CONCAT(?, ' / ', ?, ' / ', ?, ' ', ?, ': revenue $', ?, ' vs avg $', ?)",
          s.store_id,
          s.region,
          s.category,
          s.date,
          fragment("ROUND(?, 0)", s.revenue),
          fragment("ROUND(?, 0)", a.avg_revenue)
        )
    })
    |> Repo.all()
  end

  defp duplicate_alerts do
    Sale
    |> group_by([s], [s.region, s.store_id, s.category, s.date])
    |> having([s], count(s.id) > 1)
    |> select([s], %{
      sale_id: nil,
      region: s.region,
      store_id: s.store_id,
      category: s.category,
      type: :duplicate,
      kind: :data_entry,
      severity: :high,
      message:
        fragment(
          "CONCAT(?, ' / ', ?, ' ', ?, ': ', ?, ' duplicate rows')",
          s.store_id,
          s.category,
          s.date,
          count(s.id)
        )
    })
    |> Repo.all()
  end

  defp impossible_margin_alerts do
    Sale
    |> where([s], s.margin > s.revenue or s.cost < 0)
    |> select([s], %{
      sale_id: s.id,
      region: s.region,
      store_id: s.store_id,
      category: s.category,
      type: :impossible_margin,
      kind: :data_entry,
      severity: :high,
      message:
        fragment(
          "CONCAT(?, ' / ', ?, ' / ', ?, ' ', ?, ': margin $', ?, ' exceeds revenue $', ?)",
          s.store_id,
          s.region,
          s.category,
          s.date,
          s.margin,
          s.revenue
        )
    })
    |> Repo.all()
  end

  defp zero_margin_alerts do
    Sale
    |> where([s], s.revenue > 0 and s.margin == 0)
    |> select([s], %{
      sale_id: s.id,
      region: s.region,
      store_id: s.store_id,
      category: s.category,
      type: :zero_margin,
      kind: :suspicious,
      severity: :low,
      message:
        fragment(
          "CONCAT(?, ' / ', ?, ' / ', ?, ' ', ?, ': revenue equals cost')",
          s.store_id,
          s.region,
          s.category,
          s.date
        )
    })
    |> Repo.all()
  end

  defp costless_revenue_alerts do
    Sale
    |> where([s], s.revenue == 0 and s.cost > 0)
    |> select([s], %{
      sale_id: s.id,
      region: s.region,
      store_id: s.store_id,
      category: s.category,
      type: :costless_revenue,
      kind: :business,
      severity: :medium,
      message:
        fragment(
          "CONCAT(?, ' / ', ?, ' / ', ?, ' ', ?, ': $0 revenue with $', ?, ' cost')",
          s.store_id,
          s.region,
          s.category,
          s.date,
          s.cost
        )
    })
    |> Repo.all()
  end

  defp future_date_alerts do
    Sale
    |> where([s], s.date > fragment("CURDATE()"))
    |> select([s], %{
      sale_id: s.id,
      region: s.region,
      store_id: s.store_id,
      category: s.category,
      type: :future_date,
      kind: :data_entry,
      severity: :high,
      message:
        fragment(
          "CONCAT(?, ' / ', ?, ' / ', ?, ' ', ?, ': future-dated row')",
          s.store_id,
          s.region,
          s.category,
          s.date
        )
    })
    |> Repo.all()
  end

  # --- series-level detectors ----------------------------------------------

  # A "gap" is a consecutive-day silence inside a series, not a sparse
  # sampling — flag stretches of >= @max_gap_days with no rows.
  defp date_gap_alerts do
    Sale
    |> select([s], {s.store_id, s.region, s.category, s.date})
    |> order_by([s], [s.store_id, s.category, s.date])
    |> Repo.all()
    |> Enum.group_by(fn {store, _region, category, _date} -> {store, category} end)
    |> Enum.flat_map(fn {{store, category}, rows} ->
      dates = rows |> Enum.map(&elem(&1, 3)) |> Enum.sort()
      region = elem(hd(rows), 1)

      dates
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> {a, b, Date.diff(b, a)} end)
      |> Enum.filter(fn {_a, _b, days} -> days >= @max_gap_days end)
      |> Enum.map(fn {a, b, days} ->
        %{
          sale_id: nil,
          region: region,
          store_id: store,
          category: category,
          type: :date_gap,
          kind: :business,
          severity: if(days >= 28, do: :high, else: :medium),
          message: "#{store} / #{category}: #{days}-day gap #{a} -> #{b}"
        }
      end)
    end)
  end

  defp truncated_series_alerts do
    global_max = Repo.one(from s in Sale, select: max(s.date))
    threshold = Date.add(global_max, -@truncation_days)

    Sale
    |> group_by([s], [s.region, s.store_id, s.category])
    |> having([s], max(s.date) < ^threshold)
    |> select([s], %{
      sale_id: nil,
      region: s.region,
      store_id: s.store_id,
      category: s.category,
      type: :truncated_series,
      kind: :business,
      severity: :medium,
      message:
        fragment(
          "CONCAT(?, ' / ', ?, ': series ends ', ?, ' (data ends ', ?, ')')",
          s.store_id,
          s.category,
          max(s.date),
          ^global_max
        )
    })
    |> Repo.all()
  end

  defp step_change_alerts do
    %{min: min, max: max} = Hangten.Sales.date_bounds()
    midpoint = Date.add(min, div(Date.diff(max, min), 2))

    Sale
    |> group_by([s], [s.region, s.store_id, s.category])
    |> having(
      [s],
      fragment(
        "GREATEST(AVG(CASE WHEN ? < ? THEN ? END), AVG(CASE WHEN ? >= ? THEN ? END)) /
         LEAST(AVG(CASE WHEN ? < ? THEN ? END), AVG(CASE WHEN ? >= ? THEN ? END)) > ?",
        s.date,
        ^midpoint,
        s.revenue,
        s.date,
        ^midpoint,
        s.revenue,
        s.date,
        ^midpoint,
        s.revenue,
        s.date,
        ^midpoint,
        s.revenue,
        ^@step_ratio
      )
    )
    |> select([s], %{
      sale_id: nil,
      region: s.region,
      store_id: s.store_id,
      category: s.category,
      type: :step_change,
      kind: :suspicious,
      severity: :medium,
      message:
        fragment(
          "CONCAT(?, ' / ', ?, ': avg revenue shifts $', ?, ' -> $', ?, ' mid-range')",
          s.store_id,
          s.category,
          fragment(
            "ROUND(AVG(CASE WHEN ? < ? THEN ? END), 0)",
            s.date,
            ^midpoint,
            s.revenue
          ),
          fragment(
            "ROUND(AVG(CASE WHEN ? >= ? THEN ? END), 0)",
            s.date,
            ^midpoint,
            s.revenue
          )
        )
    })
    |> Repo.all()
  end
end
