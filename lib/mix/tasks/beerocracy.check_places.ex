defmodule Mix.Tasks.Beerocracy.CheckPlaces do
  @shortdoc "Validates priv/places.yml"

  @moduledoc """
  Parses the place catalogue and reports what it found.

  Adding a place is a pull request, so this runs in CI: a typo in the YAML fails
  the build with a message naming the entry, instead of surfacing as a crash
  after deploy.

      $ mix beerocracy.check_places
      $ mix beerocracy.check_places path/to/places.yml
  """

  use Mix.Task

  alias Beerocracy.Places
  alias Beerocracy.Places.Place
  alias Beerocracy.Places.Reach

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    path =
      case args do
        [path | _] -> path
        [] -> Places.path()
      end

    unless File.exists?(path) do
      Mix.raise("no catalogue at #{path}")
    end

    places =
      try do
        Places.load!(path)
      rescue
        error in Places.InvalidCatalogError -> Mix.raise(Exception.message(error))
      end

    Mix.shell().info("#{length(places)} places in #{Path.relative_to_cwd(path)}\n")

    for place <- places do
      Mix.shell().info([
        "  ",
        place.emoji,
        "  ",
        String.pad_trailing(place.name, 22),
        "beer #{stars(place.beer_rating)}  food #{stars(place.food_rating)}",
        "  office #{journey(place.office)} station #{journey(place.station)}",
        "  reach #{stars(Place.convenience(place))}"
      ])
    end

    Mix.shell().info("\nThe catalogue is valid.")
  end

  defp stars(rating), do: String.duplicate("*", rating) <> String.duplicate("·", 5 - rating)

  defp journey(reach) do
    {mode, minutes} = Reach.best(reach)
    String.pad_trailing("#{minutes}′ #{Reach.label(mode)}", 11)
  end
end
