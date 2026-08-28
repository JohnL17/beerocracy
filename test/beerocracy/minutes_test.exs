defmodule Beerocracy.MinutesTest do
  use Beerocracy.DataCase, async: false

  alias Beerocracy.Ballot
  alias Beerocracy.Minutes
  alias Beerocracy.Week

  setup do
    this_week = Week.current()
    last_week = Week.from_date(Date.add(this_week.monday, -7))

    # Last week the vote settled on the Shamrock, on Thursday.
    Ballot.set_day(last_week, "Jonas", "gh:1", :thursday, :yes)
    Ballot.swipe(last_week, "Jonas", "gh:1", "shamrock", true)

    %{week: this_week, last_week: last_week}
  end

  defp visit(week, week_key) do
    week |> Ballot.history() |> Enum.find(&(&1.week.key == week_key))
  end

  defp visits(week, week_key) do
    week |> Ballot.history() |> Enum.filter(&(&1.week.key == week_key))
  end

  describe "history with nothing recorded" do
    test "still answers with whatever the vote said", %{week: week, last_week: last_week} do
      assert %{place: place, weekday: :thursday} = visit(week, last_week.key)
      assert place.slug == "shamrock"
    end
  end

  describe "history once an admin has written a week down" do
    test "reports where we actually went, not where we voted to go", ctx do
      Minutes.record(ctx.last_week, :friday, "pickwick", "Jonas")

      assert %{place: place, weekday: :friday} = visit(ctx.week, ctx.last_week.key)
      assert place.slug == "pickwick"
    end

    test "takes a Saturday, which is on the ballot like any other day", ctx do
      Minutes.record(ctx.last_week, :saturday, "pickwick", "Jonas")

      assert %{weekday: :saturday, date: date} = visit(ctx.week, ctx.last_week.key)
      assert date == Date.add(ctx.last_week.monday, 5)
    end

    test "says whose word it is", ctx do
      Minutes.record(ctx.last_week, :friday, "pickwick", "Jonas")

      recorded = visit(ctx.week, ctx.last_week.key)

      assert recorded.recorded_by == "Jonas"
      assert Ballot.Visit.recorded?(recorded)
    end

    test "reports how the place did in the vote it lost", ctx do
      # Nobody swiped right on the Pickwick, which is the interesting part.
      Minutes.record(ctx.last_week, :friday, "pickwick", "Jonas")

      assert visit(ctx.week, ctx.last_week.key).likes == 0
    end

    test "a week nobody voted on at all still counts as a night out", ctx do
      quiet = Week.from_date(Date.add(ctx.week.monday, -14))

      Minutes.record(quiet, :tuesday, "pickwick", "Jonas")

      assert %{place: place} = visit(ctx.week, quiet.key)
      assert place.slug == "pickwick"
    end

    test "the derived answer is not marked as recorded", ctx do
      refute Ballot.Visit.recorded?(visit(ctx.week, ctx.last_week.key))
    end

    test "a slug that has left the catalogue is skipped rather than crashing", ctx do
      Minutes.record(ctx.last_week, :friday, "a-pub-that-closed-down", "Jonas")

      assert visit(ctx.week, ctx.last_week.key) == nil
    end
  end

  describe "the anti-repetition nudge" do
    test "follows where we actually went", ctx do
      Minutes.record(ctx.last_week, :friday, "pickwick", "Jonas")

      visits = Ballot.last_visits(ctx.week)

      assert visits["pickwick"] == 1
      refute Map.has_key?(visits, "shamrock")
    end
  end

  describe "forget/1" do
    test "hands the week back to the vote", ctx do
      Minutes.record(ctx.last_week, :friday, "pickwick", "Jonas")
      Minutes.forget(ctx.last_week)

      assert visit(ctx.week, ctx.last_week.key).place.slug == "shamrock"
    end

    test "is content when there was nothing to forget", ctx do
      assert Minutes.forget(ctx.last_week) == :ok
    end
  end

  describe "a night that moved on" do
    test "keeps every stop, in the order they were written down", ctx do
      Minutes.record(ctx.last_week, :friday, "shamrock", "Jonas")
      Minutes.record(ctx.last_week, :friday, "pickwick", "Jonas")

      assert [first, second] = visits(ctx.week, ctx.last_week.key)

      assert first.place.slug == "shamrock"
      assert second.place.slug == "pickwick"
      assert Enum.all?([first, second], &(&1.weekday == :friday))
    end

    test "takes a week that went out twice, earliest night first", ctx do
      # Written down out of order; the minutes still read Tuesday then Friday.
      Minutes.record(ctx.last_week, :friday, "pickwick", "Jonas")
      Minutes.record(ctx.last_week, :tuesday, "shamrock", "Jonas")

      assert [%{weekday: :tuesday}, %{weekday: :friday}] = visits(ctx.week, ctx.last_week.key)
    end

    test "writing the same stop down again corrects it rather than doubling it", ctx do
      Minutes.record(ctx.last_week, :friday, "pickwick", "Jonas")
      Minutes.record(ctx.last_week, :friday, "pickwick", "Mira")

      assert [%{recorded_by: "Mira"}] = visits(ctx.week, ctx.last_week.key)
      assert length(Minutes.all_entries!()) == 1
    end

    test "the same pub on another night is a separate stop", ctx do
      Minutes.record(ctx.last_week, :tuesday, "pickwick", "Jonas")
      Minutes.record(ctx.last_week, :friday, "pickwick", "Jonas")

      assert length(visits(ctx.week, ctx.last_week.key)) == 2
    end
  end

  describe "forget_stop/3" do
    setup ctx do
      Minutes.record(ctx.last_week, :friday, "shamrock", "Jonas")
      Minutes.record(ctx.last_week, :friday, "pickwick", "Jonas")
      ctx
    end

    test "strikes one stop and leaves the rest of the night", ctx do
      Minutes.forget_stop(ctx.last_week, :friday, "shamrock")

      assert [%{place: place}] = visits(ctx.week, ctx.last_week.key)
      assert place.slug == "pickwick"
    end

    test "leaves an identical pub on another night alone", ctx do
      Minutes.record(ctx.last_week, :tuesday, "shamrock", "Jonas")

      Minutes.forget_stop(ctx.last_week, :friday, "shamrock")

      assert [%{weekday: :tuesday, place: %{slug: "shamrock"}}, %{place: %{slug: "pickwick"}}] =
               visits(ctx.week, ctx.last_week.key)
    end

    test "is content when there was no such stop", ctx do
      assert Minutes.forget_stop(ctx.last_week, :monday, "mccarthys") == :ok
      assert length(visits(ctx.week, ctx.last_week.key)) == 2
    end
  end

  describe "recorded_visits/1" do
    test "is empty for a week nobody has written down", %{week: week} do
      assert Ballot.recorded_visits(week) == []
    end

    test "reports this week once it has been", %{week: week} do
      Minutes.record(week, :wednesday, "shamrock", "Jonas")

      assert [%{weekday: :wednesday, recorded_by: "Jonas"}] = Ballot.recorded_visits(week)
    end

    test "reports every stop of a crawl", %{week: week} do
      Minutes.record(week, :wednesday, "shamrock", "Jonas")
      Minutes.record(week, :wednesday, "mccarthys", "Jonas")

      assert [%{place: %{slug: "shamrock"}}, %{place: %{slug: "mccarthys"}}] =
               Ballot.recorded_visits(week)
    end
  end
end
