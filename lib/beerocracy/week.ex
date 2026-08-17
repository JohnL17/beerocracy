defmodule Beerocracy.Week do
  @moduledoc """
  The heartbeat of the Beerocracy: every ballot belongs to exactly one ISO week.

  Votes are never deleted when a week ends — they are simply scoped by a
  `week_key` such as `"2026-W34"`, so a new week starts with an empty tally
  while the past stays browsable.
  """

  @enforce_keys [:year, :week, :key, :monday, :sunday]
  defstruct [:year, :week, :key, :monday, :sunday]

  @type t :: %__MODULE__{
          year: pos_integer(),
          week: pos_integer(),
          key: String.t(),
          monday: Date.t(),
          sunday: Date.t()
        }

  @weekdays [:monday, :tuesday, :wednesday, :thursday, :friday]

  @doc """
  The hours a beer actually happens in, as `{from, to}` in local time.

  Shared by the forecast — which summarises exactly these hours — and by the
  catalogue, which uses them to decide whether a place is open late enough to
  be any use.
  """
  @spec drinking_window() :: {0..23, 0..23}
  def drinking_window do
    config = Application.get_env(:beerocracy, :drinking_window, [])
    {Keyword.get(config, :from, 16), Keyword.get(config, :to, 22)}
  end

  @doc "The five candidate weekdays, MO through FR."
  @spec weekdays() :: [atom()]
  def weekdays, do: @weekdays

  @doc "Two letter label used on the weekday buttons."
  @spec short_label(atom()) :: String.t()
  def short_label(:monday), do: "MO"
  def short_label(:tuesday), do: "TU"
  def short_label(:wednesday), do: "WE"
  def short_label(:thursday), do: "TH"
  def short_label(:friday), do: "FR"

  @doc "Full weekday name, e.g. `\"Wednesday\"`."
  @spec label(atom()) :: String.t()
  def label(weekday) do
    weekday |> Atom.to_string() |> String.capitalize()
  end

  @doc "The week that today falls into."
  @spec current(Date.t()) :: t()
  def current(today \\ Date.utc_today()) do
    from_date(today)
  end

  @doc "The week that `date` falls into."
  @spec from_date(Date.t()) :: t()
  def from_date(date) do
    {year, week} = :calendar.iso_week_number(Date.to_erl(date))
    monday = Date.add(date, 1 - Date.day_of_week(date))

    %__MODULE__{
      year: year,
      week: week,
      key: key(year, week),
      monday: monday,
      sunday: Date.add(monday, 6)
    }
  end

  @doc "The date a weekday falls on within the given week."
  @spec date_of(t(), atom()) :: Date.t()
  def date_of(%__MODULE__{monday: monday}, weekday) do
    Date.add(monday, Enum.find_index(@weekdays, &(&1 == weekday)) || 0)
  end

  @doc "Seconds remaining until this week's ballot closes and the tally resets."
  @spec seconds_until_reset(t(), DateTime.t()) :: non_neg_integer()
  def seconds_until_reset(%__MODULE__{sunday: sunday}, now \\ DateTime.utc_now()) do
    next_monday = sunday |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    max(DateTime.diff(next_monday, now), 0)
  end

  defp key(year, week), do: "#{year}-W#{String.pad_leading(to_string(week), 2, "0")}"
end
