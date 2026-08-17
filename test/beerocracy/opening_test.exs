defmodule Beerocracy.OpeningTest do
  use ExUnit.Case, async: true

  alias Beerocracy.Places.Opening

  doctest Beerocracy.Places.Opening

  # 2026-08-17 is a Monday.
  @monday ~D[2026-08-17]
  @thursday ~D[2026-08-20]
  @window {16, 22}

  describe "a place with no restrictions" do
    test "is open every weekday, all year" do
      opening = Opening.always()

      assert Opening.unrestricted?(opening)
      assert Opening.available?(opening, @monday, @window)
      assert Opening.available?(opening, ~D[2026-12-25], @window)
      assert Opening.describe(opening) == nil
    end
  end

  describe "opening days" do
    test "rules out the weekdays it does not open on" do
      opening = %Opening{days: MapSet.new([:thursday, :friday])}

      refute Opening.open_on?(opening, @monday)
      assert Opening.open_on?(opening, @thursday)
    end

    test "lists the weekdays in MO-FR order however they were written" do
      opening = %Opening{days: MapSet.new([:friday, :tuesday])}

      assert Opening.days(opening) == [:tuesday, :friday]
    end

    test "says so in words" do
      assert Opening.describe(%Opening{days: MapSet.new([:thursday, :friday])}) ==
               "Thursdays and Fridays"

      assert Opening.describe(%Opening{days: MapSet.new([:monday])}) == "Mondays only"
    end
  end

  describe "opening hours" do
    test "a place open across the evening is usable" do
      opening = %Opening{from: ~T[17:00:00], to: ~T[20:00:00]}

      assert Opening.overlaps_window?(opening, @window)
    end

    test "a place that shuts before the evening starts is not" do
      opening = %Opening{from: ~T[09:00:00], to: ~T[14:00:00]}

      refute Opening.overlaps_window?(opening, @window)
    end

    test "nor is one that opens after everybody has gone home" do
      opening = %Opening{from: ~T[23:00:00]}

      refute Opening.overlaps_window?(opening, @window)
    end

    test "a late bar that opens within the window counts" do
      assert Opening.overlaps_window?(%Opening{from: ~T[21:00:00]}, @window)
    end

    test "a closing time past midnight is not mistaken for the small hours" do
      # Read naively, 00:30 is before 16:00 and the pub would drop off the
      # ballot — which is most of the catalogue.
      for closing <- [~T[00:00:00], ~T[00:30:00], ~T[01:30:00], ~T[02:00:00]] do
        opening = %Opening{from: ~T[11:30:00], to: closing}

        assert Opening.overlaps_window?(opening, @window),
               "a pub open 11:30 to #{closing} should be usable in the evening"
      end
    end

    test "still rejects a daytime-only place after the wrap-around fix" do
      refute Opening.overlaps_window?(%Opening{from: ~T[09:00:00], to: ~T[14:00:00]}, @window)
    end
  end

  describe "restrictive?/2" do
    test "ordinary pub hours are information, not a constraint" do
      refute Opening.restrictive?(%Opening{from: ~T[11:30:00], to: ~T[00:30:00]}, ~D[2026-08-17])
      refute Opening.restrictive?(Opening.always(), ~D[2026-08-17])
    end

    test "shutting on some weekdays is a constraint" do
      assert Opening.restrictive?(%Opening{days: MapSet.new([:thursday])}, ~D[2026-08-17])
    end

    test "a season about to end is a constraint, a distant one is not" do
      soon = %Opening{season_until: ~D[2026-08-30]}
      distant = %Opening{season_until: ~D[2026-12-31]}

      assert Opening.restrictive?(soon, ~D[2026-08-17])
      refute Opening.restrictive?(distant, ~D[2026-08-17])
    end

    test "so is a season that has not started" do
      assert Opening.restrictive?(%Opening{season_from: ~D[2027-06-01]}, ~D[2026-08-17])
    end
  end

  describe "seasons" do
    test "a place is unavailable before its season starts" do
      opening = %Opening{season_from: ~D[2026-06-12], season_until: ~D[2026-08-30]}

      refute Opening.open_on?(opening, ~D[2026-06-01])
      assert Opening.upcoming?(opening, ~D[2026-06-01])
      refute Opening.over?(opening, ~D[2026-06-01])
    end

    test "and after it ends" do
      opening = %Opening{season_until: ~D[2026-08-30]}

      assert Opening.open_on?(opening, ~D[2026-08-30])
      refute Opening.open_on?(opening, ~D[2026-08-31])
      assert Opening.over?(opening, ~D[2026-08-31])
    end

    test "counts down the days left, never below zero" do
      opening = %Opening{season_until: ~D[2026-08-30]}

      assert Opening.days_left(opening, ~D[2026-08-17]) == 13
      assert Opening.days_left(opening, ~D[2026-08-30]) == 0
      assert Opening.days_left(opening, ~D[2026-09-05]) == 0
      assert Opening.days_left(Opening.always(), ~D[2026-08-17]) == nil
    end
  end

  test "describes days, hours and season together" do
    opening = %Opening{
      days: MapSet.new([:thursday, :friday]),
      from: ~T[17:00:00],
      to: ~T[20:00:00],
      season_until: ~D[2026-08-30]
    }

    assert Opening.describe(opening) == "Thursdays and Fridays, 17:00 - 20:00, until 30 Aug"
  end
end
