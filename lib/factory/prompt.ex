defmodule Factory.Prompt do
  @moduledoc "Expands `!`command`` shell blocks and `{{KEY}}` substitutions in prompt templates."

  require Logger

  @soh <<1>>
  @shell_regex ~r/!`([^`]+)`/
  @key_regex ~r/\{\{(\w+)\}\}/
  @shell_timeout_ms 30_000

  @doc "Expand a prompt template: run shell commands, substitute keys."
  @spec expand(String.t(), %{String.t() => String.t()}, String.t()) :: String.t()
  def expand(template, args, cwd) when is_binary(template) and is_map(args) and is_binary(cwd) do
    template
    |> expand_shell(cwd)
    |> expand_keys(args)
  end

  defp expand_shell(template, cwd) do
    blocks = Regex.scan(@shell_regex, template, return: :index)

    if blocks == [] do
      template
    else
      results = run_shell_blocks(template, blocks, cwd)
      apply_shell_results(template, blocks, results)
    end
  end

  defp run_shell_blocks(template, blocks, cwd) do
    blocks
    |> Enum.map(fn [{_full_start, _full_len}, {cmd_start, cmd_len}] ->
      binary_part(template, cmd_start, cmd_len)
    end)
    |> Task.async_stream(
      fn cmd -> run_command(cmd, cwd) end,
      timeout: @shell_timeout_ms,
      ordered: true
    )
    |> Enum.map(fn
      {:ok, output} -> @soh <> String.trim(output)
      {:exit, :timeout} -> @soh <> "[timeout: command exceeded #{@shell_timeout_ms}ms]"
    end)
  end

  defp apply_shell_results(template, blocks, results) do
    {output, _offset} =
      Enum.zip(blocks, results)
      |> Enum.reduce({template, 0}, fn {[{start, len} | _], replacement}, {acc, offset} ->
        before = binary_part(acc, 0, start + offset)
        after_part = binary_part(acc, start + offset + len, byte_size(acc) - (start + offset + len))
        new_acc = before <> replacement <> after_part
        {new_acc, offset + byte_size(replacement) - len}
      end)

    output
  end

  defp run_command(cmd, cwd) do
    case System.cmd("bash", ["-c", cmd], cd: cwd, stderr_to_stdout: true) do
      {output, 0} ->
        output

      {output, code} ->
        Logger.warning("Shell command exited #{code}: #{cmd}")
        output
    end
  end

  defp expand_keys(template, args) do
    Regex.replace(@key_regex, template, fn _full, key ->
      case Map.fetch(args, key) do
        {:ok, value} -> value
        :error -> "{{#{key}}}"
      end
    end)
  end
end
