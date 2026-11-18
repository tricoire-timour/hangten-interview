defmodule HangtenWeb.DashboardLiveTest do
  use HangtenWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Hangten.Repo
  alias Hangten.Sales.Sale

  setup do
    Repo.insert_all(Sale, [
      %{
        date: ~D[2025-01-01],
        region: "East",
        category: "Apparel",
        store_id: "E01",
        revenue: Decimal.new("100.00"),
        cost: Decimal.new("60.00")
      },
      %{
        date: ~D[2025-02-01],
        region: "West",
        category: "Home",
        store_id: "W01",
        revenue: Decimal.new("50.00"),
        cost: Decimal.new("40.00")
      }
    ])

    :ok
  end

  test "renders dashboard with KPIs, charts, and chat", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Sales Dashboard"
    assert html =~ "$150.0K" or html =~ "$150"
    assert has_element?(view, "#revenue-chart")
    assert has_element?(view, "#filter-form")
    assert has_element?(view, "#chat-form")
  end

  test "filtering re-renders without crashing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> element("#filter-form")
      |> render_change(%{
        "filters" => %{
          "region" => "East",
          "category" => "",
          "store_id" => "",
          "from" => "",
          "to" => "",
          "granularity" => "month"
        }
      })

    assert html =~ "Sales Dashboard"
    assert html =~ "E01"
  end

  test "store filter accepts multiple stores", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#filter-form")
    |> render_change(%{
      "filters" => %{
        "region" => "",
        "category" => "",
        "store_id" => ["E01", "W01"],
        "from" => "",
        "to" => "",
        "granularity" => "month"
      }
    })

    table_html = view |> element("#stores-table") |> render()
    assert table_html =~ "E01"
    assert table_html =~ "W01"

    view
    |> element("#filter-form")
    |> render_change(%{
      "filters" => %{
        "region" => "",
        "category" => "",
        "store_id" => ["W01"],
        "from" => "",
        "to" => "",
        "granularity" => "month"
      }
    })

    table_html = view |> element("#stores-table") |> render()
    refute table_html =~ "E01"
    assert table_html =~ "W01"
  end

  test "asking a question streams the stub answer", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#chat-form")
    |> render_submit(%{"question" => "what were sales in March?"})

    html = render_async(view, 5_000)
    assert html =~ "what were sales in March?"
    assert html =~ "Stub answer"
  end

  test "llm filter actions update the dashboard", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "W01"

    view
    |> element("#chat-form")
    |> render_submit(%{"question" => "show me east"})

    html = render_async(view, 5_000)
    assert html =~ "applying filters"

    # the region select reflects the applied filter
    assert has_element?(
             view,
             ~s|select[name="filters[region]"] option[value="East"][selected]|
           )

    # the stores table now only shows East stores
    table_html = view |> element("#stores-table") |> render()
    assert table_html =~ "E01"
    refute table_html =~ "W01"
  end
end
