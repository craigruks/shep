defmodule Shep.FailureReport do
  @moduledoc """
  Tell the tracker a task failed: move the issue to `shep:failed`, post
  the reason with the tail of the output that ended the task, and ping
  Slack.

  Every way a task gives up goes through `post/3` — verify exhaustion,
  CI give-up, an agent that failed outright — so none of them leaves
  the issue sitting at `shep:in-progress` with nobody told.

  The comment is public, so the output is redacted before it is posted:
  known token shapes (`ghp_`, `gho_`, `github_pat_`, `sk-`, `xox…`), long
  hex runs, and long high-entropy base64 runs become `[REDACTED]`. A 40-char
  git SHA is a long hex run too; losing one from a failure tail is the
  price of never posting a 40-hex OAuth token.
  """

  require Logger

  @tail_lines 30
  @max_chars 4_000
  @redacted "[REDACTED]"

  @token_patterns [
    ~r/\bgh[opusr]_[A-Za-z0-9]{16,}/,
    ~r/\bgithub_pat_[A-Za-z0-9_]{16,}/,
    ~r/\bsk-[A-Za-z0-9_\-]{16,}/,
    ~r/\bxox[a-z]-[A-Za-z0-9\-]{8,}/
  ]
  @hex_run ~r/\b[0-9a-fA-F]{32,}\b/
  @base64_run ~r/[A-Za-z0-9+\/_\-]{32,}={0,2}/
  # Bits per char. File paths and identifiers sit near 4.0; random
  # base64 of this length sits at 4.6 and up.
  @min_entropy 4.4

  @doc """
  Mark the task failed on the tracker and post the reason plus the
  redacted output tail as a comment. Tracker errors are logged by the
  adapter and do not stop the report.
  """
  @spec post(Shep.Task.t(), String.t(), String.t() | nil) :: :ok
  def post(%Shep.Task{} = task, reason, output) when is_binary(reason) do
    Logger.error("Goal not reached for task #{task.id}: #{reason}")
    Shep.Tracker.update_status(task.id, "failed")
    Shep.Tracker.add_comment(task.id, body(reason, output))
    Shep.Notifier.notify_failure(task, redact(reason))
    :ok
  end

  @doc "The comment body: the redacted reason, then the output tail collapsed."
  @spec body(String.t(), String.t() | nil) :: String.t()
  def body(reason, output) when is_binary(reason) do
    heading = "Goal not reached: #{redact(reason)}"

    case tail(output) do
      "" -> heading
      tail -> heading <> "\n\n" <> details(tail)
    end
  end

  @doc """
  The last #{@tail_lines} lines of `output`, redacted, capped at
  #{@max_chars} characters. Lines are cut before redacting (a token never
  spans lines, so none is split) and characters after (a cut can only
  shorten a `[REDACTED]`, never expose what it replaced).
  """
  @spec tail(String.t() | nil) :: String.t()
  def tail(nil), do: ""

  def tail(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.take(-@tail_lines)
    |> Enum.join("\n")
    |> redact()
    |> String.trim()
    |> String.slice(-@max_chars, @max_chars)
  end

  @doc "Replace anything that looks like a credential with `[REDACTED]`."
  @spec redact(String.t()) :: String.t()
  def redact(text) when is_binary(text) do
    text = Enum.reduce(@token_patterns, text, &Regex.replace(&1, &2, @redacted))
    text = Regex.replace(@hex_run, text, @redacted)

    Regex.replace(@base64_run, text, fn run ->
      if entropy(run) >= @min_entropy, do: @redacted, else: run
    end)
  end

  # A fence one backtick longer than any run in the content, so output
  # that itself contains ``` cannot close the block early.
  defp details(tail) do
    longest =
      ~r/`+/
      |> Regex.scan(tail)
      |> Enum.map(fn [run] -> String.length(run) end)
      |> Enum.max(fn -> 0 end)

    fence = String.duplicate("`", max(3, longest + 1))

    """
    <details><summary>Last output</summary>

    #{fence}
    #{tail}
    #{fence}

    </details>\
    """
  end

  defp entropy(run) do
    n = byte_size(run)

    run
    |> :binary.bin_to_list()
    |> Enum.frequencies()
    |> Map.values()
    |> Enum.reduce(0.0, fn count, acc ->
      p = count / n
      acc - p * :math.log2(p)
    end)
  end
end
