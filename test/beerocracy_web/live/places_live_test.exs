defmodule BeerocracyWeb.PlacesLiveTest do
  # Not async: SQLite allows a single writer, and the sandbox holds a write
  # transaction open for the length of each test — concurrent DB tests deadlock
  # on the write lock rather than merely queueing. Measured, not assumed.
  use BeerocracyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Beerocracy.Places
  alias Beerocracy.Places.Reach

  describe "the register" do
    test "lists every place in the catalogue", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/places")

      assert html =~ "The candidates"

      for place <- Places.all() do
        assert view |> element("#place-#{place.slug}") |> has_element?()
      end
    end

    test "shows the full detail of a place, not just its name", %{conn: conn} do
      place = hd(Places.all())
      {:ok, view, _html} = live(conn, ~p"/places")

      entry = view |> element("#place-#{place.slug}") |> render()

      assert entry =~ place.beer_note
      assert entry =~ place.food_note
      assert entry =~ "Office"
      assert entry =~ "Station"
      assert entry =~ to_string(Reach.minutes(place.office))
    end

    test "offers nothing to vote with", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/places")

      refute html =~ "phx-click=\"swipe\""
      refute html =~ "cycle_day"
      refute view |> element("button[phx-click=cycle_day]") |> has_element?()
      refute view |> element("button[phx-click=undo]") |> has_element?()
      refute view |> element("form[phx-submit=register]") |> has_element?()
      refute view |> element(".swipe-card") |> has_element?()
    end

    test "prints a zero rating as None rather than an empty score", %{conn: conn} do
      place = Enum.find(Places.all(), &(&1.food_rating == 0))
      assert place, "expected a place in the catalogue with no food at all"

      {:ok, view, _html} = live(conn, ~p"/places")
      entry = view |> element("#place-#{place.slug}") |> render()

      assert entry =~ "None"
      refute entry =~ ~s(aria-label="0 out of 5")
    end

    test "links the catalogue to the file on GitHub", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/places")

      assert view |> element("a[href='#{Places.source_url()}']") |> render() =~ "places.yml"
      assert view |> element("a[href='#{Places.edit_url()}']") |> has_element?()
    end

    test "links back to the ballot", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/places")

      assert view |> element("a[href='/']") |> has_element?()
    end

    test "is reachable from the ballot", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert view |> element("a[href='/places']") |> has_element?()
    end
  end

  describe "sorting" do
    test "keeps catalogue order by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/places")

      assert slugs_in_order(html) == Enum.map(Places.all(), & &1.slug)
    end

    test "sorts by beer, best first", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/places?by=beer")

      ratings = html |> slugs_in_order() |> Enum.map(&rating_of(&1, :beer_rating))
      assert ratings == Enum.sort(ratings, :desc)
    end

    test "sorts by food, best first", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/places?by=food")

      ratings = html |> slugs_in_order() |> Enum.map(&rating_of(&1, :food_rating))
      assert ratings == Enum.sort(ratings, :desc)
    end

    test "sorts by nearest the office", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/places?by=nearest")

      minutes =
        html
        |> slugs_in_order()
        |> Enum.map(fn slug ->
          {:ok, place} = Places.fetch(slug)
          Reach.minutes(place.office)
        end)

      assert minutes == Enum.sort(minutes)
    end

    test "marks the active sort", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/places?by=beer")

      assert view |> element("a[aria-current=true]") |> render() =~ "Beer"
    end

    test "falls back to catalogue order for a sort that does not exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/places?by=vibes")

      assert slugs_in_order(html) == Enum.map(Places.all(), & &1.slug)
    end

    test "switching sort keeps the same places on the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/places")

      html = view |> element("a[href='/places?by=nearest']") |> render_click()

      assert Enum.sort(slugs_in_order(html)) == Enum.sort(Enum.map(Places.all(), & &1.slug))
    end
  end

  defp slugs_in_order(html) do
    Regex.scan(~r/id="place-([a-z0-9-]+)"/, html) |> Enum.map(&List.last/1)
  end

  defp rating_of(slug, field) do
    {:ok, place} = Places.fetch(slug)
    Map.fetch!(place, field)
  end
end
