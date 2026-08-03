defmodule Shep.AgentRunner.Codex do
  @moduledoc "Codex CLI: command building, output parsing. Stub; not yet fully supported."

  require Logger

  @doc """
  Build CLI args for a Codex invocation.

  The prompt is positional and passed after `--`, so a prompt that opens
  with a dash is never read as a flag (`-p` is Codex's `--profile`, not a
  prompt flag).
  """
  @spec build_args(String.t(), String.t(), String.t() | nil) :: [String.t()]
  def build_args(prompt, _task_id, model \\ nil) when is_binary(prompt) do
    Logger.warning("Codex agent support is experimental")
    ["exec"] ++ model_args(model) ++ ["--", prompt]
  end

  @doc """
  Build CLI args for resuming a Codex session.

  `codex exec resume` is the headless form; bare `codex resume` opens the
  interactive picker, which would hang forever behind a Port.
  """
  @spec build_resume_args(String.t(), String.t() | nil) :: [String.t()]
  def build_resume_args(_task_id, model \\ nil) do
    Logger.warning("Codex resume is experimental")
    ["exec", "resume", "--last"] ++ model_args(model)
  end

  defp model_args(nil), do: []
  defp model_args(model) when is_binary(model), do: ["--model", model]

  @doc "Extract text content from Codex CLI output."
  @spec extract_text(String.t()) :: String.t()
  def extract_text(line) when is_binary(line), do: line

  @doc "Session name for a task (Codex uses auto-generated UUIDs)."
  @spec session_name(String.t()) :: String.t()
  def session_name(task_id) when is_binary(task_id), do: "shep-#{task_id}"
end
