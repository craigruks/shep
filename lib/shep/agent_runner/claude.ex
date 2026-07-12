defmodule Shep.AgentRunner.Claude do
  @moduledoc "Claude Code CLI: command building, output parsing, session naming."

  @doc "Build CLI args for a fresh Claude Code invocation."
  @spec build_args(String.t(), String.t()) :: [String.t()]
  def build_args(prompt, task_id) when is_binary(prompt) and is_binary(task_id) do
    [
      "--print",
      "--dangerously-skip-permissions",
      "--verbose",
      "--output-format",
      "stream-json",
      "--name",
      session_name(task_id),
      "-p",
      prompt
    ]
  end

  @doc "Build CLI args for resuming an existing Claude Code session."
  @spec build_resume_args(String.t()) :: [String.t()]
  def build_resume_args(task_id) when is_binary(task_id) do
    [
      "--print",
      "--dangerously-skip-permissions",
      "--verbose",
      "--output-format",
      "stream-json",
      "--continue",
      "--name",
      session_name(task_id)
    ]
  end

  @doc "Extract text content from a Claude Code stream-json line."
  @spec extract_text(String.t()) :: String.t()
  def extract_text(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "assistant", "message" => %{"content" => content}}} ->
        content
        |> Enum.filter(&(&1["type"] == "text"))
        |> Enum.map_join("\n", & &1["text"])

      {:ok, %{"type" => "result", "result" => result}} when is_binary(result) ->
        result

      _ ->
        line
    end
  end

  @doc "Session name for a task."
  @spec session_name(String.t()) :: String.t()
  def session_name(task_id) when is_binary(task_id), do: "shep-#{task_id}"
end
