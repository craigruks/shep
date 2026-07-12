defmodule Shep.StreamBufferTest do
  use ExUnit.Case, async: true

  alias Shep.StreamBuffer

  describe "new/0" do
    test "creates empty buffer" do
      buf = StreamBuffer.new()
      assert buf.pending == ""
      assert buf.chunks == []
    end
  end

  describe "append/2" do
    test "buffers small input without flushing" do
      buf = StreamBuffer.new()
      {flushed, _buf} = StreamBuffer.append(buf, "hello")
      assert flushed == nil
    end

    test "flushes on sentence terminator" do
      buf = StreamBuffer.new()
      {flushed, _buf} = StreamBuffer.append(buf, "Hello world.")
      assert flushed == "Hello world."
    end

    test "flushes on newline" do
      buf = StreamBuffer.new()
      {flushed, _buf} = StreamBuffer.append(buf, "Hello world\n")
      assert flushed == "Hello world"
    end

    test "flushes on threshold" do
      buf = StreamBuffer.new()
      long = String.duplicate("x", 81)
      {flushed, _buf} = StreamBuffer.append(buf, long)
      assert flushed == long
    end

    test "accumulates across multiple appends" do
      buf = StreamBuffer.new()
      {nil, buf} = StreamBuffer.append(buf, "hello ")
      {flushed, _buf} = StreamBuffer.append(buf, "world.")
      assert flushed == "hello world."
    end
  end

  describe "flush/1" do
    test "flushes remaining content" do
      buf = StreamBuffer.new()
      {nil, buf} = StreamBuffer.append(buf, "leftover")
      {flushed, _buf} = StreamBuffer.flush(buf)
      assert flushed == "leftover"
    end

    test "returns nil for empty buffer" do
      buf = StreamBuffer.new()
      {flushed, _buf} = StreamBuffer.flush(buf)
      assert flushed == nil
    end
  end
end
