defmodule Factory.Config do
  @moduledoc "Hot-reloading GenServer for WORKFLOW.md configuration."

  use GenServer

  require Logger

  @poll_interval_ms 1_000

  defstruct [:path, :stamp, :config]

  @doc "Get the current config."
  @spec current() :: {:ok, map()} | {:error, String.t()}
  def current do
    GenServer.call(__MODULE__, :current)
  end

  @doc "Get the current config or raise."
  @spec current!() :: map()
  def current! do
    case current() do
      {:ok, config} -> config
      {:error, reason} -> raise "Factory.Config: #{reason}"
    end
  end

  @doc "Force an immediate reload."
  @spec force_reload() :: {:ok, map()} | {:error, String.t()}
  def force_reload do
    GenServer.call(__MODULE__, :force_reload)
  end

  def start_link(opts) do
    path = Keyword.get(opts, :path, Application.get_env(:factory, :workflow_path, "WORKFLOW.md"))
    GenServer.start_link(__MODULE__, %{path: path}, name: __MODULE__)
  end

  @impl true
  def init(%{path: path}) do
    state = %__MODULE__{path: path, stamp: nil, config: nil}

    case load_config(state) do
      {:ok, new_state} ->
        schedule_poll()
        {:ok, new_state}

      {:error, reason} ->
        Logger.warning("WORKFLOW.md not found (#{reason}), starting with defaults")
        {:ok, default} = Factory.Config.Schema.validate(%{})
        schedule_poll()
        {:ok, %{state | config: default}}
    end
  end

  @impl true
  def handle_call(:current, _from, state) do
    case maybe_reload(state) do
      {:ok, new_state} -> {:reply, {:ok, new_state.config}, new_state}
      {:error, _reason} -> {:reply, {:ok, state.config}, state}
    end
  end

  @impl true
  def handle_call(:force_reload, _from, state) do
    case load_config(state) do
      {:ok, new_state} -> {:reply, {:ok, new_state.config}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    new_state =
      case maybe_reload(state) do
        {:ok, s} -> s
        {:error, _} -> state
      end

    schedule_poll()
    {:noreply, new_state}
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp maybe_reload(state) do
    current_stamp = file_stamp(state.path)

    if current_stamp != state.stamp do
      load_config(state)
    else
      {:ok, state}
    end
  end

  defp load_config(state) do
    case parse_workflow(state.path) do
      {:ok, raw} ->
        case Factory.Config.Schema.validate(raw) do
          {:ok, config} ->
            stamp = file_stamp(state.path)
            Logger.debug("Loaded WORKFLOW.md config")
            {:ok, %{state | config: config, stamp: stamp}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp file_stamp(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime, size: size}} -> {mtime, size}
      {:error, _} -> nil
    end
  end

  defp parse_workflow(path) do
    case File.read(path) do
      {:ok, content} -> extract_yaml_frontmatter(content)
      {:error, reason} -> {:error, "cannot read #{path}: #{reason}"}
    end
  end

  defp extract_yaml_frontmatter(content) do
    case String.split(content, "---", parts: 3) do
      [_, yaml, _] ->
        case YamlElixir.read_from_string(yaml) do
          {:ok, map} when is_map(map) -> {:ok, map}
          {:ok, _} -> {:ok, %{}}
          {:error, reason} -> {:error, "YAML parse error: #{inspect(reason)}"}
        end

      _ ->
        {:ok, %{}}
    end
  end
end
