defmodule Factory.Notifier do
  @moduledoc "Slack webhook notifications for task failures and stalls."

  require Logger

  @doc "Notify on task failure."
  @spec notify_failure(Factory.Task.t(), String.t()) :: :ok
  def notify_failure(%Factory.Task{} = task, reason) do
    post_slack(%{
      text: ":x: Factory task #{task.id} failed",
      blocks: [
        %{type: "section", text: %{type: "mrkdwn", text: "*Task #{task.id}* failed"}},
        %{
          type: "section",
          text: %{type: "mrkdwn", text: "Type: `#{task.type || "custom"}`\nReason: #{reason}"}
        }
      ]
    })
  end

  @doc "Notify on task stall."
  @spec notify_stall(String.t(), non_neg_integer()) :: :ok
  def notify_stall(task_id, idle_ms) do
    minutes = div(idle_ms, 60_000)

    post_slack(%{
      text: ":warning: Factory task #{task_id} stalled (#{minutes}min idle)"
    })
  end

  defp post_slack(payload) do
    url = Application.get_env(:factory, :slack_webhook_url)

    if url do
      Task.start(fn ->
        case Req.post(url, json: payload) do
          {:ok, %{status: 200}} -> :ok
          other -> Logger.warning("Slack notification failed: #{inspect(other)}")
        end
      end)
    end

    :ok
  end
end
