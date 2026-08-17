defmodule Beerocracy.Places.Reach do
  @moduledoc """
  How long it takes to get somewhere, on foot or by public transport.

  A place can declare either, or both. Where both are given the quicker one is
  what the card leads with — nobody walks fifteen minutes when the tram takes
  six — and the slower route is kept as the footnote.
  """

  @enforce_keys [:walk, :transit]
  defstruct [:walk, :transit]

  @type mode :: :walk | :transit
  @type t :: %__MODULE__{walk: non_neg_integer() | nil, transit: non_neg_integer() | nil}

  @doc "Builds a reach, guaranteeing at least one route is present."
  @spec new(non_neg_integer() | nil, non_neg_integer() | nil) :: {:ok, t()} | :error
  def new(nil, nil), do: :error
  def new(walk, transit), do: {:ok, %__MODULE__{walk: walk, transit: transit}}

  @doc "The quicker route, as `{mode, minutes}`."
  @spec best(t()) :: {mode(), non_neg_integer()}
  def best(%__MODULE__{walk: walk, transit: nil}), do: {:walk, walk}
  def best(%__MODULE__{walk: nil, transit: transit}), do: {:transit, transit}

  def best(%__MODULE__{walk: walk, transit: transit}) do
    # A tie goes to walking: no timetable, no connection to miss.
    if transit < walk, do: {:transit, transit}, else: {:walk, walk}
  end

  @doc "Minutes by the quicker route."
  @spec minutes(t()) :: non_neg_integer()
  def minutes(%__MODULE__{} = reach), do: reach |> best() |> elem(1)

  @doc "The route not taken, as `{mode, minutes}`, or `nil` if there is only one."
  @spec alternative(t()) :: {mode(), non_neg_integer()} | nil
  def alternative(%__MODULE__{walk: nil}), do: nil
  def alternative(%__MODULE__{transit: nil}), do: nil

  def alternative(%__MODULE__{walk: walk, transit: transit} = reach) do
    case best(reach) do
      {:walk, _} -> {:transit, transit}
      {:transit, _} -> {:walk, walk}
    end
  end

  @doc "How a mode is written on the card."
  @spec label(mode()) :: String.t()
  def label(:walk), do: "walk"
  def label(:transit), do: "transit"
end
