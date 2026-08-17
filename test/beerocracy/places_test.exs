defmodule Beerocracy.PlacesTest do
  use ExUnit.Case, async: true

  alias Beerocracy.Places
  alias Beerocracy.Places.InvalidCatalogError
  alias Beerocracy.Places.Opening
  alias Beerocracy.Places.Place
  alias Beerocracy.Places.Reach

  @valid """
  places:
    - slug: hopfenkeller
      name: Hopfenkeller
      tagline: Vaulted cellar, twenty taps.
      emoji: 🍺
      accent: copper
      beer:
        rating: 5
        note: Twenty rotating taps.
      food:
        rating: 2
        note: Pretzels only.
      reach:
        office: 6
        station:
          walk: 9
          transit: 5
      tags:
        - taproom
      url: https://example.com/hk
  """

  describe "the shipped catalogue" do
    test "parses, and every place is complete" do
      places = Places.all()

      assert places != []

      for place <- places do
        assert %Place{} = place
        assert place.slug =~ ~r/^[a-z0-9-]+$/
        assert place.beer_rating in 0..5
        assert place.food_rating in 0..5
        assert place.beer_note != ""
        assert place.food_note != ""
      end
    end

    test "every place is open at some point in the drinking window" do
      # A place that silently fails this vanishes from the ballot with no error
      # anywhere, so it is worth asserting over the real catalogue.
      window = Beerocracy.Week.drinking_window()

      for place <- Places.all() do
        assert Opening.overlaps_window?(place.opening, window),
               "#{place.name} is never open during #{inspect(window)} — it would leave the ballot"
      end
    end

    test "every place can host at least one weekday this week" do
      week = Beerocracy.Week.current()

      assert length(Places.available(week)) == length(Places.all()),
             "a place dropped off this week's ballot: " <>
               inspect(
                 Enum.map(Places.all(), & &1.slug) -- Enum.map(Places.available(week), & &1.slug)
               )
    end

    test "fetch/1 finds a place by slug and misses cleanly" do
      slug = Places.all() |> hd() |> Map.fetch!(:slug)

      assert {:ok, %Place{slug: ^slug}} = Places.fetch(slug)
      assert :error = Places.fetch("no-such-pub")
    end

    test "filter/1 keeps catalogue order" do
      slugs = Places.all() |> Enum.map(& &1.slug) |> Enum.take(3)

      assert Places.filter(Enum.reverse(slugs)) |> Enum.map(& &1.slug) == slugs
    end
  end

  describe "load!/1" do
    test "reads every documented field" do
      assert [place] = load(@valid)

      assert %Place{
               slug: "hopfenkeller",
               name: "Hopfenkeller",
               tagline: "Vaulted cellar, twenty taps.",
               emoji: "🍺",
               accent: :copper,
               beer_rating: 5,
               food_rating: 2,
               office: %Reach{walk: 6, transit: nil},
               station: %Reach{walk: 9, transit: 5},
               tags: ["taproom"],
               url: "https://example.com/hk"
             } = place
    end

    test "strips the invisible characters that come with a pasted emoji" do
      assert [place] = load(String.replace(@valid, "emoji: 🍺", "emoji: \"🍺\\u200B\""))

      assert place.emoji == "🍺"
    end

    test "keeps the zero-width joiner that holds an emoji sequence together" do
      assert [place] = load(String.replace(@valid, "emoji: 🍺", "emoji: \"🏳️\\u200D🌈\""))

      assert place.emoji == "🏳️‍🌈"
    end

    test "defaults the optional fields" do
      assert [place] =
               load("""
               places:
                 - slug: bar
                   name: Bar
                   tagline: A bar.
                   beer: {rating: 3, note: Fine.}
                   food: {rating: 3, note: Fine.}
                   reach: {office: 1, station: 2}
               """)

      assert place.emoji == "🍺"
      assert place.accent == :amber
      assert place.tags == []
      assert place.url == nil
    end

    test "names the offending place when a field is missing" do
      assert_raise InvalidCatalogError, ~r/place #1 .*`tagline` is required/s, fn ->
        load("""
        places:
          - slug: bar
            name: Bar
            beer: {rating: 3, note: Fine.}
            food: {rating: 3, note: Fine.}
            reach: {office: 1, station: 2}
        """)
      end
    end

    test "rejects a rating above 5" do
      assert_raise InvalidCatalogError,
                   ~r/`beer.rating` must be a whole number from 0 \(none at all\) to 5/,
                   fn -> load(String.replace(@valid, "rating: 5", "rating: 9")) end
    end

    test "rejects a negative rating" do
      assert_raise InvalidCatalogError,
                   ~r/`beer.rating` must be a whole number/,
                   fn -> load(String.replace(@valid, "rating: 5", "rating: -1")) end
    end

    test "accepts 0, meaning there is none at all" do
      assert [place] = load(String.replace(@valid, "rating: 2", "rating: 0"))

      assert place.food_rating == 0
    end

    test "rejects an unknown accent" do
      assert_raise InvalidCatalogError, ~r/`accent` must be one of/, fn ->
        load(String.replace(@valid, "accent: copper", "accent: neon"))
      end
    end

    test "rejects a missing reach section rather than guessing" do
      assert_raise InvalidCatalogError, ~r/`reach.office` must be minutes on foot/, fn ->
        load(String.replace(@valid, "reach:", "stroll:"))
      end
    end

    test "rejects a destination with neither a walk nor a transit time" do
      assert_raise InvalidCatalogError,
                   ~r/`reach.station` needs a `walk:` time, a `transit:` time, or both/,
                   fn ->
                     load("""
                     places:
                       - slug: bar
                         name: Bar
                         tagline: A bar.
                         beer: {rating: 3, note: Fine.}
                         food: {rating: 3, note: Fine.}
                         reach:
                           office: 1
                           station: {}
                     """)
                   end
    end

    test "rejects a route that is not walking or transit" do
      assert_raise InvalidCatalogError, ~r/`reach.station` has no helicopter/, fn ->
        load(String.replace(@valid, "transit: 5", "helicopter: 2"))
      end
    end

    test "rejects duplicate slugs, which would merge two pubs' votes" do
      assert_raise InvalidCatalogError, ~r/duplicate slugs: hopfenkeller/, fn ->
        load(@valid <> String.replace(@valid, "places:\n", ""))
      end
    end

    test "rejects a file without a places list" do
      assert_raise InvalidCatalogError, ~r/must contain a top level `places:` key/, fn ->
        load("pubs: []")
      end
    end
  end

  describe "opening and season" do
    test "defaults to open all week, all year" do
      assert [place] = load(@valid)

      assert Opening.unrestricted?(place.opening)
      assert place.outdoor? == false
    end

    test "reads days, hours, season and the outdoor flag" do
      assert [place] =
               load("""
               places:
                 - slug: bar
                   name: Bar
                   tagline: A bar.
                   beer: {rating: 3, note: Fine.}
                   food: {rating: 3, note: Fine.}
                   reach: {office: 1, station: 2}
                   outdoor: true
                   open:
                     days: [thursday, friday]
                     from: "17:00"
                     to: "20:00"
                   season:
                     from: 2026-06-12
                     until: 2026-08-30
               """)

      assert Opening.days(place.opening) == [:thursday, :friday]
      assert place.opening.from == ~T[17:00:00]
      assert place.opening.to == ~T[20:00:00]
      assert place.opening.season_from == ~D[2026-06-12]
      assert place.opening.season_until == ~D[2026-08-30]
      assert place.outdoor?
    end

    test "accepts three letter weekday names, since this is hand-edited" do
      assert [place] = load(with_open("days: [mon, wed, fri]"))

      assert Opening.days(place.opening) == [:monday, :wednesday, :friday]
    end

    test "rejects something that is not a weekday" do
      assert_raise InvalidCatalogError, ~r/`caturday` is not a weekday/, fn ->
        load(with_open("days: [caturday]"))
      end
    end

    test "rejects a time it cannot read" do
      assert_raise InvalidCatalogError, ~r/`open.from` must be a time like/, fn ->
        load(with_open(~s(from: "half past five")))
      end
    end

    test "rejects a season date it cannot read" do
      assert_raise InvalidCatalogError, ~r/`season.until` must be a date like/, fn ->
        load(String.replace(@valid, "    tags:", "    season: {until: \"soon\"}\n    tags:"))
      end
    end

    test "rejects a non-boolean outdoor flag" do
      assert_raise InvalidCatalogError, ~r/`outdoor` must be true or false/, fn ->
        load(String.replace(@valid, "    tags:", "    outdoor: yes please\n    tags:"))
      end
    end
  end

  describe "reach" do
    test "a bare number is shorthand for walking" do
      assert [place] = load(String.replace(@valid, "office: 6", "office: 6"))
      assert place.office == %Reach{walk: 6, transit: nil}
    end

    test "takes a transit time on its own" do
      assert [place] =
               load("""
               places:
                 - slug: bar
                   name: Bar
                   tagline: A bar.
                   beer: {rating: 3, note: Fine.}
                   food: {rating: 3, note: Fine.}
                   reach:
                     office: {transit: 12}
                     station: {walk: 2}
               """)

      assert place.office == %Reach{walk: nil, transit: 12}
      assert Reach.best(place.office) == {:transit, 12}
      assert Reach.alternative(place.office) == nil
    end

    test "leads with whichever route is quicker" do
      {:ok, reach} = Reach.new(15, 6)

      assert Reach.best(reach) == {:transit, 6}
      assert Reach.alternative(reach) == {:walk, 15}
      assert Reach.minutes(reach) == 6
    end

    test "a tie goes to walking, since there is no connection to miss" do
      {:ok, reach} = Reach.new(8, 8)

      assert Reach.best(reach) == {:walk, 8}
    end

    test "needs at least one route" do
      assert Reach.new(nil, nil) == :error
    end
  end

  describe "convenience/1" do
    test "scores a place that is close to both the highest" do
      assert Place.convenience(place(1, 2)) == 5
    end

    test "scores a place that is far from both the lowest" do
      assert Place.convenience(place(25, 30)) == 1
    end

    test "weights the nearer of the two journeys more heavily" do
      assert Place.convenience(place(1, 18)) > Place.convenience(place(12, 14))
    end

    test "scores by the quicker route, so a tram ride counts" do
      long_walk = %{place(20, 4) | office: %Reach{walk: 20, transit: 3}}

      assert Place.convenience(long_walk) > Place.convenience(place(20, 4))
    end
  end

  defp with_open(lines) do
    String.replace(@valid, "    tags:", "    open:\n      #{lines}\n    tags:")
  end

  defp load(yaml) do
    path = Path.join(System.tmp_dir!(), "places-#{System.unique_integer([:positive])}.yml")
    File.write!(path, yaml)
    on_exit(fn -> File.rm(path) end)
    Places.load!(path)
  end

  defp place(office, station) do
    %Place{
      slug: "x",
      name: "X",
      tagline: "x",
      emoji: "🍺",
      accent: :amber,
      beer_rating: 3,
      beer_note: "x",
      food_rating: 3,
      food_note: "x",
      office: %Reach{walk: office, transit: nil},
      station: %Reach{walk: station, transit: nil},
      opening: Opening.always(),
      outdoor?: false,
      tags: [],
      url: nil
    }
  end
end
