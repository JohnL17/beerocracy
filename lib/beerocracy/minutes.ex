defmodule Beerocracy.Minutes do
  @moduledoc """
  What actually happened, as opposed to what was agreed.

  Everywhere else in the Beerocracy is derived from votes and nothing else,
  which is what makes the archive free — no attendance to take, nothing to keep
  up to date. This is the one deliberate exception: a place the votes cannot
  know about, because whether we actually turned up is not something anybody
  voted on.

  Kept small on purpose. An entry is only ever an override, so a week without
  one behaves exactly as it did before this module existed.

  A week can hold several. An evening rarely stays in one pub, and a week that
  went out twice is still one week — so the minutes are a list of stops, in the
  order the week happened, rather than a single answer.
  """

  use Ash.Domain, otp_app: :beerocracy

  alias Beerocracy.Minutes.Entry
  alias Beerocracy.Week

  resources do
    resource Beerocracy.Minutes.Entry do
      define :record_entry, action: :record
      # Most weeks have no entry at all, so an empty list is an answer, not an error.
      define :entries_for_week, action: :for_week, args: [:week_key]
      define :all_entries, action: :read
      define :delete_entry, action: :destroy
    end
  end

  @doc """
  Writes down one stop.

  Adds to the week rather than replacing it, so a crawl is recorded a pub at a
  time. Writing the same place down again on the same night is a correction,
  not a second round.
  """
  @spec record(Week.t(), atom(), String.t(), String.t()) :: {:ok, Entry.t()} | {:error, term()}
  def record(%Week{} = week, weekday, place_slug, recorded_by) do
    record_entry(%{
      week_key: week.key,
      weekday: weekday,
      place_slug: place_slug,
      recorded_by: recorded_by
    })
  end

  @doc """
  Rubs out a whole week's minutes, handing it back to the vote.

  Returns `:ok` whether or not there was anything written down, because "there
  is no override on this week" is the desired end state either way.
  """
  @spec forget(Week.t()) :: :ok
  def forget(%Week{} = week) do
    week |> for_week() |> Enum.each(&delete_entry!/1)

    :ok
  end

  @doc """
  Rubs out one stop, leaving the rest of the night written down.

  What this is for is the pub that got added by mistake, or the round nobody
  actually stayed for — striking it should not take the rest of the evening
  with it.
  """
  @spec forget_stop(Week.t(), atom(), String.t()) :: :ok
  def forget_stop(%Week{} = week, weekday, place_slug) do
    week
    |> for_week()
    |> Enum.filter(&(&1.weekday == weekday and &1.place_slug == place_slug))
    |> Enum.each(&delete_entry!/1)

    :ok
  end

  @doc "Every stop written down for one week, in the order the week happened."
  @spec for_week(Week.t() | String.t()) :: [Entry.t()]
  def for_week(%Week{key: key}), do: for_week(key)

  def for_week(week_key) when is_binary(week_key),
    do: week_key |> entries_for_week!() |> in_order()

  @doc "Every stop, grouped by week and in order within it."
  @spec by_week() :: %{String.t() => [Entry.t()]}
  def by_week do
    all_entries!()
    |> Enum.group_by(& &1.week_key)
    |> Map.new(fn {week_key, entries} -> {week_key, in_order(entries)} end)
  end

  # The night, then the round: entries sort by weekday first, and within a
  # weekday by when they were written down, which is the order they were drunk
  # in as long as somebody wrote them down as they went.
  defp in_order(entries) do
    Enum.sort_by(entries, &{weekday_index(&1.weekday), &1.inserted_at})
  end

  defp weekday_index(weekday), do: Enum.find_index(Week.weekdays(), &(&1 == weekday))
end
