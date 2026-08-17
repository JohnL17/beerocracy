defmodule BeerocracyWeb.RulesLiveTest do
  # Not async: SQLite allows a single writer, and the sandbox holds a write
  # transaction open for the length of each test — concurrent DB tests deadlock
  # on the write lock rather than merely queueing. Measured, not assumed.
  use BeerocracyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Beerocracy.Weather.Forecast

  test "explains the rules that are not obvious from the ballot", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/rules")

    assert html =~ "The rules"
    assert html =~ "A maybe counts"
    assert html =~ "The deck is shuffled per person"
    assert html =~ "A place that is shut cannot win"
    assert html =~ "Seasonal places retire themselves"
    assert html =~ "Only the people who will be there choose"
    assert html =~ "Ties go to certainty, then to the weekend"
  end

  test "states the window the forecast covers", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/rules")

    assert html =~ Forecast.window(Beerocracy.Weather.window())
  end

  describe "the rain table" do
    test "shows every combination of rainfall and chance", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/rules")

      for {_millimetres, label} <- Forecast.rain_bands(), do: assert(html =~ label)
      for {_chance, label} <- Forecast.chance_bands(), do: assert(html =~ label)
    end

    test "prints the same verdict the ballot would", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rules")
      cells = view |> element("table.rules-table") |> render()

      # Generated from verdict_for/2 rather than restated, so the page cannot
      # drift away from what the tiles actually say.
      for {chance, _} <- Forecast.chance_bands(), {millimetres, _} <- Forecast.rain_bands() do
        verdict = Forecast.verdict_for(chance, millimetres)

        assert cells =~ verdict.phrase,
               "#{chance}% at #{millimetres}mm should read #{verdict.phrase}"
      end
    end

    test "matches what a real forecast produces", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rules")
      cells = view |> element("table.rules-table") |> render()

      # The awkward corner that prompted the wording: near certain, no rainfall.
      forecast = %Forecast{
        date: ~D[2026-08-19],
        from_hour: 16,
        to_hour: 22,
        code: 95,
        temp_min: 17.0,
        temp_max: 23.0,
        rain: [{16, 98, 0.0}]
      }

      assert Forecast.verdict(forecast).phrase == "Few drops"
      assert cells =~ "Few drops"
    end

    test "colours the wet verdicts like the tiles do", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rules")
      table = view |> element("table.rules-table") |> render()

      # Several cells share a level, so match the level to its phrase rather
      # than expecting a unique element.
      assert table =~ ~r/data-level="4"[^>]*>\s*Heavy rain/
      assert table =~ ~r/data-level="0"[^>]*>\s*Dry/
      assert table =~ ~r/data-level="3"[^>]*>\s*Rain/
    end
  end

  describe "getting there" do
    test "links back to the ballot and the register", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rules")

      assert view |> element("a[href='/']") |> has_element?()
      assert view |> element("a[href='/places']") |> has_element?()
    end

    test "is reachable from both other pages", %{conn: conn} do
      {:ok, ballot, _} = live(conn, ~p"/")
      assert ballot |> element("a[href='/rules']") |> has_element?()

      {:ok, register, _} = live(build_conn(), ~p"/places")
      assert register |> element("a[href='/rules']") |> has_element?()
    end
  end
end
