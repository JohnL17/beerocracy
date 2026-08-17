defmodule Beerocracy.Weather.Source do
  @moduledoc """
  Where a forecast comes from.

  Behind a behaviour so the tests never touch the network, and so swapping the
  provider does not reach into the rest of the application.
  """

  alias Beerocracy.Weather.Forecast

  @doc "Daily forecasts covering `first`..`last` inclusive, in date order."
  @callback fetch(first :: Date.t(), last :: Date.t()) ::
              {:ok, [Forecast.t()]} | {:error, term()}
end
