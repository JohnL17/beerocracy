defmodule Mix.Tasks.Beerocracy.MigrateVoters do
  @shortdoc "Adopts votes cast before there were accounts"

  @moduledoc """
  Moves votes filed under a typed name onto the GitHub account that owns them.

  See `Beerocracy.Accounts.Adoption` for what this is for. In development:

      $ mix beerocracy.migrate_voters --list
      $ mix beerocracy.migrate_voters jonas=anehx mira=miradev
      $ mix beerocracy.migrate_voters jonas=anehx mira=miradev --commit

  Nothing is written without `--commit`. `--offline` skips the GitHub lookup and
  works only with people who already have accounts here.

  **The production container has no Mix in it**, so there this is `bin/voters`,
  which takes exactly the same arguments.
  """

  use Mix.Task

  alias Beerocracy.Accounts.Adoption

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    # Every line of this is a query, and in dev the repo logs each one at debug,
    # which buries the report it exists to print.
    Logger.configure(level: :warning)

    strict = [commit: :boolean, list: :boolean, offline: :boolean]

    # Refuse a misspelled flag rather than ignoring it: a silently dropped
    # --offline or --commit means the task does the opposite of what was asked.
    case OptionParser.parse(args, strict: strict) do
      {opts, pairs, []} -> dispatch(opts, pairs)
      {_opts, _pairs, invalid} -> Mix.raise("unknown option: #{unknown(invalid)}")
    end
  end

  defp dispatch(opts, pairs) do
    if Keyword.get(opts, :list, false) or pairs == [] do
      Mix.shell().info(Adoption.listing())
    else
      case Adoption.migrate(pairs, opts) do
        {:ok, %{report: report}} -> Mix.shell().info(report)
        {:error, message} -> Mix.raise(message)
      end
    end
  end

  defp unknown(invalid), do: invalid |> Enum.map_join(", ", &elem(&1, 0))
end
