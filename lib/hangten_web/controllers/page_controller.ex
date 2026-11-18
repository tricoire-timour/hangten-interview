defmodule HangtenWeb.PageController do
  use HangtenWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
