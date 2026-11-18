defmodule Hangten.Sales.Sale do
  use Ecto.Schema
  import Ecto.Changeset

  schema "sales" do
    field :date, :date
    field :region, :string
    field :category, :string
    field :store_id, :string
    field :revenue, :decimal
    field :cost, :decimal
    field :margin, :decimal
  end

  def changeset(sale, attrs) do
    sale
    |> cast(attrs, [:date, :region, :category, :store_id, :revenue, :cost])
    |> validate_required([:date, :region, :category, :store_id, :revenue, :cost])
  end
end
