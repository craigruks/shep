defmodule Shep.Config.Schema do
  @moduledoc "Validates and normalizes WORKFLOW.md configuration."

  @defaults %{
    "polling" => %{"interval_ms" => 30_000},
    "workspace" => %{"root" => "~/code/shep_worktrees", "repo" => "."},
    "goal" => %{
      "verify" => nil,
      "verify_fixes" => 2,
      "ci_fixes" => 2
    },
    "agent" => %{
      "command" => "claude",
      "model" => "opus",
      "max_concurrent" => 3,
      "max_turns" => 10,
      "idle_timeout_ms" => 600_000,
      "total_timeout_ms" => 1_200_000
    },
    "hooks" => %{
      "on_worktree_ready" => nil,
      "hook_timeout_ms" => 120_000
    },
    "staging" => %{
      "base_branch" => "staging",
      "pr_target" => "staging"
    },
    "tracker" => %{
      "kind" => "github",
      "repo" => nil
    }
  }

  @doc "Parse and validate a config map (from YAML front matter). Returns normalized config."
  @spec validate(map()) :: {:ok, map()} | {:error, String.t()}
  def validate(raw) when is_map(raw) do
    config = deep_merge(@defaults, raw)

    with :ok <- validate_required(config) do
      expand_path(config)
    end
  end

  defp validate_required(config) do
    case get_in(config, ["agent", "max_concurrent"]) do
      n when is_integer(n) and n > 0 -> :ok
      _ -> {:error, "agent.max_concurrent must be a positive integer"}
    end
  end

  @doc "Merge two maps deeply, with the right side taking precedence."
  @spec deep_merge(map(), map()) :: map()
  def deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn
      _key, left_val, right_val when is_map(left_val) and is_map(right_val) ->
        deep_merge(left_val, right_val)

      _key, _left_val, right_val ->
        right_val
    end)
  end

  defp expand_path(config) do
    root = get_in(config, ["workspace", "root"])

    expanded =
      case root do
        "~/" <> rest -> Path.join(System.user_home!(), rest)
        "~" -> System.user_home!()
        path when is_binary(path) -> path
        nil -> Path.join(System.user_home!(), "code/shep_worktrees")
      end

    expanded_repo =
      case get_in(config, ["workspace", "repo"]) do
        "~/" <> rest -> Path.join(System.user_home!(), rest)
        "~" -> System.user_home!()
        path when is_binary(path) -> path
        nil -> "."
      end

    config = put_in(config, ["workspace", "repo"], expanded_repo)
    {:ok, put_in(config, ["workspace", "root"], expanded)}
  end
end
