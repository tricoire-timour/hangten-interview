defmodule Hangten.Repo.Migrations.AddMarginToSales do
  use Ecto.Migration

  def change do
    execute(
      "ALTER TABLE sales ADD COLUMN margin DECIMAL(12,2) GENERATED ALWAYS AS (revenue - cost) STORED",
      "ALTER TABLE sales DROP COLUMN margin"
    )
  end
end
