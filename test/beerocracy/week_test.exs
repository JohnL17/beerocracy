defmodule Beerocracy.WeekTest do
  use ExUnit.Case, async: true

  alias Beerocracy.Week

  describe "from_date/1" do
    test "keys a week by its ISO year and week number" do
      assert %Week{key: "2026-W34", week: 34, year: 2026} = Week.from_date(~D[2026-08-17])
    end

    test "pads single digit week numbers so keys sort lexically" do
      assert %Week{key: "2026-W05"} = Week.from_date(~D[2026-02-01])
    end

    test "spans Monday to Sunday" do
      week = Week.from_date(~D[2026-08-20])

      assert week.monday == ~D[2026-08-17]
      assert week.sunday == ~D[2026-08-23]
    end

    test "every day of one week shares a key" do
      keys =
        ~D[2026-08-17]
        |> Date.range(~D[2026-08-23])
        |> Enum.map(&Week.from_date(&1).key)
        |> Enum.uniq()

      assert keys == ["2026-W34"]
    end

    test "the following Monday starts a new key, which is how the vote resets" do
      assert Week.from_date(~D[2026-08-23]).key == "2026-W34"
      assert Week.from_date(~D[2026-08-24]).key == "2026-W35"
    end

    test "a Sunday belonging to the previous ISO year keeps that year" do
      # 2027-01-03 is a Sunday, still in ISO week 53 of 2026.
      assert %Week{key: "2026-W53", year: 2026, week: 53} = Week.from_date(~D[2027-01-03])
    end
  end

  describe "date_of/2" do
    test "maps weekdays onto the dates of that week" do
      week = Week.from_date(~D[2026-08-19])

      assert Week.date_of(week, :monday) == ~D[2026-08-17]
      assert Week.date_of(week, :friday) == ~D[2026-08-21]
    end
  end

  describe "seconds_until_reset/2" do
    test "counts down to midnight on the following Monday" do
      week = Week.from_date(~D[2026-08-17])
      now = ~U[2026-08-23 23:00:00Z]

      assert Week.seconds_until_reset(week, now) == 3600
    end

    test "never goes negative" do
      week = Week.from_date(~D[2026-08-17])

      assert Week.seconds_until_reset(week, ~U[2026-09-01 12:00:00Z]) == 0
    end
  end

  test "offers Monday through Friday, in order" do
    assert Week.weekdays() == [:monday, :tuesday, :wednesday, :thursday, :friday]
    assert Enum.map(Week.weekdays(), &Week.short_label/1) == ~w(MO TU WE TH FR)
    assert Week.label(:wednesday) == "Wednesday"
  end
end
