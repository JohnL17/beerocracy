defmodule Beerocracy.WeatherStub do
  @moduledoc """
  A forecast source for the tests. Never touches the network.

  Returns a deterministic outlook for every day in the requested range, cycling
  through a handful of weather codes so the tiles have something to render.
  """

  @behaviour Beerocracy.Weather.Source

  alias Beerocracy.Weather.Forecast

  # Clear, partly cloudy, rain, thunderstorm, snow.
  @codes [0, 2, 61, 95, 71]

  @impl true
  def fetch(first, last) do
    forecasts =
      first
      |> Date.range(last)
      |> Enum.with_index()
      |> Enum.map(fn {date, index} ->
        {from_hour, to_hour} = Beerocracy.Weather.window()

        %Forecast{
          date: date,
          from_hour: from_hour,
          to_hour: to_hour,
          code: Enum.at(@codes, rem(index, length(@codes))),
          temp_min: 16 + index,
          temp_max: 20 + index,
          rain:
            for(
              hour <- from_hour..to_hour,
              do: {hour, rem((hour - from_hour) * 13 + index * 7, 101)}
            )
        }
      end)

    {:ok, forecasts}
  end
end
