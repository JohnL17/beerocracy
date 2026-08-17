defmodule Beerocracy.Places do
  @moduledoc """
  Reads the candidate places out of `priv/places.yml`.

  The catalogue deliberately lives in a file rather than the database: adding a
  pub should be a pull request that anyone can review, not a row someone has to
  insert in production. Votes reference a place by its `slug`.

  The file is parsed on demand and cached in `:persistent_term`, keyed on the
  file's mtime — so editing the YAML takes effect without a restart, while
  repeated reads stay free.
  """

  alias Beerocracy.Places.Opening
  alias Beerocracy.Places.Place
  alias Beerocracy.Places.Reach

  defmodule InvalidCatalogError do
    defexception [:message]
  end

  @accents ~w(amber copper gold rust moss plum slate)a
  @default_accent :amber
  @default_emoji "🍺"

  @doc """
  All places in catalogue order.

  Raises `InvalidCatalogError` if the YAML is malformed — a broken catalogue is
  a broken deploy, and we would rather find out loudly at the first request than
  silently drop somebody's favourite bar.
  """
  @spec all() :: [Place.t()]
  def all do
    path = path()
    stamp = stamp(path)

    case :persistent_term.get({__MODULE__, :cache}, nil) do
      {^path, ^stamp, places} ->
        places

      _ ->
        places = load!(path)
        :persistent_term.put({__MODULE__, :cache}, {path, stamp, places})
        places
    end
  end

  @doc "Look up a single place by slug."
  @spec fetch(String.t()) :: {:ok, Place.t()} | :error
  def fetch(slug) do
    case Enum.find(all(), &(&1.slug == slug)) do
      nil -> :error
      place -> {:ok, place}
    end
  end

  @doc """
  Places that can host a beer on at least one weekday of `week`.

  This is what the ballot votes on. A summer pop-up whose season has ended, or a
  place whose opening hours miss the drinking window entirely, drops off the
  deck by itself rather than waiting for somebody to remember to delete it.
  """
  @spec available(Beerocracy.Week.t(), {0..23, 0..23}) :: [Place.t()]
  def available(week, window \\ {16, 22}) do
    Enum.filter(all(), &Place.available_this_week?(&1, week, window))
  end

  @doc "Places whose slug is in `slugs`, in catalogue order."
  @spec filter(Enumerable.t()) :: [Place.t()]
  def filter(slugs) do
    slugs = MapSet.new(slugs)
    Enum.filter(all(), &MapSet.member?(slugs, &1.slug))
  end

  @doc "Absolute path of the catalogue file currently in use."
  @spec path() :: String.t()
  def path do
    case System.get_env("PLACES_FILE") do
      nil ->
        :beerocracy
        |> Application.app_dir("priv")
        |> Path.join(Application.get_env(:beerocracy, :places_file, "places.yml"))

      override ->
        override
    end
  end

  @doc """
  The catalogue on GitHub, for reading.

  Returns `nil` when no repository is configured, so the interface can simply
  leave the link out rather than offering a broken one.
  """
  @spec source_url() :: String.t() | nil
  def source_url, do: github_url("blob")

  @doc """
  The catalogue open in GitHub's editor.

  For anyone without write access GitHub turns this into a fork-and-pull-request
  flow, which is exactly the route a new place is supposed to take.
  """
  @spec edit_url() :: String.t() | nil
  def edit_url, do: github_url("edit")

  defp github_url(action) do
    case Application.get_env(:beerocracy, :repo_url) do
      nil ->
        nil

      repo ->
        branch = Application.get_env(:beerocracy, :repo_branch, "main")
        file = Application.get_env(:beerocracy, :places_file, "places.yml")
        "#{String.trim_trailing(repo, "/")}/#{action}/#{branch}/priv/#{file}"
    end
  end

  @doc "Drops the cached catalogue. Only needed in tests."
  @spec reset_cache() :: :ok
  def reset_cache do
    :persistent_term.erase({__MODULE__, :cache})
    :ok
  end

  @doc false
  @spec load!(String.t()) :: [Place.t()]
  def load!(path) do
    parsed =
      case YamlElixir.read_from_file(path) do
        {:ok, parsed} ->
          parsed

        {:error, error} ->
          raise InvalidCatalogError, "could not parse #{path}: #{Exception.message(error)}"
      end

    entries =
      case parsed do
        %{"places" => entries} when is_list(entries) ->
          entries

        _ ->
          raise InvalidCatalogError,
                "#{path} must contain a top level `places:` key holding a list of places"
      end

    places = Enum.with_index(entries, &build!(&1, &2, path))

    case duplicate_slugs(places) do
      [] -> places
      dupes -> raise InvalidCatalogError, "#{path} has duplicate slugs: #{Enum.join(dupes, ", ")}"
    end
  end

  defp build!(entry, index, path) when is_map(entry) do
    where = "place ##{index + 1} in #{path}"

    %Place{
      slug: required_string!(entry, "slug", where),
      name: required_string!(entry, "name", where),
      tagline: required_string!(entry, "tagline", where),
      emoji: optional_string(entry, "emoji") || @default_emoji,
      accent: accent!(entry, where),
      beer_rating: rating!(entry, "beer", where),
      beer_note: note!(entry, "beer", where),
      food_rating: rating!(entry, "food", where),
      food_note: note!(entry, "food", where),
      office: reach!(entry, "office", where),
      station: reach!(entry, "station", where),
      opening: opening!(entry, where),
      outdoor?: boolean!(entry, "outdoor", where),
      tags: tags!(entry, where),
      url: optional_string(entry, "url")
    }
  end

  defp build!(_entry, index, path) do
    raise InvalidCatalogError, "place ##{index + 1} in #{path} must be a mapping"
  end

  defp required_string!(entry, key, where) do
    case entry[key] do
      value when is_binary(value) ->
        case clean(value) do
          "" -> raise InvalidCatalogError, "#{where}: `#{key}` must not be blank"
          trimmed -> trimmed
        end

      nil ->
        raise InvalidCatalogError, "#{where}: `#{key}` is required"

      other ->
        raise InvalidCatalogError, "#{where}: `#{key}` must be text, got #{inspect(other)}"
    end
  end

  defp optional_string(entry, key) do
    case entry[key] do
      value when is_binary(value) ->
        case clean(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  # Emoji and names get pasted in from web pages, which drags along invisible
  # zero-width characters. Strip those, but never the zero-width joiner — it is
  # what holds sequences like 🏳️‍🌈 together.
  defp clean(value) do
    value
    |> String.replace(["\u200B", "\u200C", "\uFEFF"], "")
    |> String.trim()
  end

  defp accent!(entry, where) do
    case entry["accent"] do
      nil ->
        @default_accent

      value when is_binary(value) ->
        accent = value |> clean() |> String.downcase()

        Enum.find(@accents, &(Atom.to_string(&1) == accent)) ||
          raise InvalidCatalogError,
                "#{where}: `accent` must be one of #{Enum.map_join(@accents, ", ", &to_string/1)}"

      other ->
        raise InvalidCatalogError, "#{where}: `accent` must be text, got #{inspect(other)}"
    end
  end

  # 0 is not "terrible", it is "there is none" — a pub with no kitchen is a
  # different thing from a pub with a bad one, and the card says so.
  defp rating!(entry, section, where) do
    case dig(entry, section, "rating") do
      rating when is_integer(rating) and rating >= 0 and rating <= 5 ->
        rating

      other ->
        raise InvalidCatalogError,
              "#{where}: `#{section}.rating` must be a whole number from 0 (none at all) " <>
                "to 5, got #{inspect(other)}"
    end
  end

  defp note!(entry, section, where) do
    case dig(entry, section, "note") do
      note when is_binary(note) ->
        clean(note)

      other ->
        raise InvalidCatalogError,
              "#{where}: `#{section}.note` must be text, got #{inspect(other)}"
    end
  end

  # `reach.office` and `reach.station` each take a walk time, a transit time, or
  # both. A bare number is the shorthand for walking, since that is the common
  # case and `office: 5` reads better than spelling it out.
  defp reach!(entry, key, where) do
    routes =
      case dig(entry, "reach", key) do
        minutes when is_integer(minutes) ->
          %{"walk" => minutes}

        %{} = routes ->
          routes

        other ->
          raise InvalidCatalogError,
                "#{where}: `reach.#{key}` must be minutes on foot, or a `walk:`/`transit:` " <>
                  "mapping, got #{inspect(other)}"
      end

    case unknown_routes(routes) do
      [] ->
        :ok

      keys ->
        raise InvalidCatalogError, "#{where}: `reach.#{key}` has no #{Enum.join(keys, ", ")}"
    end

    walk = route_minutes!(routes, "walk", key, where)
    transit = route_minutes!(routes, "transit", key, where)

    case Reach.new(walk, transit) do
      {:ok, reach} ->
        reach

      :error ->
        raise InvalidCatalogError,
              "#{where}: `reach.#{key}` needs a `walk:` time, a `transit:` time, or both"
    end
  end

  defp route_minutes!(routes, mode, key, where) do
    case routes[mode] do
      nil ->
        nil

      minutes when is_integer(minutes) and minutes >= 0 ->
        minutes

      other ->
        raise InvalidCatalogError,
              "#{where}: `reach.#{key}.#{mode}` must be whole minutes, got #{inspect(other)}"
    end
  end

  defp unknown_routes(routes) do
    routes |> Map.keys() |> Enum.reject(&(&1 in ["walk", "transit"]))
  end

  @weekdays [
    {"monday", :monday},
    {"tuesday", :tuesday},
    {"wednesday", :wednesday},
    {"thursday", :thursday},
    {"friday", :friday},
    {"saturday", :saturday},
    {"sunday", :sunday}
  ]

  # Everything about opening is optional; a place that says nothing is open all
  # week, all year, which is true of most pubs.
  defp opening!(entry, where) do
    open = section(entry, "open")
    season = section(entry, "season")

    %Opening{
      days: opening_days!(open, where),
      from: time!(open, "from", where),
      to: time!(open, "to", where),
      season_from: date!(season, "from", where),
      season_until: date!(season, "until", where)
    }
  end

  defp opening_days!(open, where) do
    case open["days"] do
      nil ->
        nil

      days when is_list(days) ->
        days
        |> Enum.map(&weekday!(&1, where))
        |> MapSet.new()

      other ->
        raise InvalidCatalogError,
              "#{where}: `open.days` must be a list of weekday names, got #{inspect(other)}"
    end
  end

  defp weekday!(value, where) when is_binary(value) do
    name = value |> clean() |> String.downcase()

    Enum.find_value(@weekdays, fn {full, weekday} ->
      # Accept "thu" as readily as "thursday" — this is a hand-edited file.
      if name == full or name == String.slice(full, 0, 3), do: weekday
    end) ||
      raise(InvalidCatalogError, "#{where}: `#{value}` is not a weekday")
  end

  defp weekday!(other, where) do
    raise InvalidCatalogError, "#{where}: a weekday must be text, got #{inspect(other)}"
  end

  defp time!(section, key, where) do
    case section[key] do
      nil ->
        nil

      value when is_binary(value) ->
        case value |> clean() |> String.split(":") do
          [hour] -> build_time!(hour, "0", value, key, where)
          [hour, minute | _rest] -> build_time!(hour, minute, value, key, where)
        end

      other ->
        raise InvalidCatalogError,
              "#{where}: `open.#{key}` must be a time like \"17:00\", got #{inspect(other)}"
    end
  end

  defp build_time!(hour, minute, original, key, where) do
    with {hour, ""} <- Integer.parse(hour),
         {minute, ""} <- Integer.parse(minute),
         {:ok, time} <- Time.new(hour, minute, 0) do
      time
    else
      _invalid ->
        raise InvalidCatalogError,
              "#{where}: `open.#{key}` must be a time like \"17:00\", got #{inspect(original)}"
    end
  end

  defp date!(section, key, where) do
    case section[key] do
      nil ->
        nil

      %Date{} = date ->
        date

      value when is_binary(value) ->
        case Date.from_iso8601(clean(value)) do
          {:ok, date} ->
            date

          {:error, _reason} ->
            raise InvalidCatalogError,
                  "#{where}: `season.#{key}` must be a date like 2026-08-30, got #{inspect(value)}"
        end

      other ->
        raise InvalidCatalogError,
              "#{where}: `season.#{key}` must be a date like 2026-08-30, got #{inspect(other)}"
    end
  end

  defp boolean!(entry, key, where) do
    case entry[key] do
      nil ->
        false

      value when is_boolean(value) ->
        value

      other ->
        raise InvalidCatalogError,
              "#{where}: `#{key}` must be true or false, got #{inspect(other)}"
    end
  end

  defp section(entry, key) do
    case entry[key] do
      map when is_map(map) -> map
      _absent -> %{}
    end
  end

  defp tags!(entry, where) do
    case entry["tags"] do
      nil ->
        []

      tags when is_list(tags) ->
        Enum.map(tags, fn
          tag when is_binary(tag) ->
            clean(tag)

          other ->
            raise InvalidCatalogError, "#{where}: every tag must be text, got #{inspect(other)}"
        end)

      other ->
        raise InvalidCatalogError, "#{where}: `tags` must be a list, got #{inspect(other)}"
    end
  end

  defp duplicate_slugs(places) do
    places
    |> Enum.frequencies_by(& &1.slug)
    |> Enum.filter(fn {_slug, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
  end

  # A missing or malformed section should read as "no value" here, so that the
  # caller can raise the message describing what it actually wanted.
  defp dig(entry, section, key) do
    case entry[section] do
      nil -> nil
      map when is_map(map) -> map[key]
      _ -> nil
    end
  end

  defp stamp(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime, size: size}} -> {mtime, size}
      {:error, reason} -> {:error, reason}
    end
  end
end
