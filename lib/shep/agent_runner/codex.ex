defmodule Shep.AgentRunner.Codex do
  @moduledoc "Codex CLI: command building, output parsing. Stub; not yet fully supported."

  require Logger

  @doc "Build CLI args for a Codex invocation."
  @spec build_args(String.t(), String.t(), String.t() | nil) :: [String.t()]
  def build_args(prompt, _task_id, _model \\ nil) when is_binary(prompt) do
    Logger.warning("Codex agent support is experimental")
    ["exec", "-p", prompt]
  end

  @doc "Build CLI args for resuming a Codex session."
  @spec build_resume_args(String.t(), String.t() | nil) :: [String.t()]
  def build_resume_args(_task_id, _model \\ nil) do
    Logger.warning("Codex resume is experimental")
    ["resume", "--last"]
  end

  @doc "Extract text content from Codex CLI output."
  @spec extract_text(String.t()) :: String.t()
  def extract_text(line) when is_binary(line), do: line

  @doc "Session name for a task (Codex uses auto-generated UUIDs)."
  @spec session_name(String.t()) :: String.t()
  def session_name(task_id) when is_binary(task_id), do: "shep-#{task_id}"
end
