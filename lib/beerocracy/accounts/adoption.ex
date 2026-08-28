defmodule Beerocracy.Accounts.Adoption do
  @moduledoc """
  Adopting votes cast before there were accounts to file them under.

  A voter used to be whatever name they typed, normalised — `jonas`. Now they
  are their GitHub account — `gh:1234`. Votes cast under the old scheme belong
  to nobody, which matters for any week still open: their owner votes again as
  themselves and the sheet counts them twice.

  Deliberately free of Mix. The production container ships a release, which has
  no Mix in it and is exactly where this needs to run — so everything here
  returns strings and tagged tuples, and the callers decide how to print and how
  to fail. `Mix.Tasks.Beerocracy.MigrateVoters` and `Beerocracy.Release` are
  both thin wrappers around it.
  """

  alias Beerocracy.Accounts
  alias Beerocracy.Accounts.GitHubDirectory
  alias Beerocracy.Accounts.User
  alias Beerocracy.Repo
  alias Beerocracy.Voting

  @type orphan :: %{key: String.t(), name: String.t(), votes: pos_integer(), weeks: [String.t()]}

  @doc "Voters whose votes are not filed under any account."
  @spec orphans() :: [orphan()]
  def orphans do
    (Voting.all_day_votes!() ++ Voting.all_place_votes!())
    |> Enum.reject(&String.starts_with?(&1.voter_key, "gh:"))
    |> Enum.group_by(& &1.voter_key)
    |> Enum.map(fn {key, votes} ->
      %{
        key: key,
        name: hd(votes).voter_name,
        votes: length(votes),
        weeks: votes |> Enum.map(& &1.week_key) |> Enum.uniq() |> Enum.sort()
      }
    end)
    |> Enum.sort_by(& &1.key)
  end

  @doc "The report `--list` prints: who is unmigrated, and a guess for each."
  @spec listing() :: String.t()
  def listing do
    case orphans() do
      [] ->
        "Every vote already belongs to an account. Nothing to do."

      orphans ->
        users = Accounts.list_users!()

        rows =
          Enum.map_join(orphans, "\n", fn orphan ->
            IO.iodata_to_binary([
              "  ",
              String.pad_trailing(orphan.key, 16),
              String.pad_trailing(orphan.name, 16),
              String.pad_trailing("#{orphan.votes} votes", 12),
              "#{length(orphan.weeks)} week(s): #{Enum.join(orphan.weeks, ", ")}",
              suggestion(orphan.name, users)
            ])
          end)

        """
        #{length(orphans)} voter(s) with no account:

        #{rows}

        Map each one onto a GitHub handle, then re-run with --commit.
        Nobody needs to have signed in first — handles are looked up on GitHub.
        Accounts so far: #{handles(users)}\
        """
    end
  end

  @doc """
  Moves votes from old keys onto the accounts that own them.

  `mapping` is a list of `"old_key=github_handle"` strings. Nothing is written
  unless `:commit` is true, so the returned report doubles as the plan.
  """
  @spec migrate([String.t()], keyword()) ::
          {:ok, %{report: String.t(), moved: non_neg_integer(), dropped: non_neg_integer()}}
          | {:error, String.t()}
  def migrate(mapping, opts \\ []) do
    commit? = Keyword.get(opts, :commit, false)
    offline? = Keyword.get(opts, :offline, false)

    with {:ok, pairs} <- parse(mapping),
         resolved = Enum.map(pairs, fn {old, h} -> {old, h, resolve(h, offline?)} end),
         :ok <- check(resolved, offline?) do
      moves = apply_moves(resolved, commit?)

      moved = moves |> Enum.map(& &1.moved) |> Enum.sum()
      dropped = moves |> Enum.map(& &1.dropped) |> Enum.sum()

      {:ok, %{report: report(moves, moved, dropped, commit?), moved: moved, dropped: dropped}}
    end
  end

  # Every handle is resolved before anything is written, and the writes go in
  # one transaction — a migration that rewrote half the office and then fell
  # over would leave a mess nobody could reconstruct by hand.
  defp apply_moves(resolved, false = _commit?) do
    Enum.map(resolved, fn {old, _h, {:ok, target}} -> move(old, target, false) end)
  end

  defp apply_moves(resolved, true = _commit?) do
    {:ok, moves} =
      Repo.transaction(fn ->
        Enum.map(resolved, fn {old, _h, {:ok, target}} -> move(old, target, true) end)
      end)

    moves
  end

  # ── Resolving a handle ─────────────────────────────────────────────────────

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
      # No display name to impose yet — they pick one when they sign in — so the
      # name already on the votes is left exactly as it is.
      {:ok, account} -> {:ok, %{key: "gh:" <> account.id, name: nil, via: describe(account)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_user(handle) do
    wanted = String.downcase(handle)

    Enum.find(Accounts.list_users!(), &(String.downcase(&1.github_login) == wanted))
  end

  defp describe(%{login: login, name: nil}), do: "GitHub: @#{login}"
  defp describe(%{login: login, name: name}), do: "GitHub: #{name} (@#{login})"

  defp check(resolved, offline?) do
    case Enum.filter(resolved, &match?({:error, _}, elem(&1, 2))) do
      [] -> :ok
      failed -> {:error, unresolved_message(failed, offline?)}
    end
  end

  # ── Moving the votes ───────────────────────────────────────────────────────

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

    if commit? do
      Enum.each(day_moves, &Voting.reassign_day_vote!(&1, attrs(&1, target)))
      Enum.each(place_moves, &Voting.reassign_place_vote!(&1, attrs(&1, target)))
      Enum.each(day_clashes, &Voting.retract_day_vote!/1)
      Enum.each(place_clashes, &Voting.retract_place_vote!/1)
    end

    %{
      old: old_key,
      new: new_key,
      via: target.via,
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

  # ── Words ──────────────────────────────────────────────────────────────────

  defp report(moves, moved, dropped, commit?) do
    rows =
      Enum.map_join(moves, "\n", fn move ->
        IO.iodata_to_binary([
          "  ",
          String.pad_trailing(move.old, 16),
          "→ ",
          String.pad_trailing(move.new, 16),
          String.pad_trailing("#{move.moved} moved", 10),
          String.pad_trailing(clash_note(move.dropped), 34),
          move.via
        ])
      end)

    header = if commit?, do: "", else: "Dry run. Nothing will be written.\n\n"

    footer =
      if commit? do
        "\n\nDone. #{moved} vote(s) adopted, #{dropped} superseded and dropped."
      else
        "\n\n#{moved} vote(s) would be adopted, #{dropped} dropped. Re-run with --commit."
      end

    "#{header}#{rows}#{footer}"
  end

  defp clash_note(0), do: ""
  defp clash_note(count), do: "#{count} already voted as themselves"

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

  defp handles([]), do: "none yet — nobody has signed in."
  defp handles(users), do: users |> Enum.map(& &1.github_login) |> Enum.join(", ")

  defp unresolved_message(failed, offline?) do
    lines =
      Enum.map_join(failed, "", fn {_old, handle, {:error, reason}} ->
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

  defp parse(mapping) do
    Enum.reduce_while(mapping, {:ok, []}, fn pair, {:ok, acc} ->
      case String.split(pair, "=", parts: 2) do
        [old, handle] when old != "" and handle != "" -> {:cont, {:ok, acc ++ [{old, handle}]}}
        _ -> {:halt, {:error, ~s(expected old_key=github_handle, got "#{pair}")}}
      end
    end)
  end
end
