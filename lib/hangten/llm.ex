defmodule Hangten.LLM do
  @moduledoc """
  LLM facade. Delegates to the configured backend module
  (`Hangten.LLM.Ollama` in dev/prod, `Hangten.LLM.Stub` in test).

  Both backends return the same contract:

      {:ok, %{text: String.t(), filters: map() | :reset | nil,
              sql: String.t() | nil, query_result: map() | nil,
              thinking: String.t() | nil}}

  `filters` uses the dashboard filter keys (`:region`, `:category`,
  `:store_id`, `:from`, `:to`). A map is merged into the active filters,
  `:reset` clears them, `nil` leaves them alone.

  `query_result` is `%{columns: [String.t()], rows: [[term]]}` when the
  backend ran a SQL query, `%{error: String.t()}` on failure, or `nil`.

  `history` is a list of `%{role: "user" | "assistant", content: String.t()}`
  maps from previous turns — the backend may cap how much it sends.

  `context` carries current dashboard state (e.g. `%{widgets: [...]}`) so the
  backend can mention what is on screen.
  """

  @spec answer(String.t(), [map()], map()) :: {:ok, map()} | {:error, term()}
  def answer(question, history \\ [], context \\ %{}),
    do: backend().answer(question, history, context)

  defp backend do
    :hangten
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:backend, Hangten.LLM.Ollama)
  end
end
