defmodule Shep.Completion do
  @moduledoc "Parses `<completion>` JSON blocks from agent stdout."

  alias Shep.Completion.{Complete, Continue, Failed}

  @completion_regex ~r/<completion>(.*?)<\/completion>/s

  @doc "Extract a completion signal from a line of agent output."
  @spec parse(String.t()) :: Complete.t() | Failed.t() | Continue.t() | nil
  def parse(line) when is_binary(line) do
    case Regex.run(@completion_regex, line) do
      [_, json] -> decode(json)
      _ -> nil
    end
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, %{"type" => "complete"} = map} ->
        %Complete{
          summary: Map.get(map, "summary", ""),
          verify: Map.get(map, "verify", [])
        }

      {:ok, %{"type" => "failed"} = map} ->
        %Failed{
          reason: Map.get(map, "reason", "unknown"),
          recoverable: Map.get(map, "recoverable", false)
        }

      {:ok, %{"type" => "continue"}} ->
        %Continue{}

      _ ->
        nil
    end
  end
end
