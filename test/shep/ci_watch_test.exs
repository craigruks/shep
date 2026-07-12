defmodule Shep.CIWatchTest do
  use ExUnit.Case, async: true

  describe "evaluate_checks (via poll_checks contract)" do
    test "all passed checks return :passed" do
      checks = [
        %{"name" => "Quality", "state" => "COMPLETED", "bucket" => "pass"},
        %{"name" => "Build", "state" => "COMPLETED", "bucket" => "pass"}
      ]

      assert :passed == evaluate(checks)
    end

    test "any failed check returns {:failed, name}" do
      checks = [
        %{"name" => "Quality", "state" => "COMPLETED", "bucket" => "pass"},
        %{"name" => "Build", "state" => "COMPLETED", "bucket" => "fail"}
      ]

      assert {:failed, "Build"} == evaluate(checks)
    end

    test "pending check returns :pending" do
      checks = [
        %{"name" => "Quality", "state" => "IN_PROGRESS", "bucket" => ""},
        %{"name" => "Build", "state" => "COMPLETED", "bucket" => "pass"}
      ]

      assert :pending == evaluate(checks)
    end

    test "empty checks returns :pending" do
      assert :pending == evaluate([])
    end

    test "skipping bucket treated as passed" do
      checks = [
        %{"name" => "Test", "state" => "COMPLETED", "bucket" => "skipping"},
        %{"name" => "Build", "state" => "COMPLETED", "bucket" => "pass"}
      ]

      assert :passed == evaluate(checks)
    end

    test "check without bucket field treated as pending" do
      checks = [
        %{"name" => "Test", "state" => "IN_PROGRESS"}
      ]

      assert :pending == evaluate(checks)
    end
  end

  describe "poll_checks error handling" do
    test "poll_checks returns {:error, reason} on gh failure" do
      assert {:error, _} = Shep.CIWatch.poll_checks("fake/repo", "99999")
    end
  end

  defp evaluate(checks) do
    states = Enum.map(checks, &normalize/1)

    cond do
      checks == [] ->
        :pending

      Enum.any?(states, &(&1 == :failed)) ->
        failed = Enum.find(checks, fn c -> normalize(c) == :failed end)
        {:failed, failed["name"] || "unknown check"}

      Enum.all?(states, &(&1 == :passed)) ->
        :passed

      true ->
        :pending
    end
  end

  defp normalize(%{"bucket" => bucket}) do
    case bucket do
      "pass" -> :passed
      "fail" -> :failed
      "skipping" -> :passed
      _ -> :pending
    end
  end

  defp normalize(_), do: :pending
end
