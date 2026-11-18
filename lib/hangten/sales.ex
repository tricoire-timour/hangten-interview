defmodule Hangten.Sales do
  import Ecto.Query

  alias Hangten.Repo
  alias Hangten.Sales.Sale

  @filters [:region, :category, :store_id]

  def summary(filters \\ %{}) do
    filters
    |> base_query()
    |> select([s], %{
      revenue: coalesce(sum(s.revenue), 0),
      cost: coalesce(sum(s.cost), 0),
      margin: coalesce(sum(s.margin), 0),
      rows: count(s.id)
    })
    |> Repo.one()
  end

  def revenue_by_region(filters \\ %{}), do: grouped(filters, :region)
  def revenue_by_category(filters \\ %{}), do: grouped(filters, :category)
  def revenue_by_store(filters \\ %{}), do: grouped(filters, :store_id)

  @doc "Generic rollup: GROUP BY dimension, SUM/COUNT metric. Powers LLM-added widgets."
  def aggregate(dimension, metric, filters \\ %{}) when dimension in @filters do
    query =
      filters
      |> base_query()
      |> group_by([s], field(s, ^dimension))

    query =
      case metric do
        :revenue ->
          select(query, [s], %{
            name: field(s, ^dimension),
            value: coalesce(sum(s.revenue), 0)
          })

        :margin ->
          select(query, [s], %{
            name: field(s, ^dimension),
            value: coalesce(sum(s.margin), 0)
          })

        :cost ->
          select(query, [s], %{
            name: field(s, ^dimension),
            value: coalesce(sum(s.cost), 0)
          })

        :rows ->
          select(query, [s], %{name: field(s, ^dimension), value: count(s.id)})
      end

    query
    |> Repo.all()
    |> Enum.sort_by(&to_number(&1.value), :desc)
  end

  defp to_number(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_number(n) when is_number(n), do: n

  def revenue_over_time(filters \\ %{}, granularity \\ :month) do
    filters
    |> base_query()
    |> time_bucket(granularity)
    |> Repo.all()
  end

  defp time_bucket(query, :day) do
    query
    |> group_by([s], s.date)
    |> select([s], %{
      period: s.date,
      revenue: sum(s.revenue),
      margin: sum(s.margin)
    })
    |> order_by([s], s.date)
  end

  defp time_bucket(query, :week) do
    week_start = dynamic([s], fragment("DATE_SUB(?, INTERVAL WEEKDAY(?) DAY)", s.date, s.date))

    query
    |> group_by([s], ^week_start)
    |> select([s], %{
      period: fragment("DATE_SUB(?, INTERVAL WEEKDAY(?) DAY)", s.date, s.date),
      revenue: sum(s.revenue),
      margin: sum(s.margin)
    })
    |> order_by([s], ^week_start)
  end

  defp time_bucket(query, :month) do
    month_start = dynamic([s], fragment("DATE_FORMAT(?, '%Y-%m-01')", s.date))

    query
    |> group_by([s], ^month_start)
    |> select([s], %{
      period: fragment("DATE_FORMAT(?, '%Y-%m-01')", s.date),
      revenue: sum(s.revenue),
      margin: sum(s.margin)
    })
    |> order_by([s], ^month_start)
  end

  def list_regions, do: distinct_values(:region)
  def list_categories, do: distinct_values(:category)
  def list_stores, do: distinct_values(:store_id)

  def date_bounds do
    Sale
    |> select([s], %{min: min(s.date), max: max(s.date)})
    |> Repo.one()
  end

  defp grouped(filters, field) do
    filters
    |> base_query()
    |> group_by([s], field(s, ^field))
    |> select([s], %{
      name: field(s, ^field),
      revenue: sum(s.revenue),
      margin: sum(s.margin)
    })
    |> order_by([s], desc: sum(s.revenue))
    |> Repo.all()
  end

  defp distinct_values(field) do
    Sale
    |> select([s], field(s, ^field))
    |> distinct(true)
    |> order_by([s], field(s, ^field))
    |> Repo.all()
  end

  defp base_query(filters) do
    Enum.reduce(filters, from(s in Sale), fn
      {key, value}, query when key in [:from, :to] -> apply_date_filter(query, key, value)
      {key, value}, query when key in @filters -> apply_dim_filter(query, key, value)
      _other, query -> query
    end)
  end

  defp apply_date_filter(query, _key, value) when value in [nil, ""], do: query
  defp apply_date_filter(query, :from, value), do: where(query, [s], s.date >= ^value)
  defp apply_date_filter(query, :to, value), do: where(query, [s], s.date <= ^value)

  defp apply_dim_filter(query, key, values) when is_list(values) do
    case Enum.reject(values, &(&1 in [nil, ""])) do
      [] -> query
      values -> where(query, [s], field(s, ^key) in ^values)
    end
  end

  defp apply_dim_filter(query, _key, value) when value in [nil, ""], do: query
  defp apply_dim_filter(query, key, value), do: where(query, [s], field(s, ^key) == ^value)
end
