defmodule Beerocracy.Places.Place do
  @moduledoc """
  A candidate establishment, as declared in `priv/places.yml`.
  """

  alias Beerocracy.Places.Opening
  alias Beerocracy.Places.Reach

  @enforce_keys [
    :slug,
    :name,
    :tagline,
    :emoji,
    :accent,
    :beer_rating,
    :beer_note,
    :food_rating,
    :food_note,
    :office,
    :station,
    :opening,
    :outdoor?,
    :tags,
    :url
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          slug: String.t(),
          name: String.t(),
          tagline: String.t(),
          emoji: String.t(),
          accent: atom(),
          beer_rating: 1..5,
          beer_note: String.t(),
          food_rating: 1..5,
          food_note: String.t(),
          office: Reach.t(),
          station: Reach.t(),
          opening: Opening.t(),
          outdoor?: boolean(),
          tags: [String.t()],
          url: String.t() | nil
        }

  @doc "Whether this place can host a beer on `date`, given the drinking window."
  @spec available_on?(t(), Date.t(), {0..23, 0..23}) :: boolean()
  def available_on?(%__MODULE__{opening: opening}, date, window \\ {16, 22}) do
    Opening.available?(opening, date, window)
  end

  @doc "Whether this place is usable on any weekday of `week`."
  @spec available_this_week?(t(), Beerocracy.Week.t(), {0..23, 0..23}) :: boolean()
  def available_this_week?(%__MODULE__{} = place, week, window \\ {16, 22}) do
    Enum.any?(Beerocracy.Week.weekdays(), fn weekday ->
      available_on?(place, Beerocracy.Week.date_of(week, weekday), window)
    end)
  end

  @doc """
  How reachable a place is overall, as a 1-5 score.

  Being a minute from the office and eighteen from the station is a different
  kind of convenient than the reverse, so we score the two journeys together and
  let the shorter one carry a little more weight. Each journey is scored by
  whichever route is quicker, walking or public transport.
  """
  @spec convenience(t()) :: 1..5
  def convenience(%__MODULE__{office: office, station: station}) do
    office = Reach.minutes(office)
    station = Reach.minutes(station)

    (score(min(office, station)) * 0.6 + score(max(office, station)) * 0.4)
    |> round()
    |> max(1)
    |> min(5)
  end

  defp score(minutes) when minutes <= 2, do: 5
  defp score(minutes) when minutes <= 5, do: 4
  defp score(minutes) when minutes <= 10, do: 3
  defp score(minutes) when minutes <= 15, do: 2
  defp score(_minutes), do: 1
end
