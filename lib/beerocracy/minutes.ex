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
  """

  use Ash.Domain, otp_app: :beerocracy

  alias Beerocracy.Minutes.Entry
  alias Beerocracy.Week

  resources do
    resource Beerocracy.Minutes.Entry do
      define :record_entry, action: :record
      # Most weeks have no entry at all, so absence is an answer, not an error.
      define :entry_for_week, action: :for_week, args: [:week_key], not_found_error?: false
      define :all_entries, action: :read
      define :delete_entry, action: :destroy
    end
  end

  @doc "Records where we went in a week, correcting any earlier answer."
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
  Rubs out a week's entry, handing it back to the vote.

  Returns `:ok` whether or not there was one, because "there is no override on
  this week" is the desired end state either way.
  """
  @spec forget(Week.t()) :: :ok
  def forget(%Week{} = week) do
    case for_week(week) do
      nil -> :ok
      entry -> delete_entry!(entry)
    end

    :ok
  end

  @doc "The entry for one week, or `nil`."
  @spec for_week(Week.t() | String.t()) :: Entry.t() | nil
  def for_week(%Week{key: key}), do: for_week(key)
  def for_week(week_key) when is_binary(week_key), do: entry_for_week!(week_key)

  @doc "Every entry, keyed by week."
  @spec by_week() :: %{String.t() => Entry.t()}
  def by_week, do: Map.new(all_entries!(), &{&1.week_key, &1})
end
