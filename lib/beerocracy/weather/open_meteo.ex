defmodule Beerocracy.Weather.OpenMeteo do
  @moduledoc """
  Forecasts from [Open-Meteo](https://open-meteo.com).

  Chosen because it needs no API key and no account: one fewer secret to
  configure, and nothing to expire quietly six months from now.

  Asks for hourly readings and folds each day's drinking window into one
  summary. The daily maximum would be cheaper to fetch and actively misleading —
  it is often set at three in the afternoon, hours before anybody sits down.
  """

  @behaviour Beerocracy.Weather.Source

  alias Beerocracy.Weather
  alias Beerocracy.Weather.Forecast

  @endpoint "https://api.open-meteo.com/v1/forecast"
  @fields ~w(weather_code temperature_2m precipitation_probability precipitation)

  @impl true
  def fetch(first, last) do
    config = Application.get_env(:beerocracy, :weather, [])

    params = [
      latitude: Keyword.get(config, :latitude, 46.948),
      longitude: Keyword.get(config, :longitude, 7.4474),
      # Local times, so "18:00" means six in the evening where the pub is.
      timezone: Keyword.get(config, :timezone, "Europe/Zurich"),
      hourly: Enum.join(@fields, ","),
      start_date: Date.to_iso8601(first),
      end_date: Date.to_iso8601(last)
    ]

    request =
      Req.new(
        url: @endpoint,
        params: params,
        receive_timeout: Keyword.get(config, :timeout, 8_000),
        retry: false
      )

    case Req.get(request) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse(body, Weather.window())

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Folds an Open-Meteo hourly payload into one forecast per day.

  Open-Meteo returns parallel arrays rather than a list of readings, and any
  measurement can be null, so hours missing a code or a temperature are dropped.
  A day with no usable hours in the window is left out entirely rather than
  rendered as blanks.
  """
  @spec parse(map(), {0..23, 0..23}) :: {:ok, [Forecast.t()]} | {:error, term()}
  def parse(body, window \\ {16, 22})

  def parse(%{"hourly" => hourly}, {from_hour, to_hour}) when is_map(hourly) do
    times = Map.get(hourly, "time", [])
    codes = Map.get(hourly, "weather_code", [])
    temps = Map.get(hourly, "temperature_2m", [])
    chances = Map.get(hourly, "precipitation_probability", [])
    millimetres = Map.get(hourly, "precipitation", [])

    forecasts =
      [times, codes, temps]
      |> Enum.zip()
      |> Enum.with_index()
      |> Enum.flat_map(fn {{time, code, temp}, index} ->
        case reading(
               time,
               code,
               temp,
               {Enum.at(chances, index), Enum.at(millimetres, index)},
               from_hour,
               to_hour
             ) do
          {:ok, reading} -> [reading]
          :skip -> []
        end
      end)
      |> Enum.group_by(& &1.date)
      |> Enum.map(fn {date, readings} -> summarise(date, readings, from_hour, to_hour) end)
      |> Enum.sort_by(& &1.date, Date)

    {:ok, forecasts}
  end

  def parse(_body, _window), do: {:error, :unexpected_payload}

  defp reading(time, code, temp, {chance, millimetres}, from_hour, to_hour)
       when is_binary(time) and is_integer(code) and is_number(temp) do
    with [date, clock] <- String.split(time, "T"),
         {:ok, date} <- Date.from_iso8601(date),
         hour when hour >= from_hour and hour <= to_hour <-
           clock |> String.slice(0, 2) |> String.to_integer() do
      {:ok,
       %{
         date: date,
         hour: hour,
         code: code,
         temp: temp,
         chance: if(is_integer(chance), do: chance),
         mm: if(is_number(millimetres), do: millimetres * 1.0, else: 0.0)
       }}
    else
      _outside_the_window -> :skip
    end
  end

  defp reading(_time, _code, _temp, _rain, _from, _to), do: :skip

  defp summarise(date, readings, from_hour, to_hour) do
    readings = Enum.sort_by(readings, & &1.hour)
    temps = Enum.map(readings, & &1.temp)

    # Kept hour by hour rather than collapsed to a range: the shape is the point,
    # and a percentage range is not a quantity anyone can reason about.
    rain =
      readings
      |> Enum.reject(&is_nil(&1.chance))
      |> Enum.map(&{&1.hour, &1.chance, &1.mm})

    %Forecast{
      date: date,
      from_hour: from_hour,
      to_hour: to_hour,
      # WMO codes climb roughly with severity, so the highest one in the window
      # is the thing worth warning about: an hour of thunderstorms matters more
      # than the five clear hours around it.
      code: readings |> Enum.map(& &1.code) |> Enum.max(),
      temp_min: Enum.min(temps),
      temp_max: Enum.max(temps),
      rain: rain
    }
  end
end
