defmodule Hangten.Seeds do
  @moduledoc "Loads sales_data.csv into the sales table (idempotent — wipes first)."

  alias Hangten.Repo
  alias Hangten.Sales.Sale

  def run do
    rows =
      path()
      |> File.stream!()
      |> NimbleCSV.RFC4180.parse_stream(skip_headers: true)
      |> Enum.map(fn [date, region, category, store_id, revenue, cost] ->
        %{
          date: Date.from_iso8601!(date),
          region: region,
          category: category,
          store_id: store_id,
          revenue: Decimal.new(revenue),
          cost: Decimal.new(cost)
        }
      end)

    Repo.delete_all(Sale)
    Repo.insert_all(Sale, rows)
    {:ok, length(rows)}
  end

  defp path do
    Path.join(:code.priv_dir(:hangten), "repo/sales_data.csv")
  end
end
