defmodule Factory.Session do
  @moduledoc "Parses Claude Code session JSONL files for token usage and cache metrics."

  @doc "Parse a session JSONL file and extract token usage summary."
  @spec parse(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse(path) when is_binary(path) do
    if File.exists?(path) do
      stats =
        path
        |> File.stream!()
        |> Stream.map(&decode_line/1)
        |> Stream.reject(&is_nil/1)
        |> Enum.reduce(empty_stats(), &accumulate/2)

      {:ok, stats}
    else
      {:error, "file not found: #{path}"}
    end
  end

  @doc "Find the most recent session file for a given project directory."
  @spec find_latest(String.t()) :: String.t() | nil
  def find_latest(project_dir) when is_binary(project_dir) do
    sessions_dir = Path.join([System.user_home!(), ".claude", "projects", project_dir])

    case File.ls(sessions_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.sort(:desc)
        |> List.first()
        |> then(fn
          nil -> nil
          file -> Path.join(sessions_dir, file)
        end)

      {:error, _} ->
        nil
    end
  end

  @doc "Return an empty stats map."
  @spec empty_stats() :: map()
  def empty_stats do
    %{
      input_tokens: 0,
      output_tokens: 0,
      cache_creation_tokens: 0,
      cache_read_tokens: 0,
      turns: 0
    }
  end

  defp decode_line(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, map} -> map
      {:error, _} -> nil
    end
  end

  defp accumulate(%{"type" => "assistant"} = entry, stats) do
    usage = Map.get(entry, "usage", %{})

    %{
      stats
      | input_tokens: stats.input_tokens + Map.get(usage, "inputTokens", 0),
        output_tokens: stats.output_tokens + Map.get(usage, "outputTokens", 0),
        cache_creation_tokens:
          stats.cache_creation_tokens + Map.get(usage, "cacheCreationInputTokens", 0),
        cache_read_tokens: stats.cache_read_tokens + Map.get(usage, "cacheReadInputTokens", 0),
        turns: stats.turns + 1
    }
  end

  defp accumulate(_entry, stats), do: stats
end
