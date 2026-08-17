defmodule Beerocracy.Places.Opening do
  @moduledoc """
  When a place is actually open.

  Without this the ballot is confidently wrong: it will happily elect a brewery
  window that only opens on Thursdays for a Tuesday, or a summer pop-up in
  November. Everything here is optional — a place that says nothing is assumed
  to be open every weekday, all year, which is true of most pubs.
  """

  alias Beerocracy.Week

  defstruct days: nil, from: nil, to: nil, season_from: nil, season_until: nil

  @type t :: %__MODULE__{
          days: MapSet.t() | nil,
          from: Time.t() | nil,
          to: Time.t() | nil,
          season_from: Date.t() | nil,
          season_until: Date.t() | nil
        }

  @doc "An opening with no restrictions at all."
  @spec always() :: t()
  def always, do: %__MODULE__{}

  @doc """
  Whether the opening actually rules anything out for a weekday drinker.

  Ordinary pub hours are information; a place that shuts on Mondays or vanishes
  at the end of the month is a constraint, and the two should not look alike.
  """
  @spec restrictive?(t(), Date.t()) :: boolean()
  def restrictive?(%__MODULE__{} = opening, today \\ Date.utc_today()) do
    not is_nil(opening.days) or
      (not is_nil(opening.season_until) and days_left(opening, today) <= 21) or
      upcoming?(opening, today)
  end

  @doc "True when nothing about this place is restricted."
  @spec unrestricted?(t()) :: boolean()
  def unrestricted?(%__MODULE__{
        days: nil,
        from: nil,
        to: nil,
        season_from: nil,
        season_until: nil
      }),
      do: true

  def unrestricted?(%__MODULE__{}), do: false

  @doc "The weekdays this place opens, in MO-FR order."
  @spec days(t()) :: [atom()]
  def days(%__MODULE__{days: nil}), do: Week.weekdays()
  def days(%__MODULE__{days: days}), do: Enum.filter(Week.weekdays(), &MapSet.member?(days, &1))

  @doc """
  Whether the place is open on `date`, ignoring the time of day.

  A date outside the season fails, and so does a weekday it does not open on.
  """
  @spec open_on?(t(), Date.t()) :: boolean()
  def open_on?(%__MODULE__{} = opening, %Date{} = date) do
    in_season?(opening, date) and opens_on_weekday?(opening, date)
  end

  @doc "Whether the place is within its season on `date`."
  @spec in_season?(t(), Date.t()) :: boolean()
  def in_season?(%__MODULE__{season_from: from, season_until: until}, %Date{} = date) do
    (is_nil(from) or Date.compare(date, from) != :lt) and
      (is_nil(until) or Date.compare(date, until) != :gt)
  end

  @doc """
  Whether the opening hours overlap the drinking window at all.

  A place that shuts at two in the afternoon is no use for a beer at six, even
  though it is open that day.
  """
  @spec overlaps_window?(t(), {0..23, 0..23}) :: boolean()
  def overlaps_window?(%__MODULE__{from: nil, to: nil}, _window), do: true

  def overlaps_window?(%__MODULE__{from: from, to: to}, {window_from, window_to}) do
    opens = if from, do: from.hour, else: 0
    # An hour of `to` means last orders, so a place open "to 20:00" is still
    # usable by someone arriving at 19:00 — hence the strict comparisons.
    opens < window_to and closing_hour(from, to) > window_from
  end

  # Pubs close after midnight. Read naively, "to 00:30" is half past midnight
  # *this* morning, which puts closing time before opening time and would drop
  # the place off the ballot entirely — so a closing time at or before opening
  # has plainly wrapped into the next day.
  defp closing_hour(_from, nil), do: 24
  defp closing_hour(nil, to), do: to.hour

  defp closing_hour(from, to) do
    if Time.compare(to, from) == :gt, do: to.hour, else: to.hour + 24
  end

  @doc """
  Whether the place can host a beer on `date` given the drinking `window`.
  """
  @spec available?(t(), Date.t(), {0..23, 0..23}) :: boolean()
  def available?(%__MODULE__{} = opening, %Date{} = date, window) do
    open_on?(opening, date) and overlaps_window?(opening, window)
  end

  @doc """
  The season has been and gone as of `date`.

  Distinguished from "not yet started" so the interface can say which.
  """
  @spec over?(t(), Date.t()) :: boolean()
  def over?(%__MODULE__{season_until: nil}, _date), do: false
  def over?(%__MODULE__{season_until: until}, date), do: Date.compare(date, until) == :gt

  @doc "The season has not started yet as of `date`."
  @spec upcoming?(t(), Date.t()) :: boolean()
  def upcoming?(%__MODULE__{season_from: nil}, _date), do: false
  def upcoming?(%__MODULE__{season_from: from}, date), do: Date.compare(date, from) == :lt

  @doc """
  Days remaining in the season, or `nil` when it does not end.

  Used to nudge people towards a place before it disappears for the year.
  """
  @spec days_left(t(), Date.t()) :: non_neg_integer() | nil
  def days_left(%__MODULE__{season_until: nil}, _date), do: nil
  def days_left(%__MODULE__{season_until: until}, date), do: max(Date.diff(until, date), 0)

  @doc """
  The restriction in words, or `nil` when there is nothing to say.

  ## Examples

      iex> alias Beerocracy.Places.Opening
      iex> Opening.describe(%Opening{days: MapSet.new([:thursday, :friday]),
      ...>   from: ~T[17:00:00], to: ~T[20:00:00]})
      "Thursdays and Fridays, 17:00 - 20:00"
  """
  @spec describe(t()) :: String.t() | nil
  def describe(%__MODULE__{} = opening) do
    [day_phrase(opening), hour_phrase(opening), season_phrase(opening)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, ", ")
    end
  end

  defp opens_on_weekday?(%__MODULE__{days: nil}, _date), do: true

  defp opens_on_weekday?(%__MODULE__{days: days}, date) do
    MapSet.member?(days, weekday_of(date))
  end

  defp weekday_of(date) do
    Enum.at(
      [:monday, :tuesday, :wednesday, :thursday, :friday, :saturday, :sunday],
      Date.day_of_week(date) - 1
    )
  end

  defp day_phrase(%__MODULE__{days: nil}), do: nil

  defp day_phrase(%__MODULE__{} = opening) do
    case Enum.map(days(opening), &Week.label/1) do
      [] -> "Never on a weekday"
      [only] -> "#{only}s only"
      names -> names |> Enum.map(&(&1 <> "s")) |> to_sentence()
    end
  end

  defp hour_phrase(%__MODULE__{from: nil, to: nil}), do: nil
  defp hour_phrase(%__MODULE__{from: from, to: nil}), do: "from #{clock(from)}"
  defp hour_phrase(%__MODULE__{from: nil, to: to}), do: "until #{clock(to)}"
  defp hour_phrase(%__MODULE__{from: from, to: to}), do: "#{clock(from)} - #{clock(to)}"

  defp season_phrase(%__MODULE__{season_from: nil, season_until: nil}), do: nil
  defp season_phrase(%__MODULE__{season_from: from, season_until: nil}), do: "from #{date(from)}"

  defp season_phrase(%__MODULE__{season_from: nil, season_until: until}),
    do: "until #{date(until)}"

  defp season_phrase(%__MODULE__{season_from: from, season_until: until}),
    do: "#{date(from)} to #{date(until)}"

  defp to_sentence([a, b]), do: "#{a} and #{b}"

  defp to_sentence(names) do
    {rest, [last]} = Enum.split(names, -1)
    "#{Enum.join(rest, ", ")} and #{last}"
  end

  defp clock(time), do: Calendar.strftime(time, "%H:%M")
  defp date(value), do: Calendar.strftime(value, "%-d %b")
end
