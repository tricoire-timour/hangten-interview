defmodule Hangten.Repo.Migrations.CreateSales do
  use Ecto.Migration

  def change do
    create table(:sales) do
      add :date, :date, null: false
      add :region, :"ENUM('East','North','South','West')", null: false
      add :category, :"ENUM('Accessories','Apparel','Footwear','Home')", null: false
      add :store_id, :string, null: false
      add :revenue, :decimal, precision: 12, scale: 2, null: false
      add :cost, :decimal, precision: 12, scale: 2, null: false
    end

    create index(:sales, [:region, :date])
    create index(:sales, [:category, :date])
    create index(:sales, [:store_id, :date])
  end
end
