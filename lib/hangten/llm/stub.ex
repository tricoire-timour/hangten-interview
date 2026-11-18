defmodule Hangten.LLM.Stub do
  @moduledoc """
  Keyword-matching stub used in tests and as a fallback when no real
  backend is available. Returns the same contract as `Hangten.LLM.Ollama`.
  """

  @regions ~w(East North South West)
  @categories ~w(Accessories Apparel Footwear Home)

  @spec answer(String.t(), [map()], map()) :: {:ok, map()} | {:error, term()}
  def answer(question, _history \\ [], _context \\ %{}) do
    Process.sleep(600)

    downcased = String.downcase(question)
    filters = extract_filters(downcased)

    cond do
      Regex.match?(~r/\b(reset|clear)\b/, downcased) ->
        {:ok, %{text: "Clearing all dashboard filters.", filters: :reset}}

      map_size(filters) > 0 ->
        applied = Enum.map_join(filters, ", ", fn {k, v} -> "#{k}: #{v}" end)

        {:ok,
         %{
           text:
             ~s(Stub: applying filters — #{applied}.) <>
               "\n\nA real LLM backend would also explain the data behind the change.",
           filters: filters
         }}

      true ->
        {:ok,
         %{
           text:
             ~s(Stub answer to: "#{question}"\n\n) <>
               "Try mentioning a region (East/North/South/West), a category, " <>
               "a store id (e.g. E01), or \"clear filters\" — I'll apply them " <>
               "to the dashboard.",
           filters: nil
         }}
    end
  end

  defp extract_filters(downcased) do
    %{}
    |> maybe_put(
      :region,
      Enum.find(@regions, &String.contains?(downcased, String.downcase(&1)))
    )
    |> maybe_put(
      :category,
      Enum.find(@categories, &String.contains?(downcased, String.downcase(&1)))
    )
    |> maybe_put(:store_id, extract_store(downcased))
  end

  defp extract_store(downcased) do
    case Regex.run(~r/\b[a-z]\d{2}\b/, downcased) do
      [store] -> String.upcase(store)
      _ -> nil
    end
  end

  defp maybe_put(filters, _key, nil), do: filters
  defp maybe_put(filters, key, value), do: Map.put(filters, key, value)
end
