defmodule Shep.CompletionTest do
  use ExUnit.Case, async: true

  alias Shep.Completion
  alias Shep.Completion.{Complete, Continue, Failed}

  describe "parse/1" do
    test "parses complete signal" do
      line =
        ~s(<completion>{"type":"complete","summary":"fixed the bug","verify":["tests pass"]}</completion>)

      assert %Complete{summary: "fixed the bug", verify: ["tests pass"]} = Completion.parse(line)
    end

    test "parses complete signal without verify" do
      line = ~s(<completion>{"type":"complete","summary":"done"}</completion>)
      assert %Complete{summary: "done", verify: []} = Completion.parse(line)
    end

    test "parses failed signal" do
      line =
        ~s(<completion>{"type":"failed","reason":"cannot fix","recoverable":false}</completion>)

      assert %Failed{reason: "cannot fix", recoverable: false} = Completion.parse(line)
    end

    test "parses failed recoverable signal" do
      line =
        ~s(<completion>{"type":"failed","reason":"rate limited","recoverable":true}</completion>)

      assert %Failed{reason: "rate limited", recoverable: true} = Completion.parse(line)
    end

    test "parses continue signal" do
      line = ~s(<completion>{"type":"continue"}</completion>)
      assert %Continue{} = Completion.parse(line)
    end

    test "returns nil for non-completion lines" do
      assert nil == Completion.parse("just some output")
      assert nil == Completion.parse("")
      assert nil == Completion.parse("<completion>not json</completion>")
    end

    test "returns nil for unknown type" do
      line = ~s(<completion>{"type":"unknown"}</completion>)
      assert nil == Completion.parse(line)
    end

    test "handles completion embedded in other text" do
      line =
        ~s(Some prefix text <completion>{"type":"complete","summary":"done"}</completion> trailing)

      assert %Complete{summary: "done"} = Completion.parse(line)
    end
  end
end
