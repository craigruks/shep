defmodule Shep.RunLogger do
  @moduledoc "Telemetry handlers: JSONL file sink + Axiom sink for agent lifecycle events."

  require Logger

  @runs_dir ".shep/runs"

  @doc "Attach all telemetry handlers."
  @spec attach() :: :ok
  def attach do
    events = [
      [:shep, :agent, :start],
      [:shep, :agent, :stop],
      [:shep, :agent, :stdout],
      [:shep, :orchestrator, :dispatch],
      [:shep, :hook, :start],
      [:shep, :hook, :stop]
    ]

    :telemetry.attach_many("shep-jsonl-logger", events, &__MODULE__.handle_event/4, :jsonl)
    :telemetry.attach_many("shep-axiom-logger", events, &__MODULE__.handle_event/4, :axiom)

    :telemetry.attach_many(
      "shep-stdout-logger",
      [[:shep, :agent, :stdout], [:shep, :agent, :stop]],
      &__MODULE__.handle_event/4,
      :stdout
    )

    :ok
  end

  @doc "Detach all telemetry handlers."
  @spec detach() :: :ok
  def detach do
    :telemetry.detach("shep-jsonl-logger")
    :telemetry.detach("shep-axiom-logger")
    :telemetry.detach("shep-stdout-logger")
    :ok
  end

  @doc "Handle a telemetry event."
  def handle_event(event, measurements, metadata, :jsonl) do
    write_jsonl(event, measurements, metadata)
  end

  def handle_event(event, measurements, metadata, :axiom) do
    emit_axiom(event, measurements, metadata)
  end

  def handle_event([:shep, :agent, :stdout], _measurements, metadata, :stdout) do
    write_stdout(metadata)
  end

  def handle_event([:shep, :agent, :stop], measurements, metadata, :stdout) do
    write_stdout_marker(metadata, measurements)
  end

  defp write_jsonl(event, measurements, metadata) do
    task_id = Map.get(metadata, :task_id)
    if task_id == nil, do: throw(:no_task_id)

    File.mkdir_p!(@runs_dir)
    path = Path.join(@runs_dir, "#{task_id}.jsonl")

    entry =
      %{
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        event: Enum.join(event, "."),
        measurements: sanitize(measurements),
        metadata: sanitize(Map.delete(metadata, :line))
      }
      |> Jason.encode!()

    File.write!(path, entry <> "\n", [:append])
  catch
    :no_task_id -> :ok
  end

  defp write_stdout(%{task_id: task_id, line: line}) when is_binary(task_id) and is_binary(line) do
    case format_line(line) do
      nil ->
        :ok

      formatted ->
        File.mkdir_p!(@runs_dir)
        path = Path.join(@runs_dir, "#{task_id}.stdout.log")
        ts = DateTime.utc_now() |> Calendar.strftime("%H:%M:%S")
        File.write!(path, "[#{ts}] #{formatted}\n", [:append])
    end
  end

  defp write_stdout(_metadata), do: :ok

  defp write_stdout_marker(%{task_id: task_id, completion: completion}, %{duration_ms: ms})
       when is_binary(task_id) do
    status =
      case completion do
        %Shep.Completion.Failed{} -> "FAILED"
        _ -> "COMPLETE"
      end

    secs = div(ms, 1000)
    path = Path.join(@runs_dir, "#{task_id}.stdout.log")
    File.write!(path, "=== TASK #{status} (#{secs}s) ===\n", [:append])
  end

  defp write_stdout_marker(_metadata, _measurements), do: :ok

  defp format_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "assistant", "message" => %{"content" => content}}} ->
        texts =
          content
          |> Enum.filter(&(&1["type"] == "text"))
          |> Enum.map_join("\n", & &1["text"])

        if texts != "", do: texts

      {:ok, %{"type" => "tool_use", "tool" => %{"name" => name}}} ->
        "→ #{name}"

      {:ok, %{"type" => "tool_result", "content" => content}} when is_binary(content) ->
        truncated = String.slice(content, 0, 200)
        if truncated != content, do: "  ← #{truncated}…", else: "  ← #{content}"

      {:ok, %{"type" => "result", "result" => result}} when is_binary(result) ->
        "✓ #{String.slice(result, 0, 200)}"

      {:error, _} ->
        clean = String.replace(line, ~r/\e\[[0-9;]*m/, "")
        if String.trim(clean) != "", do: clean

      _ ->
        nil
    end
  end

  defp emit_axiom(event, measurements, metadata) do
    token = Application.get_env(:shep, :axiom_token)
    if token == nil, do: throw(:no_token)

    payload = %{
      _time: DateTime.utc_now() |> DateTime.to_iso8601(),
      event: Enum.join(event, "."),
      measurements: sanitize(measurements),
      task_id: Map.get(metadata, :task_id),
      task_type: Map.get(metadata, :task_type),
      source: "shep"
    }

    dataset = Application.get_env(:shep, :axiom_dataset, "shep-events")

    Task.start(fn ->
      Req.post("https://api.axiom.co/v1/datasets/#{dataset}/ingest",
        json: [payload],
        headers: [{"authorization", "Bearer #{token}"}]
      )
    end)
  catch
    :no_token -> :ok
  end

  defp sanitize(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_struct(v) -> {k, inspect(v)}
      {k, v} when is_pid(v) -> {k, inspect(v)}
      {k, v} when is_reference(v) -> {k, inspect(v)}
      {k, v} when is_function(v) -> {k, inspect(v)}
      {k, v} -> {k, v}
    end)
  end

  defp sanitize(other), do: other
end
