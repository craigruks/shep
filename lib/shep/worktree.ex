defmodule Shep.Worktree do
  @moduledoc "Git worktree lifecycle: create, remove, prune."

  require Logger

  @doc "Create a worktree for the given branch, branching from base_branch. `repo` is the git repo to cut from."
  @spec create(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def create(branch, base_branch, root, repo \\ ".")
      when is_binary(branch) and is_binary(base_branch) do
    safe_name = sanitize_branch(branch)
    path = Path.expand(Path.join(root, safe_name))

    cleanup_stale(branch, path, repo)

    case System.cmd("git", ["-C", repo, "worktree", "add", "-b", branch, path, base_branch],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        Logger.info("Created worktree at #{path}")
        {:ok, path}

      {output, _code} ->
        {:error, "git worktree add failed: #{String.trim(output)}"}
    end
  end

  defp cleanup_stale(branch, path, repo) do
    if File.dir?(path) do
      Logger.info("Removing stale worktree: #{path}")
      System.cmd("git", ["-C", repo, "worktree", "remove", path, "--force"], stderr_to_stdout: true)
    end

    case System.cmd("git", ["-C", repo, "branch", "-D", branch], stderr_to_stdout: true) do
      {_, 0} -> Logger.info("Removed stale branch: #{branch}")
      _ -> :ok
    end

    prune(repo)
  end

  @doc "Remove a worktree. Preserves if there are uncommitted changes."
  @spec remove(String.t(), String.t()) :: :ok | {:error, String.t()}
  def remove(path, repo \\ ".") when is_binary(path) do
    if has_uncommitted_changes?(path) do
      Logger.warning("Preserving dirty worktree: #{path}")
      {:error, "worktree has uncommitted changes"}
    else
      case System.cmd("git", ["-C", repo, "worktree", "remove", path], stderr_to_stdout: true) do
        {_output, 0} ->
          Logger.info("Removed worktree: #{path}")
          :ok

        {output, _code} ->
          {:error, "git worktree remove failed: #{String.trim(output)}"}
      end
    end
  end

  @doc "Check if a worktree has uncommitted changes."
  @spec has_uncommitted_changes?(String.t()) :: boolean()
  def has_uncommitted_changes?(path) when is_binary(path) do
    case System.cmd("git", ["-C", path, "status", "--porcelain"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) != ""
      _ -> true
    end
  end

  @doc "Prune stale worktree references."
  @spec prune(String.t()) :: :ok
  def prune(repo \\ ".") do
    System.cmd("git", ["-C", repo, "worktree", "prune"], stderr_to_stdout: true)
    :ok
  end

  @doc "List all worktree paths under the given root."
  @spec list(String.t()) :: [String.t()]
  def list(root) when is_binary(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.dir?/1)

      {:error, _} ->
        []
    end
  end

  @doc false
  def sanitize_branch_for_test(branch), do: sanitize_branch(branch)

  defp sanitize_branch(branch) do
    branch
    |> String.replace(~r/[^a-zA-Z0-9_\-]/, "_")
    |> String.trim_leading("_")
  end
end
