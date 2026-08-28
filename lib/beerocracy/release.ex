defmodule Beerocracy.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :beerocracy

  alias Beerocracy.Accounts.Adoption

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Adopts votes cast before there were accounts. See `bin/voters`.

  Takes the same arguments the Mix task does, as a list of strings, because the
  container has no Mix in it:

      bin/voters --list
      bin/voters jonas=anehx --commit
  """
  def voters(args \\ []) do
    {opts, pairs, invalid} =
      OptionParser.parse(args, strict: [commit: :boolean, list: :boolean, offline: :boolean])

    cond do
      invalid != [] ->
        die("unknown option: #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")

      Keyword.get(opts, :list, false) or pairs == [] ->
        with_repo(fn -> IO.puts(Adoption.listing()) end)

      true ->
        with_repo(fn ->
          case Adoption.migrate(pairs, opts) do
            {:ok, %{report: report}} -> IO.puts(report)
            {:error, message} -> die(message)
          end
        end)
    end
  end

  # `eval` runs in a fresh VM with nothing started, so the repo has to be
  # brought up around the work and taken down after — and Req has to be running
  # before any handle can be looked up on GitHub.
  defp with_repo(fun) do
    load_app()
    {:ok, _started} = Application.ensure_all_started(:req)

    {:ok, result, _} = Ecto.Migrator.with_repo(Beerocracy.Repo, fn _repo -> fun.() end)

    result
  end

  # A failed migration must not look like a successful one to whatever ran it.
  defp die(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
