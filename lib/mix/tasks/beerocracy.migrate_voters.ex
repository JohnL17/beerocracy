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

  Nobody has to have signed in first. A handle already on the sheet is resolved
  locally; anybody else is looked up against GitHub's public user endpoint,
  because an account id is public and permanent. Their votes are waiting for
  them the first time they arrive. Pass `--offline` to refuse the lookup and
  work only with people who already have accounts here.

  The dry run prints the account each handle resolved to, so a mistyped handle
  shows up as somebody else's name rather than as somebody else's votes.

  Where a person voted under both schemes in the same week, the vote they cast
  as themselves is the one that survives; the orphan is dropped rather than
  merged, because two answers to the same question are not additive.
  """

  use Mix.Task

  alias Beerocracy.Accounts
  alias Beerocracy.Accounts.GitHubDirectory
  alias Beerocracy.Accounts.User
  alias Beerocracy.Voting

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    # Every line of this task is a query, and in dev the repo logs each one at
    # debug — which buries the report it exists to print.
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
    case {Keyword.get(opts, :list, false), parse_pairs(pairs)} do
      {true, _any} -> report()
      {false, []} -> report()
      {false, mapping} -> migrate(mapping, opts)
    end
  end

  defp unknown(invalid), do: invalid |> Enum.map_join(", ", &elem(&1, 0))

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

        Nobody needs to have signed in first — handles are looked up on GitHub.
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

  defp migrate(mapping, opts) do
    commit? = Keyword.get(opts, :commit, false)
    offline? = Keyword.get(opts, :offline, false)

    resolved = Enum.map(mapping, fn {old, handle} -> {old, handle, resolve(handle, offline?)} end)

    case Enum.filter(resolved, &match?({:error, _}, elem(&1, 2))) do
      [] -> :ok
      failed -> Mix.raise(unresolved_message(failed, offline?))
    end

    unless commit?, do: Mix.shell().info("Dry run. Nothing will be written.\n")

    totals =
      Enum.map(resolved, fn {old, _handle, {:ok, target}} -> move(old, target, commit?) end)

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

  # Somebody already on the sheet is known locally and needs no lookup. Anybody
  # else is a public GitHub account we can file votes under before they arrive.
  defp resolve(handle, offline?) do
    case find_user(handle) do
      %User{} = user ->
        {:ok, %{key: User.voter_key(user), name: user.display_name, via: "signed in"}}

      nil when offline? ->
        {:error, :not_here}

      nil ->
        lookup(handle)
    end
  end

  defp lookup(handle) do
    case GitHubDirectory.fetch(handle) do
      {:ok, account} ->
        # No display name to impose yet — they pick one when they sign in — so
        # the name already on the votes is left exactly as it is.
        {:ok, %{key: "gh:" <> account.id, name: nil, via: describe(account)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp describe(%{login: login, name: nil}), do: "GitHub: @#{login}"
  defp describe(%{login: login, name: name}), do: "GitHub: #{name} (@#{login})"

  defp move(old_key, target, commit?) do
    new_key = target.key

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
      String.pad_trailing(new_key, 16),
      String.pad_trailing("#{length(day_moves) + length(place_moves)} moved", 10),
      String.pad_trailing(clash_note(length(day_clashes) + length(place_clashes)), 34),
      target.via
    ])

    if commit? do
      Enum.each(day_moves, &Voting.reassign_day_vote!(&1, attrs(&1, target)))
      Enum.each(place_moves, &Voting.reassign_place_vote!(&1, attrs(&1, target)))
      Enum.each(day_clashes, &Voting.retract_day_vote!/1)
      Enum.each(place_clashes, &Voting.retract_place_vote!/1)
    end

    %{
      moved: length(day_moves) + length(place_moves),
      dropped: length(day_clashes) + length(place_clashes)
    }
  end

  # The name they go by here wins when they have one; otherwise the vote keeps
  # the name it was cast under, which is what they called themselves at the time.
  defp attrs(vote, %{key: key, name: nil}), do: %{voter_key: key, voter_name: vote.voter_name}
  defp attrs(_vote, %{key: key, name: name}), do: %{voter_key: key, voter_name: name}

  defp occupied(votes, key, identity) do
    votes
    |> Enum.filter(&(&1.voter_key == key))
    |> MapSet.new(identity)
  end

  defp clash_note(0), do: ""
  defp clash_note(count), do: "#{count} already voted as themselves"

  defp find_user(handle) do
    wanted = String.downcase(handle)

    Enum.find(Accounts.list_users!(), &(String.downcase(&1.github_login) == wanted))
  end

  defp unresolved_message(failed, offline?) do
    lines =
      Enum.map(failed, fn {_old, handle, {:error, reason}} ->
        "\n  #{handle} — #{explain(reason)}"
      end)

    hint =
      if offline?,
        do: "\n\nDrop --offline to look the rest up on GitHub.",
        else: "\n\nCheck the spelling; the handle is the @name, not the name on the sheet."

    "could not resolve:#{lines}#{hint}"
  end

  defp explain(:no_such_account), do: "no such GitHub account"
  defp explain(:not_here), do: "has not signed in, and --offline forbids looking them up"
  defp explain({:status, status}), do: "GitHub answered #{status}"
  defp explain(reason), do: inspect(reason)

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
