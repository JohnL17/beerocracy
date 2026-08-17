defmodule BeerocracyWeb.BallotLiveTest do
  # Not async: SQLite allows a single writer, and the sandbox holds a write
  # transaction open for the length of each test — concurrent DB tests deadlock
  # on the write lock rather than merely queueing. Measured, not assumed.
  use BeerocracyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Beerocracy.Ballot
  alias Beerocracy.Places
  alias Beerocracy.Places.Reach
  alias Beerocracy.Week

  describe "the sheet" do
    test "shows the current week number and the date range", %{conn: conn} do
      week = Week.current()
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Beerocracy"
      assert html =~ to_string(week.week)
      assert html =~ "Calendar week"
    end

    test "lists every place from the catalogue in the tally", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      for place <- Places.all() do
        assert html =~ escaped(place.name)
      end
    end

    test "locks the voting sections until someone signs the register", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert view |> element("section[data-locked]") |> has_element?()

      view |> form("form[phx-submit=register]", name: "Jonas") |> render_submit()

      refute view |> element("section[data-locked]") |> has_element?()
      assert render(view) =~ "Signed: Jonas"
    end

    test "links the catalogue to the file on GitHub", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert view |> element("a[href='#{Places.source_url()}']") |> render() =~ "places.yml"
      assert view |> element("a[href='#{Places.edit_url()}']") |> render() =~ "Add a place"
    end

    test "refuses a blank name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_submit(view, "register", %{"name" => "   "})

      assert html =~ "Enter a name first"
      assert view |> element("section[data-locked]") |> has_element?()
    end
  end

  describe "voting for a day" do
    setup [:signed_in]

    test "marks a day yes and shows it in the tally", %{view: view} do
      tap_day(view, :wednesday)

      assert stance(view, :wednesday) == "yes"
      assert view |> element("button[phx-value-weekday=wednesday][data-leader]") |> has_element?()
      assert render(view) =~ "Wednesday is leading, but nothing approved is open"
    end

    test "cycles yes to maybe to cleared", %{view: view} do
      tap_day(view, :tuesday)
      assert stance(view, :tuesday) == "yes"

      tap_day(view, :tuesday)
      assert stance(view, :tuesday) == "maybe"

      tap_day(view, :tuesday)
      assert stance(view, :tuesday) == nil
    end

    test "a maybe still counts towards the day", %{view: view} do
      tap_day(view, :friday)
      tap_day(view, :friday)

      assert stance(view, :friday) == "maybe"

      day =
        Ballot.tally(Week.current()) |> Map.fetch!(:days) |> Enum.find(&(&1.weekday == :friday))

      assert day.count == 1
      assert day.maybe_count == 1
      assert view |> element("button[phx-value-weekday=friday][data-leader]") |> has_element?()
    end

    test "labels the voter's own answer on the tile", %{view: view} do
      tap_day(view, :monday)
      assert view |> element("button[phx-value-weekday=monday]") |> render() =~ "Yes"

      tap_day(view, :monday)
      assert view |> element("button[phx-value-weekday=monday]") |> render() =~ "Maybe"
    end

    test "offers Monday through Friday and nothing else", %{view: view} do
      for weekday <- Week.weekdays() do
        assert view |> element("button[phx-value-weekday=#{weekday}]") |> has_element?()
      end

      refute view |> element("button[phx-value-weekday=saturday]") |> has_element?()
      refute view |> element("button[phx-value-weekday=sunday]") |> has_element?()
    end

    test "ignores a weekday that is not on the ballot", %{view: view} do
      render_click(view, "cycle_day", %{"weekday" => "caturday"})

      assert Ballot.tally(Week.current()).day_votes_cast == 0
    end
  end

  describe "swiping for a place" do
    setup [:signed_in]

    test "deals three places as a stack", %{view: view} do
      assert [first, second, third] = deck_slugs(view)
      assert length(Enum.uniq([first, second, third])) == 3

      assert view |> element("#card-#{first}[data-depth='0']") |> has_element?()
      assert view |> element("#card-#{second}[data-depth='1']") |> has_element?()
      assert view |> element("#card-#{third}[data-depth='2']") |> has_element?()
    end

    test "deals them in a different order to a different voter", %{conn: conn} do
      orders =
        for name <- ~w(Jonas Mira Ada Kim Sam) do
          {:ok, view, _} = live(conn, ~p"/")
          view |> form("form[phx-submit=register]", name: name) |> render_submit()
          deck_slugs(view)
        end

      assert length(Enum.uniq(orders)) > 1,
             "every voter was dealt the same three cards first"
    end

    test "deals the same order to the same voter on a later visit", %{conn: conn} do
      first_visit =
        (fn ->
           {:ok, view, _} = live(conn, ~p"/")
           view |> form("form[phx-submit=register]", name: "Jonas") |> render_submit()
           deck_slugs(view)
         end).()

      {:ok, view, _} = live(build_conn(), ~p"/")
      render_hook(view, "restore_voter", %{"name" => "Jonas"})

      assert deck_slugs(view) == first_visit
    end

    test "shows the beer, food and proximity information on the card", %{view: view} do
      {:ok, place} = Places.fetch(top_slug(view))
      card = view |> element("#card-#{place.slug}") |> render()

      assert card =~ place.beer_note
      assert card =~ place.food_note
      assert card =~ "Office"
      assert card =~ "Station"
      assert card =~ to_string(Reach.minutes(place.office))
      assert card =~ to_string(Reach.minutes(place.station))
    end

    test "shows the quicker route and notes the other one", %{view: view} do
      # Whichever place in the catalogue offers both routes to the station.
      place = Enum.find(Places.all(), &(&1.station.walk && &1.station.transit))
      assert place, "expected at least one place reachable both on foot and by transit"

      bring_to_top(view, place.slug)

      {mode, minutes} = Reach.best(place.station)
      {other_mode, other_minutes} = Reach.alternative(place.station)
      card = view |> element("#card-#{place.slug}") |> render()

      assert card =~ "#{minutes}"
      assert card =~ "min #{Reach.label(mode)}"
      assert card =~ "or #{other_minutes} min #{Reach.label(other_mode)}"
    end

    test "a right swipe records approval and deals the next card", %{view: view} do
      [first, second | _] = deck_slugs(view)

      render_hook(view, "swipe", %{"slug" => first, "liked" => true})

      refute view |> element("#card-#{first}") |> has_element?()
      assert view |> element("#card-#{second}[data-depth='0']") |> has_element?()
      assert render(view) =~ "1 of #{length(Places.all())} judged"
    end

    test "a left swipe records a rejection", %{view: view} do
      place = hd(Places.all())

      # Only counts once the swiper has said when they can come.
      tap_day(view, :wednesday)
      render_hook(view, "swipe", %{"slug" => place.slug, "liked" => false})

      result = Ballot.tally(Week.current()).places |> Enum.find(&(&1.place.slug == place.slug))
      assert %{likes: 0, dislikes: 1} = result
    end

    test "undo puts the last card back on top of the deck", %{view: view} do
      [first, second | _] = deck_slugs(view)

      render_hook(view, "swipe", %{"slug" => first, "liked" => true})
      render_hook(view, "swipe", %{"slug" => second, "liked" => true})

      view |> element("button[phx-click=undo]") |> render_click()

      assert view |> element("#card-#{second}[data-depth='0']") |> has_element?()
      refute view |> element("#card-#{first}") |> has_element?()
    end

    test "stamps the ballot complete once every place is judged", %{view: view} do
      for place <- Places.all() do
        render_hook(view, "swipe", %{"slug" => place.slug, "liked" => place.beer_rating > 3})
      end

      html = render(view)
      assert html =~ "Ballot complete"
      refute html =~ "data-depth=\"0\""
    end

    test "ignores a slug that is no longer in the catalogue", %{view: view} do
      html = render_hook(view, "swipe", %{"slug" => "demolished-pub", "liked" => true})

      assert html =~ "no longer in the catalogue"
    end
  end

  describe "opening hours on the sheet" do
    setup [:signed_in]

    test "a place is only dealt when it can host some day this week", %{view: view} do
      dealt = Enum.map(Places.available(Week.current()), & &1.slug)

      assert "bierfenster" in dealt, "Thursday-only places are still votable this week"

      # Meliano's season ends 2026-08-30, so it is on the ballot now and gone later.
      autumn = Week.from_date(~D[2026-11-04])
      refute "melianos" in Enum.map(Places.available(autumn), & &1.slug)

      assert render(view) =~ "of #{length(dealt)} judged"
    end

    test "says when the day it wants is shut", %{view: view} do
      tap_day(view, :tuesday)
      render_hook(view, "swipe", %{"slug" => "bierfenster", "liked" => true})

      html = render(view)

      # Tuesday plus a Thursday-only brewery window must not read as a decision.
      refute html =~ "Tuesday at Bierfenster"
      assert html =~ "shut on Tuesday"
    end

    test "prints the restriction on the card", %{view: view} do
      bring_to_top(view, "bierfenster")
      card = view |> element("#card-bierfenster") |> render()

      assert card =~ "Thursdays and Fridays"
      assert card =~ "17:00 - 20:00"
    end
  end

  describe "where we went" do
    setup [:signed_in]

    test "lists past weeks and flags a place we were at recently", %{conn: conn} do
      week = Week.current()
      past = Week.from_date(Date.add(week.monday, -7))

      Ballot.set_day(past, "Jonas", Ballot.voter_key("Jonas"), :thursday, :yes)
      Ballot.swipe(past, "Jonas", Ballot.voter_key("Jonas"), "shamrock", true)

      {:ok, view, _html} = live(conn, ~p"/")
      view |> form("form[phx-submit=register]", name: "Jonas") |> render_submit()

      html = render(view)
      assert html =~ "Where we went"
      assert html =~ "W#{past.week}"

      bring_to_top(view, "shamrock")
      assert view |> element("#card-shamrock") |> render() =~ "here last week"
    end

    test "says nothing when there is no history yet", %{view: view} do
      refute render(view) =~ "Where we went"
    end
  end

  describe "swiping without picking a day" do
    setup [:signed_in]

    test "tells you your swipes are not counting yet", %{view: view} do
      refute render(view) =~ "not counting yet"

      render_hook(view, "swipe", %{"slug" => top_slug(view), "liked" => true})

      assert render(view) =~ "Your swipes are not counting yet"
    end

    test "offers a way out for anyone who cannot make it", %{view: view} do
      render_hook(view, "swipe", %{"slug" => top_slug(view), "liked" => true})

      button =
        view
        |> element("button[phx-click=reset_vote][data-confirm^='Clear your swipes']")
        |> render()

      assert render(view) =~ "Cannot make it this week?"
      assert button =~ "Clear my swipes"
      # A literal interpolation marker here would mean HEEx never expanded it.
      assert button =~ "week #{Week.current().week}?"
    end

    test "clearing the swipes empties the deck state and the nudge", %{view: view} do
      render_hook(view, "swipe", %{"slug" => top_slug(view), "liked" => true})
      assert render(view) =~ "1 of"

      view
      |> element("button[phx-click=reset_vote][data-confirm^='Clear your swipes']")
      |> render_click()

      html = render(view)
      refute html =~ "Your swipes are not counting yet"
      assert html =~ "0 of"
    end

    test "the nudge goes away once a day is picked", %{view: view} do
      render_hook(view, "swipe", %{"slug" => top_slug(view), "liked" => true})
      assert render(view) =~ "Your swipes are not counting yet"

      tap_day(view, :wednesday)

      refute render(view) =~ "Your swipes are not counting yet"
    end

    test "names the people whose swipes are parked", %{view: view, conn: conn} do
      # Jonas commits and swipes; Mira only swipes.
      tap_day(view, :wednesday)
      render_hook(view, "swipe", %{"slug" => "shamrock", "liked" => true})

      {:ok, mira, _} = live(conn, ~p"/")
      mira |> form("form[phx-submit=register]", name: "Mira") |> render_submit()
      render_hook(mira, "swipe", %{"slug" => "pickwick", "liked" => true})

      html = render(view)

      assert html =~ "Not counting yet:"
      assert html =~ "Mira"
      # Parked swipes are shown, not hidden.
      assert html =~ "+1?"
    end

    test "the parked swipe does not decide the winner", %{view: view, conn: conn} do
      tap_day(view, :wednesday)
      render_hook(view, "swipe", %{"slug" => "shamrock", "liked" => true})

      for name <- ~w(Mira Ada) do
        {:ok, other, _} = live(conn, ~p"/")
        other |> form("form[phx-submit=register]", name: name) |> render_submit()
        render_hook(other, "swipe", %{"slug" => "pickwick", "liked" => true})
      end

      assert Ballot.winning_place(Ballot.tally(Week.current())).place.slug == "shamrock"
    end
  end

  describe "resetting your vote" do
    setup [:signed_in]

    test "clears the voter's own days and swipes", %{view: view} do
      slug = top_slug(view)

      tap_day(view, :monday)
      tap_day(view, :tuesday)
      render_hook(view, "swipe", %{"slug" => slug, "liked" => true})
      refute view |> element("#card-#{slug}") |> has_element?()

      view |> element("button[phx-click=reset_vote]") |> render_click()

      assert stance(view, :monday) == nil
      assert stance(view, :tuesday) == nil
      assert slug in deck_slugs(view)
      assert render(view) =~ "0 of #{length(Places.all())} judged"
    end

    test "says what it cleared", %{view: view} do
      tap_day(view, :monday)
      render_hook(view, "swipe", %{"slug" => hd(Places.all()).slug, "liked" => false})

      html = view |> element("button[phx-click=reset_vote]") |> render_click()

      assert html =~ "Cleared 1 day and 1 swipe"
    end

    test "is honest when there was nothing to clear", %{view: view} do
      html = view |> element("button[phx-click=reset_vote]") |> render_click()

      assert html =~ "Nothing to clear"
    end

    test "leaves everyone else's votes alone", %{view: view, conn: conn} do
      {:ok, mira, _} = live(conn, ~p"/")
      mira |> form("form[phx-submit=register]", name: "Mira") |> render_submit()
      mira |> element("button[phx-value-weekday=monday]") |> render_click()

      tap_day(view, :monday)
      view |> element("button[phx-click=reset_vote]") |> render_click()

      day =
        Ballot.tally(Week.current()) |> Map.fetch!(:days) |> Enum.find(&(&1.weekday == :monday))

      assert day.count == 1
      assert day.voters == ["Mira"]
    end

    test "asks before throwing the work away", %{view: view} do
      assert view |> element("button[phx-click=reset_vote][data-confirm]") |> has_element?()
    end
  end

  describe "several voters" do
    test "one voter's swipe shows up on another's sheet without a reload", %{conn: conn} do
      place = hd(Places.all())

      {:ok, mira, _} = live(conn, ~p"/")
      mira |> form("form[phx-submit=register]", name: "Mira") |> render_submit()

      {:ok, jonas, _} = live(build_conn(), ~p"/")
      jonas |> form("form[phx-submit=register]", name: "Jonas") |> render_submit()

      render_hook(jonas, "swipe", %{"slug" => place.slug, "liked" => true})
      jonas |> element("button[phx-value-weekday=thursday]") |> render_click()

      # Mira never touched her browser; the tally arrives over PubSub.
      html = render(mira)
      assert html =~ "Thursday at #{place.name}"
      assert html =~ "Jonas"
    end

    test "the same name picks up where it left off", %{conn: conn} do
      place = hd(Places.all())

      {:ok, first, _} = live(conn, ~p"/")
      first |> form("form[phx-submit=register]", name: "Jonas") |> render_submit()
      first |> element("button[phx-value-weekday=friday]") |> render_click()
      render_hook(first, "swipe", %{"slug" => place.slug, "liked" => true})

      # A new browser, the name restored from local storage.
      {:ok, second, _} = live(build_conn(), ~p"/")
      render_hook(second, "restore_voter", %{"name" => "  jonas "})

      assert stance(second, :friday) == "yes"
      refute second |> element("#card-#{place.slug}") |> has_element?()
      assert render(second) =~ "Signed: jonas"
    end

    test "signing out clears the sheet for the next person", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      view |> form("form[phx-submit=register]", name: "Jonas") |> render_submit()
      view |> element("button[phx-value-weekday=monday]") |> render_click()

      view |> element("button[phx-click=sign_out]") |> render_click()

      assert view |> element("section[data-locked]") |> has_element?()
      assert view |> element("form[phx-submit=register]") |> has_element?()
      # The vote itself stays on the sheet — signing out is not a retraction.
      assert render(view) =~ "Monday at" or Ballot.tally(Week.current()).day_votes_cast == 1
    end
  end

  test "votes cast in another week do not appear on this week's sheet", %{conn: conn} do
    last_week = Week.from_date(Date.add(Date.utc_today(), -7))
    Ballot.set_day(last_week, "Ghost", Ballot.voter_key("Ghost"), :monday, :yes)

    {:ok, _view, html} = live(conn, ~p"/")

    refute html =~ "Ghost"
  end

  # The deck is shuffled per voter, so tests read the order off the page rather
  # than assuming the catalogue's.
  defp deck_slugs(view) do
    ~r/data-slug="([a-z0-9-]+)"/
    |> Regex.scan(render(view))
    |> Enum.map(&List.last/1)
  end

  defp top_slug(view), do: view |> deck_slugs() |> List.first()

  # Reject whatever is in front until `slug` is the card on top.
  defp bring_to_top(view, slug) do
    Enum.each(1..length(Places.all()), fn _ ->
      case top_slug(view) do
        ^slug -> :ok
        other -> render_hook(view, "swipe", %{"slug" => other, "liked" => false})
      end
    end)

    assert top_slug(view) == slug
  end

  defp tap_day(view, weekday) do
    view |> element("button[phx-value-weekday=#{weekday}]") |> render_click()
  end

  # The voter's own stance is what the tile carries in `data-stance`.
  defp stance(view, weekday) do
    view
    |> element("button[phx-value-weekday=#{weekday}]")
    |> render()
    |> then(&Regex.run(~r/data-stance="([a-z]+)"/, &1))
    |> case do
      [_, stance] -> stance
      nil -> nil
    end
  end

  # Place names go through the templates, so `&` arrives as `&amp;`.
  defp escaped(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp signed_in(%{conn: conn}) do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> form("form[phx-submit=register]", name: "Jonas") |> render_submit()
    %{view: view}
  end
end
