defmodule Beerocracy.Weather do
  @moduledoc """
  Keeps a forecast for the current week to hand, so the ballot can show what the
  sky is doing above each weekday.

  The forecast is fetched on a slow timer and published to `:persistent_term`,
  which means rendering a page never waits on an HTTP request and a hundred open
  browsers cost exactly one call an hour. Weather is a nicety: if the fetch
  fails, or the box has no internet at all, the tiles simply go back to showing
  nothing and voting carries on.
  """

  use GenServer

  alias Beerocracy.Weather.Forecast
  alias Beerocracy.Week

  require Logger

  @cache {__MODULE__, :forecasts}
  @retry_after :timer.minutes(5)

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The window the forecast covers — the hours people are actually out.

  Summarising these rather than the whole day is the point: a day's high is
  usually set mid-afternoon and answers the wrong question.
  """
  @spec window() :: {0..23, 0..23}
  defdelegate window(), to: Week, as: :drinking_window

  @doc """
  The forecast for every day it knows about, keyed by date.

  Always returns a map — an empty one before the first fetch lands, or when the
  forecast is switched off.
  """
  @spec forecasts() :: %{Date.t() => Forecast.t()}
  def forecasts, do: :persistent_term.get(@cache, %{})

  @doc "The forecast for one day, or `nil` if it is not known."
  @spec for_date(Date.t()) :: Forecast.t() | nil
  def for_date(%Date{} = date), do: Map.get(forecasts(), date)

  @doc "Forecasts for the five weekdays of `week`, keyed by date."
  @spec for_week(Week.t()) :: %{Date.t() => Forecast.t()}
  def for_week(%Week{} = week) do
    known = forecasts()

    for weekday <- Week.weekdays(),
        date = Week.date_of(week, weekday),
        forecast = Map.get(known, date),
        into: %{},
        do: {date, forecast}
  end

  @doc "Fetches now rather than waiting for the timer. Used by tests."
  @spec refresh(timeout()) :: :ok | {:error, term()}
  def refresh(timeout \\ 10_000), do: GenServer.call(__MODULE__, :refresh, timeout)

  @doc false
  @spec put(%{Date.t() => Forecast.t()}) :: :ok
  def put(forecasts), do: :persistent_term.put(@cache, forecasts)

  @doc false
  @spec clear() :: :ok
  def clear do
    :persistent_term.erase(@cache)
    :ok
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:beerocracy, :weather, [])

    state = %{
      source: Keyword.get(config, :source, Beerocracy.Weather.OpenMeteo),
      refresh_every: Keyword.get(config, :refresh_every, :timer.hours(1)),
      enabled?: Keyword.get(config, :enabled, true) and not Keyword.get(opts, :disabled, false)
    }

    if state.enabled?, do: send(self(), :refresh)

    {:ok, state}
  end

  # An explicit call is a deliberate request, so it fetches even when the
  # automatic polling is switched off — that is what `enabled: false` governs.
  @impl true
  def handle_call(:refresh, _from, state) do
    {:reply, fetch_and_publish(state), state}
  end

  @impl true
  def handle_info(:refresh, state) do
    delay =
      case fetch_and_publish(state) do
        :ok -> state.refresh_every
        # A blip should not mean an empty sky until the next hour is up.
        {:error, _reason} -> min(@retry_after, state.refresh_every)
      end

    Process.send_after(self(), :refresh, delay)
    {:noreply, state}
  end

  defp fetch_and_publish(state) do
    week = Week.current()
    # A little either side of the working week, so the tiles are still right if
    # the box was asleep over the weekend.
    first = Date.add(week.monday, -1)
    last = Date.add(week.sunday, 1)

    case state.source.fetch(first, last) do
      {:ok, forecasts} ->
        put(Map.new(forecasts, &{&1.date, &1}))
        :ok

      {:error, reason} ->
        Logger.warning("could not fetch the forecast: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
