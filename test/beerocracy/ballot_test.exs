defmodule Beerocracy.BallotTest do
  # Not async: SQLite allows a single writer, and the sandbox holds a write
  # transaction open for the length of each test — concurrent DB tests deadlock
  # on the write lock rather than merely queueing. Measured, not assumed.
  use Beerocracy.DataCase, async: false

  alias Beerocracy.Ballot
  alias Beerocracy.Places
  alias Beerocracy.Week

  setup do
    %{week: Week.from_date(~D[2026-08-19]), next: Week.from_date(~D[2026-08-26])}
  end

  describe "voter_key/1" do
    test "treats a name as the same person regardless of case and padding" do
      assert Ballot.voter_key("  Jonas  ") == Ballot.voter_key("jonas")
      assert Ballot.voter_key("Ada  Lovelace") == Ballot.voter_key("ada lovelace")
    end

    test "keeps different people apart" do
      refute Ballot.voter_key("Jonas") == Ballot.voter_key("Jonah")
    end
  end

  describe "cycle_day/4" do
    test "walks a day from nothing, to yes, to maybe, and back", %{week: week} do
      assert Ballot.cycle_day(week, "Jonas", key("Jonas"), :wednesday) == %{wednesday: :yes}
      assert Ballot.cycle_day(week, "Jonas", key("Jonas"), :wednesday) == %{wednesday: :maybe}
      assert Ballot.cycle_day(week, "Jonas", key("Jonas"), :wednesday) == %{}

      assert Ballot.tally(week) |> day(:wednesday) |> Map.fetch!(:count) == 0
    end

    test "lets one voter mark several days independently", %{week: week} do
      Ballot.cycle_day(week, "Jonas", key("Jonas"), :tuesday)
      Ballot.cycle_day(week, "Jonas", key("Jonas"), :thursday)
      days = Ballot.cycle_day(week, "Jonas", key("Jonas"), :thursday)

      assert days == %{tuesday: :yes, thursday: :maybe}
    end

    test "counts each voter once per day", %{week: week} do
      Ballot.set_day(week, "Jonas", key("Jonas"), :monday, :yes)
      Ballot.set_day(week, "Mira", key("Mira"), :monday, :maybe)

      assert Ballot.tally(week) |> day(:monday) |> Map.fetch!(:voters) == ["Jonas", "Mira"]
    end
  end

  describe "a maybe" do
    test "counts towards the day just like a yes", %{week: week} do
      Ballot.set_day(week, "Jonas", key("Jonas"), :monday, :yes)
      Ballot.set_day(week, "Mira", key("Mira"), :monday, :maybe)

      result = Ballot.tally(week) |> day(:monday)

      assert result.count == 2
      assert result.yes_count == 1
      assert result.maybe_count == 1
    end

    test "is tracked apart from a yes, so a shaky day is visibly shaky", %{week: week} do
      Ballot.set_day(week, "Jonas", key("Jonas"), :friday, :maybe)
      Ballot.set_day(week, "Mira", key("Mira"), :friday, :maybe)

      result = Ballot.tally(week) |> day(:friday)

      assert result.certain == []
      assert result.tentative == ["Jonas", "Mira"]
    end

    test "beats a day with fewer people on it", %{week: week} do
      Ballot.set_day(week, "Jonas", key("Jonas"), :monday, :yes)
      Ballot.set_day(week, "Mira", key("Mira"), :tuesday, :maybe)
      Ballot.set_day(week, "Ada", key("Ada"), :tuesday, :maybe)

      assert Ballot.winning_day(Ballot.tally(week)).weekday == :tuesday
    end

    test "loses a draw to the day more people are certain about", %{week: week} do
      Ballot.set_day(week, "Jonas", key("Jonas"), :thursday, :yes)
      Ballot.set_day(week, "Mira", key("Mira"), :thursday, :yes)
      Ballot.set_day(week, "Ada", key("Ada"), :tuesday, :maybe)
      Ballot.set_day(week, "Kim", key("Kim"), :tuesday, :maybe)

      assert Ballot.winning_day(Ballot.tally(week)).weekday == :thursday
    end

    test "can be changed to a yes without adding a second vote", %{week: week} do
      Ballot.set_day(week, "Jonas", key("Jonas"), :monday, :maybe)
      Ballot.set_day(week, "Jonas", key("Jonas"), :monday, :yes)

      result = Ballot.tally(week) |> day(:monday)

      assert result.count == 1
      assert result.yes_count == 1
      assert result.maybe_count == 0
    end
  end

  describe "next_stance/1" do
    test "cycles nothing, yes, maybe" do
      assert Ballot.next_stance(nil) == :yes
      assert Ballot.next_stance(:yes) == :maybe
      assert Ballot.next_stance(:maybe) == nil
    end
  end

  describe "swipe/5" do
    setup %{week: week} do
      for name <- ~w(Jonas Mira), do: commits(week, name)
      :ok
    end

    test "records a verdict and lets the voter change their mind", %{week: week} do
      slug = first_slug()

      Ballot.swipe(week, "Jonas", key("Jonas"), slug, true)
      assert %{likes: 1, dislikes: 0} = result(week, slug)

      Ballot.swipe(week, "Jonas", key("Jonas"), slug, false)
      assert %{likes: 0, dislikes: 1} = result(week, slug)
    end

    test "ranks the most approved place first", %{week: week} do
      [a, b | _] = Enum.map(Places.all(), & &1.slug)

      Ballot.swipe(week, "Jonas", key("Jonas"), b, true)
      Ballot.swipe(week, "Mira", key("Mira"), b, true)
      Ballot.swipe(week, "Jonas", key("Jonas"), a, true)

      tally = Ballot.tally(week)

      assert hd(tally.places).place.slug == b
      assert Ballot.winning_place(tally).place.slug == b
    end

    test "a rejection subtracts nothing, so it cannot unseat an equally liked place",
         %{week: week} do
      [a, b | _] = Enum.map(Places.all(), & &1.slug)

      Ballot.swipe(week, "Jonas", key("Jonas"), a, true)
      Ballot.swipe(week, "Mira", key("Mira"), a, false)
      Ballot.swipe(week, "Jonas", key("Jonas"), b, true)

      # One like each: the rejection on `a` is recorded but weighs nothing.
      assert result(week, a).likes == 1
      assert result(week, a).dislikes == 1
      assert result(week, b).likes == 1

      assert %{places: places} = Ballot.outcome(Ballot.tally(week))
      assert length(places) == 2
    end

    test "a place everybody rejected still ranks on its likes alone", %{week: week} do
      [a, b | _] = Enum.map(Places.all(), & &1.slug)

      for name <- ~w(Jonas Mira), do: Ballot.swipe(week, name, key(name), a, true)
      Ballot.swipe(week, "Jonas", key("Jonas"), b, true)
      Ballot.swipe(week, "Mira", key("Mira"), b, false)

      assert Ballot.winning_place(Ballot.tally(week)).place.slug == a
    end
  end

  describe "undo_last_swipe/2" do
    test "puts the most recent swipe back on the deck", %{week: week} do
      [a, b | _] = Enum.map(Places.all(), & &1.slug)

      Ballot.swipe(week, "Jonas", key("Jonas"), a, true)
      Ballot.swipe(week, "Jonas", key("Jonas"), b, false)

      assert {:ok, ^b} = Ballot.undo_last_swipe(week, key("Jonas"))
      assert Ballot.voter_state(week, key("Jonas")).places == %{a => true}
    end

    test "does nothing when the voter has not swiped", %{week: week} do
      assert :error = Ballot.undo_last_swipe(week, key("Nobody"))
    end

    test "only takes back the voter's own swipe", %{week: week} do
      slug = first_slug()

      commits(week, "Mira")
      Ballot.swipe(week, "Mira", key("Mira"), slug, true)

      assert :error = Ballot.undo_last_swipe(week, key("Jonas"))
      assert %{likes: 1} = result(week, slug)
    end
  end

  describe "weekly reset" do
    test "votes are scoped to their week", %{week: week, next: next} do
      Ballot.set_day(week, "Jonas", key("Jonas"), :wednesday, :yes)
      Ballot.swipe(week, "Jonas", key("Jonas"), first_slug(), true)

      this_week = Ballot.tally(week)
      new_week = Ballot.tally(next)

      assert this_week.day_votes_cast == 1
      assert this_week.place_votes_cast == 1

      assert new_week.day_votes_cast == 0
      assert new_week.place_votes_cast == 0
      assert new_week.voters == []
      assert Ballot.winning_day(new_week) == nil
      assert Ballot.winning_place(new_week) == nil
    end

    test "a new week hands every place back to the deck", %{week: week, next: next} do
      for place <- Places.all() do
        Ballot.swipe(week, "Jonas", key("Jonas"), place.slug, true)
      end

      assert Ballot.voter_state(week, key("Jonas")).places |> map_size() == length(Places.all())

      state = Ballot.voter_state(next, key("Jonas"))
      assert state.places == %{}
      assert state.days == %{}

      assert next |> Ballot.pending_places(state.places) |> Enum.map(& &1.slug) |> Enum.sort() ==
               next |> Places.available() |> Enum.map(& &1.slug) |> Enum.sort()
    end
  end

  describe "pending_places/3" do
    setup %{week: week}, do: %{open: Places.available(week)}

    test "deals every available place that has not been judged", %{week: week, open: open} do
      assert week |> Ballot.pending_places(%{}, "seed") |> length() == length(open)

      [gone | _] = Enum.map(open, & &1.slug)
      remaining = week |> Ballot.pending_places(%{gone => true}, "seed") |> Enum.map(& &1.slug)

      assert length(remaining) == length(open) - 1
      refute gone in remaining
    end

    test "gives the same voter the same order every time", %{week: week} do
      seed = {"2026-W34", "jonas"}

      assert Ballot.pending_places(week, %{}, seed) == Ballot.pending_places(week, %{}, seed)
    end

    test "gives different voters different orders", %{week: week} do
      orders =
        for name <- ~w(jonas mira ada kim sam) do
          week |> Ballot.pending_places(%{}, {"2026-W34", name}) |> Enum.map(& &1.slug)
        end

      assert length(Enum.uniq(orders)) > 1, "every voter got the same running order"
    end

    test "reshuffles when the week rolls over", %{week: week} do
      jonas = fn key ->
        week |> Ballot.pending_places(%{}, {key, "jonas"}) |> Enum.map(& &1.slug)
      end

      weeks = Enum.map(~w(2026-W34 2026-W35 2026-W36 2026-W37), jonas)

      assert length(Enum.uniq(weeks)) > 1, "the order never changed from week to week"
    end

    test "holds its order steady as places are judged", %{week: week} do
      seed = {"2026-W34", "jonas"}
      dealt = week |> Ballot.pending_places(%{}, seed) |> Enum.map(& &1.slug)
      [first, second | _] = dealt

      remaining =
        week
        |> Ballot.pending_places(%{first => true, second => false}, seed)
        |> Enum.map(& &1.slug)

      # Judging a card must not reorder the ones behind it.
      assert remaining == dealt -- [first, second]
    end
  end

  describe "winning_day/1" do
    test "is nil while nobody has voted", %{week: week} do
      assert Ballot.winning_day(Ballot.tally(week)) == nil
    end

    test "picks the day with the most approvals", %{week: week} do
      Ballot.set_day(week, "Jonas", key("Jonas"), :thursday, :yes)
      Ballot.set_day(week, "Mira", key("Mira"), :thursday, :yes)
      Ballot.set_day(week, "Jonas", key("Jonas"), :monday, :yes)

      assert Ballot.winning_day(Ballot.tally(week)).weekday == :thursday
    end

    test "breaks a level tie towards the weekend", %{week: week} do
      Ballot.set_day(week, "Jonas", key("Jonas"), :tuesday, :yes)
      Ballot.set_day(week, "Mira", key("Mira"), :friday, :yes)

      assert Ballot.winning_day(Ballot.tally(week)).weekday == :friday
    end

    test "prefers the day with fewer maybes before reaching for the weekend", %{week: week} do
      # Friday is later but softer; Tuesday's firm yes should take it.
      Ballot.set_day(week, "Jonas", key("Jonas"), :tuesday, :yes)
      Ballot.set_day(week, "Mira", key("Mira"), :friday, :maybe)

      assert Ballot.winning_day(Ballot.tally(week)).weekday == :tuesday
    end

    test "a bigger turnout beats both of those", %{week: week} do
      Ballot.set_day(week, "Jonas", key("Jonas"), :friday, :yes)

      for name <- ~w(Mira Ada), do: Ballot.set_day(week, name, key(name), :monday, :maybe)

      assert Ballot.winning_day(Ballot.tally(week)).weekday == :monday
    end
  end

  test "broadcasts to everyone watching the week", %{week: week} do
    Ballot.subscribe(week)

    Ballot.set_day(week, "Jonas", key("Jonas"), :monday, :yes)
    assert_receive {:ballot_updated, "2026-W34"}

    Ballot.swipe(week, "Jonas", key("Jonas"), first_slug(), true)
    assert_receive {:ballot_updated, "2026-W34"}
  end

  describe "outcome/1" do
    test "pairs the winning day with a place that is open on it", %{week: week} do
      # Bierfenster opens Thursdays and Fridays only.
      Ballot.set_day(week, "Jonas", key("Jonas"), :tuesday, :yes)
      Ballot.swipe(week, "Jonas", key("Jonas"), "bierfenster", true)
      Ballot.swipe(week, "Mira", key("Mira"), "bierfenster", true)
      Ballot.swipe(week, "Jonas", key("Jonas"), "shamrock", true)

      assert %{day: day, places: places, blocked: blocked} = Ballot.outcome(Ballot.tally(week))

      assert day.weekday == :tuesday
      assert Enum.map(places, & &1.place.slug) == ["shamrock"]
      # ...and says why the more popular one was passed over.
      assert blocked.place.slug == "bierfenster"
    end

    test "picks the most-liked place when it is open anyway", %{week: week} do
      Ballot.set_day(week, "Jonas", key("Jonas"), :thursday, :yes)
      Ballot.swipe(week, "Jonas", key("Jonas"), "bierfenster", true)
      Ballot.swipe(week, "Mira", key("Mira"), "bierfenster", true)

      assert %{places: places, blocked: nil} = Ballot.outcome(Ballot.tally(week))

      assert Enum.map(places, & &1.place.slug) == ["bierfenster"]
    end

    test "has no place when nothing approved is open on the winning day", %{week: week} do
      Ballot.set_day(week, "Jonas", key("Jonas"), :monday, :yes)
      Ballot.swipe(week, "Jonas", key("Jonas"), "bierfenster", true)

      assert %{day: day, places: []} = outcome = Ballot.outcome(Ballot.tally(week))

      assert day.weekday == :monday
      refute Ballot.decided?(outcome)
    end

    test "is nil before anybody has picked a day", %{week: week} do
      assert Ballot.outcome(Ballot.tally(week)) == nil
    end
  end

  describe "draws" do
    test "every place tied at the top of the winning day is reported", %{week: week} do
      commits(week, "Jonas")
      Ballot.swipe(week, "Jonas", key("Jonas"), "shamrock", true)
      Ballot.swipe(week, "Jonas", key("Jonas"), "pickwick", true)

      assert %{places: places} = Ballot.outcome(Ballot.tally(week))

      assert length(places) == 2
      assert "shamrock" in Enum.map(places, & &1.place.slug)
      assert "pickwick" in Enum.map(places, & &1.place.slug)
    end

    test "a place shut on the winning day is left out of the draw", %{week: week} do
      # Wednesday wins; Bierfenster only opens Thursday and Friday.
      commits(week, "Jonas")
      Ballot.swipe(week, "Jonas", key("Jonas"), "bierfenster", true)
      Ballot.swipe(week, "Jonas", key("Jonas"), "shamrock", true)

      assert %{places: places, blocked: blocked} = Ballot.outcome(Ballot.tally(week))

      assert Enum.map(places, & &1.place.slug) == ["shamrock"]
      assert blocked.place.slug == "bierfenster"
    end
  end

  describe "only the people free on the winning day get a say" do
    test "a swipe from someone busy that day does not count", %{week: week} do
      # Wednesday wins; Ada can only do Monday.
      for name <- ~w(Jonas Mira), do: commits(week, name)
      Ballot.set_day(week, "Ada", key("Ada"), :monday, :yes)

      Ballot.swipe(week, "Jonas", key("Jonas"), "shamrock", true)
      Ballot.swipe(week, "Ada", key("Ada"), "pickwick", true)

      tally = Ballot.tally(week)

      assert Ballot.winning_day(tally).weekday == :wednesday
      assert result(tally, "shamrock").likes == 1
      assert result(tally, "pickwick").likes == 0
      assert result(tally, "pickwick").waiting_likes == 1
    end

    test "they are listed as waiting, the same as somebody with no day at all", %{week: week} do
      for name <- ~w(Jonas Mira), do: commits(week, name)
      Ballot.set_day(week, "Ada", key("Ada"), :monday, :yes)
      Ballot.swipe(week, "Ada", key("Ada"), "pickwick", true)
      Ballot.swipe(week, "Kim", key("Kim"), "pickwick", true)

      assert Ballot.tally(week).waiting == ["Ada", "Kim"]
    end

    test "a maybe on the winning day is enough to count", %{week: week} do
      commits(week, "Jonas")
      Ballot.set_day(week, "Ada", key("Ada"), :wednesday, :maybe)
      Ballot.swipe(week, "Ada", key("Ada"), "pickwick", true)

      assert result(week, "pickwick").likes == 1
      assert Ballot.tally(week).waiting == []
    end

    test "the count follows the winning day when it moves", %{week: week} do
      Ballot.set_day(week, "Jonas", key("Jonas"), :wednesday, :yes)
      Ballot.set_day(week, "Ada", key("Ada"), :thursday, :yes)
      Ballot.swipe(week, "Ada", key("Ada"), "pickwick", true)

      # Thursday is nearer the weekend, so it takes the level tie and Ada counts.
      assert Ballot.winning_day(Ballot.tally(week)).weekday == :thursday
      assert result(week, "pickwick").likes == 1

      # Two more for Wednesday and it wins outright, so Ada drops out again.
      for name <- ~w(Mira Kim), do: commits(week, name)

      assert Ballot.winning_day(Ballot.tally(week)).weekday == :wednesday
      assert result(week, "pickwick").likes == 0
      assert Ballot.tally(week).waiting == ["Ada"]
    end

    test "before any day leads, any commitment earns a say", %{week: week} do
      Ballot.set_day(week, "Ada", key("Ada"), :monday, :yes)
      Ballot.swipe(week, "Ada", key("Ada"), "pickwick", true)

      assert result(week, "pickwick").likes == 1
    end
  end

  describe "counts?/2" do
    test "is false with no day marked at all", %{week: week} do
      refute Ballot.counts?(Ballot.tally(week), %{})
    end

    test "is true before any day leads, once some day is marked", %{week: week} do
      assert Ballot.counts?(Ballot.tally(week), %{monday: :yes})
    end

    test "follows the winning day once there is one", %{week: week} do
      commits(week, "Jonas")
      tally = Ballot.tally(week)

      assert Ballot.counts?(tally, %{wednesday: :yes})
      assert Ballot.counts?(tally, %{wednesday: :maybe})
      refute Ballot.counts?(tally, %{monday: :yes})
    end
  end

  describe "ranked/1" do
    test "numbers the table like a league table" do
      places = [result_with(3, 0), result_with(2, 0), result_with(2, 0), result_with(1, 0)]

      assert Ballot.ranked(places) |> Enum.map(&elem(&1, 0)) == [1, 2, nil, 4]
    end

    test "leaves a drawn row blank rather than repeating the position" do
      places = [result_with(5, 0), result_with(5, 0), result_with(5, 0), result_with(1, 0)]

      assert Ballot.ranked(places) |> Enum.map(&elem(&1, 0)) == [1, nil, nil, 4]
    end

    test "ignores rejections when deciding a position" do
      # A left swipe is worth nothing, so these two are drawn on one like each.
      places = [result_with(2, 0), result_with(2, 7)]

      assert Ballot.ranked(places) |> Enum.map(&elem(&1, 0)) == [1, nil]
    end

    test "keeps every row and their order" do
      places = [result_with(2, 0), result_with(2, 0)]

      assert Ballot.ranked(places) |> Enum.map(&elem(&1, 1)) == places
    end

    test "copes with an empty table" do
      assert Ballot.ranked([]) == []
    end
  end

  describe "closed_days/2" do
    test "names the weekdays a place cannot host", %{week: week} do
      {:ok, bierfenster} = Places.fetch("bierfenster")

      assert Ballot.closed_days(bierfenster, week) == [:monday, :tuesday, :wednesday]
    end

    test "is empty for a place open all week", %{week: week} do
      {:ok, shamrock} = Places.fetch("shamrock")

      assert Ballot.closed_days(shamrock, week) == []
    end
  end

  describe "history/2" do
    test "reports where past weeks ended up, most recent first", %{week: week} do
      for {weeks_ago, slug, day} <- [{1, "shamrock", :thursday}, {3, "pickwick", :tuesday}] do
        past = Week.from_date(Date.add(week.monday, -7 * weeks_ago))
        Ballot.set_day(past, "Jonas", key("Jonas"), day, :yes)
        Ballot.swipe(past, "Jonas", key("Jonas"), slug, true)
      end

      assert [recent, older] = Ballot.history(week)

      assert recent.place.slug == "shamrock"
      assert recent.weekday == :thursday
      assert older.place.slug == "pickwick"
    end

    test "leaves out the week being voted on", %{week: week} do
      Ballot.set_day(week, "Jonas", key("Jonas"), :thursday, :yes)
      Ballot.swipe(week, "Jonas", key("Jonas"), "shamrock", true)

      assert Ballot.history(week) == []
    end

    test "skips a week that never reached a decision", %{week: week} do
      past = Week.from_date(Date.add(week.monday, -7))
      # Swipes but no day, so nothing was ever settled.
      Ballot.swipe(past, "Jonas", key("Jonas"), "shamrock", true)

      assert Ballot.history(week) == []
    end
  end

  describe "last_visits/2" do
    test "reports how many weeks ago each place last won", %{week: week} do
      for {weeks_ago, slug} <- [{1, "shamrock"}, {2, "pickwick"}, {4, "shamrock"}] do
        past = Week.from_date(Date.add(week.monday, -7 * weeks_ago))
        Ballot.set_day(past, "Jonas", key("Jonas"), :thursday, :yes)
        Ballot.swipe(past, "Jonas", key("Jonas"), slug, true)
      end

      visits = Ballot.last_visits(week)

      # The most recent win is the one that matters, not every win.
      assert visits["shamrock"] == 1
      assert visits["pickwick"] == 2
      refute Map.has_key?(visits, "mccarthys")
    end
  end

  describe "swipes from someone who has not picked a day" do
    test "do not count towards the tally", %{week: week} do
      commits(week, "Jonas")
      Ballot.swipe(week, "Jonas", key("Jonas"), "shamrock", true)
      # Mira swipes but never says when she can come.
      Ballot.swipe(week, "Mira", key("Mira"), "shamrock", true)

      result = result(week, "shamrock")

      assert result.likes == 1
      assert result.fans == ["Jonas"]
    end

    test "are kept and shown as waiting, not thrown away", %{week: week} do
      Ballot.swipe(week, "Mira", key("Mira"), "shamrock", true)
      Ballot.swipe(week, "Mira", key("Mira"), "pickwick", false)

      tally = Ballot.tally(week)

      assert tally.waiting == ["Mira"]
      assert result(tally, "shamrock").waiting_likes == 1
      assert result(tally, "shamrock").waiting == ["Mira"]
      assert result(tally, "pickwick").waiting_dislikes == 1
    end

    test "cannot decide the winner on their own", %{week: week} do
      commits(week, "Jonas")
      Ballot.swipe(week, "Jonas", key("Jonas"), "shamrock", true)

      # Two enthusiastic swipes for a rival, from people who are not coming.
      for name <- ~w(Mira Ada), do: Ballot.swipe(week, name, key(name), "pickwick", true)

      assert Ballot.winning_place(Ballot.tally(week)).place.slug == "shamrock"
    end

    test "start counting the moment they pick a day", %{week: week} do
      Ballot.swipe(week, "Mira", key("Mira"), "shamrock", true)
      assert result(week, "shamrock").likes == 0

      commits(week, "Mira")

      assert result(week, "shamrock").likes == 1
      assert Ballot.tally(week).waiting == []
    end

    test "stop counting again if they withdraw from every day", %{week: week} do
      commits(week, "Mira")
      Ballot.swipe(week, "Mira", key("Mira"), "shamrock", true)
      assert result(week, "shamrock").likes == 1

      Ballot.set_day(week, "Mira", key("Mira"), :wednesday, nil)

      assert result(week, "shamrock").likes == 0
      assert Ballot.tally(week).waiting == ["Mira"]
    end
  end

  defp result_with(likes, dislikes) do
    %Ballot.PlaceResult{
      place: hd(Places.all()),
      likes: likes,
      dislikes: dislikes,
      fans: [],
      critics: [],
      waiting_likes: 0,
      waiting_dislikes: 0,
      waiting: []
    }
  end

  defp key(name), do: Ballot.voter_key(name)

  # Saying which days work is what earns a say in where.
  defp commits(week, name), do: Ballot.set_day(week, name, key(name), :wednesday, :yes)

  defp first_slug, do: Places.all() |> hd() |> Map.fetch!(:slug)

  defp day(tally, weekday), do: Enum.find(tally.days, &(&1.weekday == weekday))

  defp result(%Ballot.Tally{} = tally, slug),
    do: tally |> Map.fetch!(:places) |> Enum.find(&(&1.place.slug == slug))

  defp result(week, slug), do: week |> Ballot.tally() |> result(slug)
end
