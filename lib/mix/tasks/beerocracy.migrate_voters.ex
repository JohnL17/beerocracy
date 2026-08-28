defmodule Mix.Tasks.Beerocracy.MigrateVoters do
  @shortdoc "Adopts votes cast before there were accounts"

  @moduledoc """
  Moves votes filed under a typed name onto the GitHub account that owns them.

  Before signing in existed, a voter was whatever name they typed, normalised —
  `jonas`. Now they are their GitHub account — `gh:1234`. Votes cast under the
  old scheme belong to nobody, which matters for any week still open: their
  owner votes again as themselves and the sheet counts them twice.

  Run it with no arguments — or `--list` — to see who is still unmigrated and
  what it would guess for each:

      $ mix beerocracy.migrate_voters
      $ mix beerocracy.migrate_voters --list

  Then map each old key onto a GitHub handle. Nothing is written without
  `--commit`, so the plan is safe to read first:

      $ mix beerocracy.migrate_voters jonas=anehx mira=miradev
      $ mix beerocracy.migrate_voters jonas=anehx mira=miradev --commit

  The handle has to belong to somebody who has signed in at least once — that
  is what creates the account to file the votes under.

  Where a person voted under both schemes in the same week, the vote they cast
  as themselves is the one that survives; the orphan is dropped rather than
  merged, because two answers to the same question are not additive.
  """

  use Mix.Task

  alias Beerocracy.Accounts
  alias Beerocracy.Accounts.User
  alias Beerocracy.Voting

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    # Every line of this task is a query, and in dev the repo logs each one at
    # debug — which buries the report it exists to print.
    Logger.configure(level: :warning)

    {opts, pairs, _} = OptionParser.parse(args, strict: [commit: :boolean, list: :boolean])

    case {Keyword.get(opts, :list, false), parse_pairs(pairs)} do
      {true, _any} -> report()
      {false, []} -> report()
      {false, mapping} -> migrate(mapping, Keyword.get(opts, :commit, false))
    end
  end

  # ── Reporting ──────────────────────────────────────────────────────────────

  defp report do
    case orphans() do
      [] ->
        Mix.shell().info("Every vote already belongs to an account. Nothing to do.")

      orphans ->
        users = Accounts.list_users!()

        Mix.shell().info("#{length(orphans)} voter(s) with no account:\n")

        for {key, name, votes, weeks} <- orphans do
          Mix.shell().info([
            "  ",
            String.pad_trailing(key, 16),
            String.pad_trailing(name, 16),
            String.pad_trailing("#{votes} votes", 12),
            "#{length(weeks)} week(s): #{Enum.join(Enum.sort(weeks), ", ")}",
            suggestion(name, users)
          ])
        end

        Mix.shell().info("""

        Map each one onto a GitHub handle and run it again:

            mix beerocracy.migrate_voters #{example(orphans)}

        Add --commit once the plan reads right. Accounts so far: #{handles(users)}
        """)
    end
  end

  # A guess, never an action: the old key was a normalised name, so an account
  # whose display name or handle normalises the same way is probably them.
  defp suggestion(name, users) do
    normalised = Accounts.normalise_name(name)

    users
    |> Enum.find(fn user ->
      Accounts.normalise_name(user.display_name) == normalised or
        String.downcase(user.github_login) == normalised
    end)
    |> case do
      nil -> ""
      user -> "  → probably #{user.github_login}"
    end
  end

  defp example([{key, name, _, _} | _]), do: "#{key}=#{Accounts.normalise_name(name)}"

  defp handles([]), do: "none yet — nobody has signed in."
  defp handles(users), do: users |> Enum.map(& &1.github_login) |> Enum.join(", ")

  # ── Migrating ──────────────────────────────────────────────────────────────

  defp migrate(mapping, commit?) do
    resolved = Enum.map(mapping, fn {old, handle} -> {old, handle, find_user(handle)} end)

    case Enum.filter(resolved, &is_nil(elem(&1, 2))) do
      [] -> :ok
      missing -> Mix.raise(missing_message(missing))
    end

    unless commit?, do: Mix.shell().info("Dry run. Nothing will be written.\n")

    totals = Enum.map(resolved, fn {old, _, user} -> move(old, user, commit?) end)

    moved = totals |> Enum.map(& &1.moved) |> Enum.sum()
    dropped = totals |> Enum.map(& &1.dropped) |> Enum.sum()

    Mix.shell().info(
      if commit? do
        "\nDone. #{moved} vote(s) adopted, #{dropped} superseded and dropped."
      else
        "\n#{moved} vote(s) would be adopted, #{dropped} dropped. Re-run with --commit."
      end
    )
  end

  defp move(old_key, %User{} = user, commit?) do
    new_key = User.voter_key(user)

    days = Enum.filter(Voting.all_day_votes!(), &(&1.voter_key == old_key))
    places = Enum.filter(Voting.all_place_votes!(), &(&1.voter_key == old_key))

    taken_days = occupied(Voting.all_day_votes!(), new_key, &{&1.week_key, &1.weekday})
    taken_places = occupied(Voting.all_place_votes!(), new_key, &{&1.week_key, &1.place_slug})

    {day_clashes, day_moves} =
      Enum.split_with(days, &MapSet.member?(taken_days, {&1.week_key, &1.weekday}))

    {place_clashes, place_moves} =
      Enum.split_with(places, &MapSet.member?(taken_places, {&1.week_key, &1.place_slug}))

    Mix.shell().info([
      "  ",
      String.pad_trailing(old_key, 16),
      "→ ",
      String.pad_trailing("#{new_key} (#{user.display_name})", 28),
      "#{length(day_moves) + length(place_moves)} moved",
      clash_note(length(day_clashes) + length(place_clashes))
    ])

    if commit? do
      attrs = %{voter_key: new_key, voter_name: user.display_name}

      Enum.each(day_moves, &Voting.reassign_day_vote!(&1, attrs))
      Enum.each(place_moves, &Voting.reassign_place_vote!(&1, attrs))
      Enum.each(day_clashes, &Voting.retract_day_vote!/1)
      Enum.each(place_clashes, &Voting.retract_place_vote!/1)
    end

    %{
      moved: length(day_moves) + length(place_moves),
      dropped: length(day_clashes) + length(place_clashes)
    }
  end

  defp occupied(votes, key, identity) do
    votes
    |> Enum.filter(&(&1.voter_key == key))
    |> MapSet.new(identity)
  end

  defp clash_note(0), do: ""
  defp clash_note(count), do: ", #{count} already voted as themselves"

  defp find_user(handle) do
    wanted = String.downcase(handle)

    Enum.find(Accounts.list_users!(), &(String.downcase(&1.github_login) == wanted))
  end

  defp missing_message(missing) do
    handles = missing |> Enum.map(&elem(&1, 1)) |> Enum.join(", ")

    "no account for: #{handles}. They each need to sign in once before their votes can be moved."
  end

  # ── Input ──────────────────────────────────────────────────────────────────

  defp parse_pairs(pairs) do
    Enum.map(pairs, fn pair ->
      case String.split(pair, "=", parts: 2) do
        [old, handle] when old != "" and handle != "" -> {old, handle}
        _ -> Mix.raise(~s(expected old_key=github_handle, got "#{pair}"))
      end
    end)
  end

  defp orphans do
    (Voting.all_day_votes!() ++ Voting.all_place_votes!())
    |> Enum.reject(&String.starts_with?(&1.voter_key, "gh:"))
    |> Enum.group_by(& &1.voter_key)
    |> Enum.map(fn {key, votes} ->
      {key, hd(votes).voter_name, length(votes), votes |> Enum.map(& &1.week_key) |> Enum.uniq()}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end
end
