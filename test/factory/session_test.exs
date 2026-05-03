defmodule Factory.SessionTest do
  use ExUnit.Case, async: true

  alias Factory.Session

  describe "parse/1" do
    test "parses session JSONL with token usage" do
      path =
        write_temp_jsonl([
          %{"type" => "human", "message" => "hello"},
          %{
            "type" => "assistant",
            "message" => "hi",
            "usage" => %{
              "inputTokens" => 100,
              "outputTokens" => 50,
              "cacheCreationInputTokens" => 200,
              "cacheReadInputTokens" => 80
            }
          },
          %{
            "type" => "assistant",
            "message" => "done",
            "usage" => %{"inputTokens" => 120, "outputTokens" => 60}
          }
        ])

      assert {:ok, stats} = Session.parse(path)
      assert stats.input_tokens == 220
      assert stats.output_tokens == 110
      assert stats.cache_creation_tokens == 200
      assert stats.cache_read_tokens == 80
      assert stats.turns == 2
    end

    test "returns empty stats for no assistant entries" do
      path = write_temp_jsonl([%{"type" => "human", "message" => "hi"}])
      assert {:ok, stats} = Session.parse(path)
      assert stats == Session.empty_stats()
    end

    test "returns error for missing file" do
      assert {:error, _} = Session.parse("/tmp/nonexistent_#{System.unique_integer()}.jsonl")
    end
  end

  describe "empty_stats/0" do
    test "returns zeroed map" do
      stats = Session.empty_stats()
      assert stats.input_tokens == 0
      assert stats.output_tokens == 0
      assert stats.turns == 0
    end
  end

  defp write_temp_jsonl(entries) do
    path = Path.join(System.tmp_dir!(), "session_test_#{System.unique_integer([:positive])}.jsonl")
    content = Enum.map_join(entries, "\n", &Jason.encode!/1)
    File.write!(path, content)
    path
  end
end
