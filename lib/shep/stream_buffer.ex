defmodule Shep.StreamBuffer do
  @moduledoc "Buffers single-token streams into readable chunks for logs and display."

  @enforce_keys [:chunks]
  defstruct chunks: [], pending: "", last_flush: nil

  @type t :: %__MODULE__{
          chunks: [String.t()],
          pending: String.t(),
          last_flush: integer() | nil
        }

  @flush_threshold 80
  @sentence_terminators [?., ?!, ??, ?\n]

  @doc "Create a new empty buffer."
  @spec new() :: t()
  def new, do: %__MODULE__{chunks: [], last_flush: now_ms()}

  @doc "Append text to the buffer. Returns `{flushed_text | nil, updated_buffer}`."
  @spec append(t(), String.t()) :: {String.t() | nil, t()}
  def append(%__MODULE__{} = buf, text) when is_binary(text) do
    new_pending = buf.pending <> text

    cond do
      should_flush?(new_pending, buf.last_flush) ->
        {String.trim(new_pending), %{buf | pending: "", last_flush: now_ms()}}

      true ->
        {nil, %{buf | pending: new_pending}}
    end
  end

  @doc "Force-flush any remaining content."
  @spec flush(t()) :: {String.t() | nil, t()}
  def flush(%__MODULE__{pending: ""} = buf), do: {nil, buf}

  def flush(%__MODULE__{} = buf) do
    {String.trim(buf.pending), %{buf | pending: "", last_flush: now_ms()}}
  end

  defp should_flush?(text, _last_flush) when byte_size(text) >= @flush_threshold, do: true

  defp should_flush?(text, _last_flush) do
    case :binary.last(text) do
      char when char in @sentence_terminators -> byte_size(text) > 0
      _ -> false
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
