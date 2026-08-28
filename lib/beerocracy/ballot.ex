defmodule Beerocracy.Ballot do
  @moduledoc """
  The reading room of the Beerocracy.

  `Beerocracy.Voting` stores individual votes; this module turns them into the
  thing everybody actually wants to look at — a tally for the current week —
  and broadcasts when it changes so every open browser updates at once.

  Voters are identified by an opaque `voter_key` that comes from
  `Beerocracy.Accounts` and means nothing here. The display name travels
  alongside it purely so the tally can be read back from the votes alone.
  """

  alias Beerocracy.Places
  alias Beerocracy.Places.Place
  alias Beerocracy.Voting
  alias Beerocracy.Week

  @pubsub Beerocracy.PubSub

  defmodule DayResult do
    @moduledoc """
    One weekday and everyone it works for.

    A maybe counts towards `count` exactly like a yes — it is still a body in the
    pub — but it is tracked separately so a day carried entirely by maybes is
    visibly shakier than one everybody committed to.
    """
    defstruct [:weekday, :date, :count, :yes_count, :maybe_count, :voters, :certain, :tentative]

    @type t :: %__MODULE__{
            weekday: atom(),
            date: Date.t(),
            count: non_neg_integer(),
            yes_count: non_neg_integer(),
            maybe_count: non_neg_integer(),
            voters: [String.t()],
            certain: [String.t()],
            tentative: [String.t()]
          }
  end

  defmodule PlaceResult do
    @moduledoc """
    One place and how the swipes landed.

    A left swipe is worth nothing at all, not minus one: it says "not this one",
    which is a place to skip rather than a vote to hold against it. Rejections
    are still counted and shown — five people swiping past is worth knowing —
    they simply carry no weight in the ranking.

    Only swipes from people who have said which days work for them are counted.
    Somebody who has not committed to a day is not coming yet, so they do not
    get to choose where — but their swipes are kept and shown as waiting, both
    so the sheet can nudge them and so nobody thinks their input was binned.
    """
    defstruct [
      :place,
      :likes,
      :dislikes,
      :fans,
      :critics,
      :waiting_likes,
      :waiting_dislikes,
      :waiting
    ]

    @type t :: %__MODULE__{
            place: Place.t(),
            likes: non_neg_integer(),
            dislikes: non_neg_integer(),
            fans: [String.t()],
            critics: [String.t()],
            waiting_likes: non_neg_integer(),
            waiting_dislikes: non_neg_integer(),
            waiting: [String.t()]
          }
  end

  defmodule Tally do
    @moduledoc "Everything the results screen needs for one week."
    defstruct [:week, :days, :places, :voters, :waiting, :day_votes_cast, :place_votes_cast]

    @type t :: %__MODULE__{
            week: Week.t(),
            days: [DayResult.t()],
            places: [PlaceResult.t()],
            voters: [String.t()],
            waiting: [String.t()],
            day_votes_cast: non_neg_integer(),
            place_votes_cast: non_neg_integer()
          }
  end

  @doc "PubSub topic carrying `:ballot_updated` for one week."
  @spec topic(Week.t() | String.t()) :: String.t()
  def topic(%Week{key: key}), do: topic(key)
  def topic(week_key) when is_binary(week_key), do: "ballot:#{week_key}"

  @doc "Listen for changes to a week's tally."
  @spec subscribe(Week.t() | String.t()) :: :ok | {:error, term()}
  def subscribe(week), do: Phoenix.PubSub.subscribe(@pubsub, topic(week))

  @doc """
  The full tally for a week: weekdays in MO-FR order, places ranked best first.
  """
  @spec tally(Week.t()) :: Tally.t()
  def tally(%Week{} = week) do
    day_votes = Voting.day_votes_for_week!(week.key)
    place_votes = Voting.place_votes_for_week!(week.key)

    days = day_results(week, day_votes)

    # Where is decided by the people who will actually be there. Until a day
    # leads that means anyone who has committed to any day at all; once one
    # does, it narrows to the people free on it.
    eligible = eligible_voters(day_votes, leading_weekday(days))

    %Tally{
      week: week,
      days: days,
      places: place_results(week, place_votes, eligible),
      voters: distinct_voters(day_votes ++ place_votes),
      waiting: waiting_voters(place_votes, eligible),
      day_votes_cast: length(day_votes),
      place_votes_cast: length(place_votes)
    }
  end

  @doc """
  What one voter has already decided this week: their stance per weekday and
  their verdict per place slug.
  """
  @spec voter_state(Week.t(), String.t()) :: %{days: map(), places: map()}
  def voter_state(%Week{} = week, voter_key) do
    days =
      week.key
      |> Voting.day_votes_for_week!()
      |> Enum.filter(&(&1.voter_key == voter_key))
      |> Map.new(&{&1.weekday, &1.stance})

    places =
      week.key
      |> Voting.place_votes_for_week!()
      |> Enum.filter(&(&1.voter_key == voter_key))
      |> Map.new(&{&1.place_slug, &1.liked})

    %{days: days, places: places}
  end

  @doc """
  The stances a weekday tile cycles through, in order.

  Tapping a day walks it round the loop: nothing, yes, maybe, and back to
  nothing. `nil` is "not this day" — no row at all.
  """
  @spec stances() :: [atom() | nil]
  def stances, do: [nil, :yes, :maybe]

  @doc "The stance that follows `stance` in the cycle."
  @spec next_stance(atom() | nil) :: atom() | nil
  def next_stance(stance) do
    case Enum.find_index(stances(), &(&1 == stance)) do
      nil -> :yes
      index -> Enum.at(stances(), rem(index + 1, length(stances())))
    end
  end

  @doc """
  Advances a voter's stance on a weekday one step round the cycle, returning
  their new stance for every day.
  """
  @spec cycle_day(Week.t(), String.t(), String.t(), atom()) :: map()
  def cycle_day(%Week{} = week, voter_name, voter_key, weekday) do
    current = Map.get(voter_state(week, voter_key).days, weekday)
    set_day(week, voter_name, voter_key, weekday, next_stance(current))
  end

  @doc """
  Sets a voter's stance on a weekday outright. `nil` withdraws them from the day.
  """
  @spec set_day(Week.t(), String.t(), String.t(), atom(), atom() | nil) :: map()
  def set_day(%Week{} = week, voter_name, voter_key, weekday, stance) do
    existing =
      week.key
      |> Voting.day_votes_for_week!()
      |> Enum.find(&(&1.voter_key == voter_key and &1.weekday == weekday))

    case {existing, stance} do
      {nil, nil} ->
        :ok

      {vote, nil} ->
        Voting.retract_day_vote!(vote)

      {_, stance} ->
        Voting.cast_day_vote!(%{
          week_key: week.key,
          voter_key: voter_key,
          voter_name: voter_name,
          weekday: weekday,
          stance: stance
        })
    end

    broadcast(week)
    voter_state(week, voter_key).days
  end

  @doc "Records a swipe. `liked?` is true for right, false for left."
  @spec swipe(Week.t(), String.t(), String.t(), String.t(), boolean()) :: :ok
  def swipe(%Week{} = week, voter_name, voter_key, place_slug, liked?) do
    Voting.cast_place_vote!(%{
      week_key: week.key,
      voter_key: voter_key,
      voter_name: voter_name,
      place_slug: place_slug,
      liked: liked?
    })

    broadcast(week)
  end

  @doc """
  Rewrites a voter's name on every mark they have ever made.

  The name is copied onto each vote as it is cast, which is what lets the tally
  be read back from the votes alone. The cost of that is this function: when
  somebody renames themselves, the copies have to be brought along, or the sheet
  goes on calling them by a name they have just abandoned.

  Nothing is keyed on the name, so this is only ever cosmetic — no vote moves,
  and nothing can collide.
  """
  @spec rename_voter(Week.t(), String.t(), String.t()) :: :ok
  def rename_voter(%Week{} = week, voter_key, voter_name) do
    Voting.all_day_votes!()
    |> Enum.filter(&(&1.voter_key == voter_key))
    |> Enum.each(&Voting.rename_day_voter!(&1, voter_name))

    Voting.all_place_votes!()
    |> Enum.filter(&(&1.voter_key == voter_key))
    |> Enum.each(&Voting.rename_place_voter!(&1, voter_name))

    broadcast(week)
  end

  @doc """
  Rubs out everything one voter did this week — days and swipes both.

  Only their own marks go; the rest of the sheet is untouched. Returns how many
  of each were cleared so the interface can say what it just did.
  """
  @spec reset_voter(Week.t(), String.t()) :: %{days: non_neg_integer(), places: non_neg_integer()}
  def reset_voter(%Week{} = week, voter_key) do
    days =
      week.key
      |> Voting.day_votes_for_week!()
      |> Enum.filter(&(&1.voter_key == voter_key))

    places =
      week.key
      |> Voting.place_votes_for_week!()
      |> Enum.filter(&(&1.voter_key == voter_key))

    Enum.each(days, &Voting.retract_day_vote!/1)
    Enum.each(places, &Voting.retract_place_vote!/1)

    if days != [] or places != [], do: broadcast(week)

    %{days: length(days), places: length(places)}
  end

  @doc """
  Takes back a voter's most recent swipe, so a fumbled thumb is not a verdict.

  Returns the slug that went back on the deck, or `:error` if they had not
  swiped anything yet.
  """
  @spec undo_last_swipe(Week.t(), String.t()) :: {:ok, String.t()} | :error
  def undo_last_swipe(%Week{} = week, voter_key) do
    week.key
    |> Voting.place_votes_for_week!()
    |> Enum.filter(&(&1.voter_key == voter_key))
    |> Enum.max_by(& &1.updated_at, DateTime, fn -> nil end)
    |> case do
      nil ->
        :error

      vote ->
        Voting.retract_place_vote!(vote)
        broadcast(week)
        {:ok, vote.place_slug}
    end
  end

  @doc """
  Places this voter has not swiped yet, dealt in a shuffled order.

  Catalogue order is a thumb on the scale: whatever sits at the top of the file
  gets judged while everyone is still interested, and the last few get rushed.
  So each voter gets their own order, derived from `seed` — the same every time
  they open the sheet, different from everybody else's, and reshuffled next
  week. Stable matters as much as random here: a deck that reorders itself
  between swipes would be unusable.
  """
  @spec pending_places(Week.t(), map(), term()) :: [Place.t()]
  def pending_places(%Week{} = week, decided, seed \\ nil) do
    week
    |> Places.available()
    |> Enum.reject(&Map.has_key?(decided, &1.slug))
    |> Enum.sort_by(&:erlang.phash2({seed, &1.slug}))
  end

  @doc """
  The place table with a position against each row, football-table style.

  Places tied on the same record share a position, and only the first of them
  prints a number — repeating "3" down three rows reads as three separate third
  places. The next distinct record resumes at the position it has actually
  earned, so a three-way tie for first is followed by fourth, not second.

  Returns `[{position | nil, result}]` in table order.
  """
  @spec ranked([PlaceResult.t()]) :: [{pos_integer() | nil, PlaceResult.t()}]
  def ranked(places) do
    places
    |> Enum.chunk_by(& &1.likes)
    |> Enum.flat_map_reduce(1, fn drawn, position ->
      rows = Enum.with_index(drawn, fn result, index -> {index == 0 && position, result} end)
      {rows, position + length(drawn)}
    end)
    |> elem(0)
    |> Enum.map(fn {position, result} -> {position || nil, result} end)
  end

  @doc """
  The winning weekday, or `nil` while nobody has voted.

  Decided in three steps, each only reached when the one before it draws:

    1. the most people, counting a maybe the same as a yes — a body is a body;
    2. the fewest maybes, so the firmer commitment wins a level total;
    3. the day nearest the weekend, because Friday beats Monday and an argument
       about which is exactly the thing that stops a beer from happening.

  The third step always separates them, so a day is never left undecided.
  """
  @spec winning_day(Tally.t()) :: DayResult.t() | nil
  def winning_day(%Tally{days: days}) do
    days
    |> Enum.filter(&(&1.count > 0))
    |> Enum.sort_by(&{-&1.count, &1.maybe_count, -weekday_index(&1.weekday)})
    |> List.first()
  end

  defp weekday_index(weekday), do: Enum.find_index(Week.weekdays(), &(&1 == weekday))

  @doc "The winning place, or `nil` while nobody has swiped right."
  @spec winning_place(Tally.t()) :: PlaceResult.t() | nil
  def winning_place(%Tally{places: places}) do
    Enum.find(places, &(&1.likes > 0))
  end

  @doc """
  The decision as it stands: a day, and a place that is actually open on it.

  The point of pairing them here rather than picking the two winners separately
  is that the separate answer can be nonsense — a brewery window that opens on
  Thursdays does not become available because Tuesday won the vote. When the
  most-liked place cannot host the winning day, it is reported as `blocked` so
  the sheet can say so out loud instead of quietly promoting the runner-up.
  """
  @spec outcome(Tally.t()) ::
          %{day: DayResult.t(), place: PlaceResult.t() | nil, blocked: PlaceResult.t() | nil}
          | nil
  def outcome(%Tally{} = tally) do
    case winning_day(tally) do
      nil ->
        nil

      day ->
        approved = Enum.filter(tally.places, &(&1.likes > 0))
        open = Enum.filter(approved, &Place.available_on?(&1.place, day.date))

        # Every place tied at the top, not just whichever sorted first — the
        # names are only a display order, not a reason to prefer one pub.
        places =
          case open do
            [] -> []
            [best | _] -> Enum.filter(open, &drawn_with?(&1, best))
          end

        first_choice = List.first(approved)

        # Reported even when nothing at all is open, so the sheet can name the
        # place people actually wanted instead of shrugging.
        blocked = if first_choice && first_choice not in places, do: first_choice

        %{day: day, places: places, blocked: blocked}
    end
  end

  defp drawn_with?(a, b), do: a.likes == b.likes

  @doc "Whether the outcome has settled on anywhere at all."
  @spec decided?(map() | nil) :: boolean()
  def decided?(nil), do: false
  def decided?(%{places: places}), do: places != []

  @doc """
  Whether an outdoor place is being proposed for a day that looks wet.

  Returns the forecast responsible, or `nil` when there is nothing to warn
  about. Deliberately a warning and not a demotion — people are allowed to sit
  in the rain, they just should not be surprised by it.
  """
  @spec soaking_risk(map() | nil, %{Date.t() => struct()}) :: struct() | nil
  def soaking_risk(nil, _forecasts), do: nil
  def soaking_risk(%{places: []}, _forecasts), do: nil

  def soaking_risk(%{day: day, places: places}, forecasts) do
    with true <- Enum.any?(places, & &1.place.outdoor?),
         %{} = forecast <- Map.get(forecasts, day.date),
         true <- Beerocracy.Weather.Forecast.wet?(forecast) do
      forecast
    else
      _dry_or_indoors -> nil
    end
  end

  defmodule Visit do
    @moduledoc "Where a past week ended up."
    defstruct [:week, :weekday, :date, :place, :likes]

    @type t :: %__MODULE__{
            week: Week.t(),
            weekday: atom(),
            date: Date.t(),
            place: Place.t(),
            likes: non_neg_integer()
          }
  end

  @doc """
  Where past weeks ended up, most recent first.

  Reads the archive that has been accumulating since week one — nothing extra is
  stored for this. Weeks that never reached a decision are skipped, as are
  winners whose slug has since left the catalogue.
  """
  @spec history(Week.t(), pos_integer()) :: [Visit.t()]
  def history(%Week{} = before, limit \\ 8) do
    Voting.all_place_votes!()
    |> Enum.group_by(& &1.week_key)
    |> Map.delete(before.key)
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.flat_map(&visit(&1, before))
    |> Enum.take(limit)
  end

  @doc """
  How many weeks ago each place last won, keyed by slug.

  What this really answers is "not there again, surely" — four Thursdays running
  at the same pub is a failure mode worth making visible while people swipe.
  """
  @spec last_visits(Week.t(), pos_integer()) :: %{String.t() => non_neg_integer()}
  def last_visits(%Week{} = week, limit \\ 12) do
    week
    |> history(limit)
    |> Enum.reduce(%{}, fn visit, seen ->
      Map.put_new(seen, visit.place.slug, weeks_between(visit.week, week))
    end)
  end

  defp weeks_between(%Week{monday: earlier}, %Week{monday: later}) do
    later |> Date.diff(earlier) |> div(7)
  end

  defp visit({week_key, votes}, before) do
    with {:ok, week} <- week_from_key(week_key, before),
         tally = tally_from(week, votes),
         %{day: day, places: [%PlaceResult{} = result | _]} <- outcome(tally) do
      [
        %Visit{
          week: week,
          weekday: day.weekday,
          date: day.date,
          place: result.place,
          likes: result.likes
        }
      ]
    else
      _no_decision -> []
    end
  end

  # The week key is all that is stored, so walk back from the current week to
  # find the Monday it belongs to rather than trying to invert the ISO calendar.
  defp week_from_key(week_key, %Week{} = reference) do
    Enum.find_value(0..104, fn weeks_ago ->
      week = Week.from_date(Date.add(reference.monday, -7 * weeks_ago))
      if week.key == week_key, do: {:ok, week}
    end) || :error
  end

  defp tally_from(week, place_votes) do
    day_votes = Voting.day_votes_for_week!(week.key)
    committed = MapSet.new(day_votes, & &1.voter_key)

    %Tally{
      week: week,
      days: day_results(week, day_votes),
      places: place_results(week, place_votes, committed),
      voters: distinct_voters(day_votes ++ place_votes),
      waiting: waiting_voters(place_votes, committed),
      day_votes_cast: length(day_votes),
      place_votes_cast: length(place_votes)
    }
  end

  @doc "Weekdays of `week` that this place cannot host."
  @spec closed_days(Place.t(), Week.t()) :: [atom()]
  def closed_days(%Place{} = place, %Week{} = week) do
    Enum.reject(Week.weekdays(), fn weekday ->
      Place.available_on?(place, Week.date_of(week, weekday))
    end)
  end

  defp broadcast(%Week{} = week) do
    Phoenix.PubSub.broadcast(@pubsub, topic(week), {:ballot_updated, week.key})
  end

  defp day_results(week, day_votes) do
    by_day = Enum.group_by(day_votes, & &1.weekday)

    Enum.map(Week.weekdays(), fn weekday ->
      votes = Map.get(by_day, weekday, [])
      {certain, tentative} = Enum.split_with(votes, &(&1.stance == :yes))

      %DayResult{
        weekday: weekday,
        date: Week.date_of(week, weekday),
        count: length(votes),
        yes_count: length(certain),
        maybe_count: length(tentative),
        voters: votes |> Enum.map(& &1.voter_name) |> Enum.sort(),
        certain: certain |> Enum.map(& &1.voter_name) |> Enum.sort(),
        tentative: tentative |> Enum.map(& &1.voter_name) |> Enum.sort()
      }
    end)
  end

  defp place_results(week, place_votes, committed) do
    by_place = Enum.group_by(place_votes, & &1.place_slug)

    week
    |> Places.available()
    |> Enum.map(fn place ->
      {counted, waiting} =
        by_place
        |> Map.get(place.slug, [])
        |> Enum.split_with(&MapSet.member?(committed, &1.voter_key))

      {fans, critics} = Enum.split_with(counted, & &1.liked)
      {waiting_fans, waiting_critics} = Enum.split_with(waiting, & &1.liked)

      %PlaceResult{
        place: place,
        likes: length(fans),
        dislikes: length(critics),
        fans: names(fans),
        critics: names(critics),
        waiting_likes: length(waiting_fans),
        waiting_dislikes: length(waiting_critics),
        waiting: names(waiting)
      }
    end)
    # Most right-swipes wins, and nothing else counts. Name only settles the
    # display order of a genuine draw; it is not a reason to prefer a pub.
    |> Enum.sort_by(&{-&1.likes, &1.place.name})
  end

  # The weekday that leads, worked out from day results alone so that eligibility
  # can be settled before the places are counted.
  defp leading_weekday(days) do
    days
    |> Enum.filter(&(&1.count > 0))
    |> Enum.sort_by(&{-&1.count, &1.maybe_count, -weekday_index(&1.weekday)})
    |> List.first()
    |> case do
      nil -> nil
      day -> day.weekday
    end
  end

  defp eligible_voters(day_votes, nil), do: MapSet.new(day_votes, & &1.voter_key)

  defp eligible_voters(day_votes, weekday) do
    day_votes
    |> Enum.filter(&(&1.weekday == weekday))
    |> MapSet.new(& &1.voter_key)
  end

  @doc """
  Whether this voter's swipes count towards the week as it currently stands.

  False both for somebody who has picked no day at all and for somebody who is
  busy on the day that is winning — in either case they will not be there, so
  they do not get to pick the pub.
  """
  @spec counts?(Tally.t(), map()) :: boolean()
  def counts?(%Tally{} = tally, day_stances) do
    case winning_day(tally) do
      # Nothing leads yet, so any commitment at all earns a say.
      nil -> map_size(day_stances) > 0
      day -> Map.has_key?(day_stances, day.weekday)
    end
  end

  # Everyone who has swiped without earning a say, so the sheet can say so.
  defp waiting_voters(place_votes, committed) do
    place_votes
    |> Enum.reject(&MapSet.member?(committed, &1.voter_key))
    |> Enum.uniq_by(& &1.voter_key)
    |> Enum.map(& &1.voter_name)
    |> Enum.sort_by(&String.downcase/1)
  end

  defp names(votes), do: votes |> Enum.map(& &1.voter_name) |> Enum.sort()

  defp distinct_voters(votes) do
    votes
    |> Enum.uniq_by(& &1.voter_key)
    |> Enum.map(& &1.voter_name)
    |> Enum.sort_by(&String.downcase/1)
  end
end
