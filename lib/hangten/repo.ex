defmodule Hangten.Repo do
  use Ecto.Repo,
    otp_app: :hangten,
    adapter: Ecto.Adapters.MyXQL
end
