defmodule Shep.NotifierTest do
  # Reads the :slack_webhook_url app env, so no concurrent cases.
  use ExUnit.Case, async: false

  setup do
    original = Application.get_env(:shep, :slack_webhook_url)
    Application.delete_env(:shep, :slack_webhook_url)
    on_exit(fn -> Application.put_env(:shep, :slack_webhook_url, original) end)
    :ok
  end

  test "notify_failure is a no-op :ok without a webhook configured" do
    task = %Shep.Task{id: "n1", branch: "b", prompt: "p"}
    assert :ok = Shep.Notifier.notify_failure(task, "it broke")
  end

  test "notify_stall is a no-op :ok without a webhook configured" do
    assert :ok = Shep.Notifier.notify_stall("n2", 600_000)
  end
end
