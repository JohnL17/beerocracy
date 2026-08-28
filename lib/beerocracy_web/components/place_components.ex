defmodule BeerocracyWeb.PlaceComponents do
  @moduledoc """
  The bits of a place that look the same wherever it is printed.

  A place appears twice in the app — as a card on the ballot deck and as an
  entry in the register — and the two must never disagree about how many pips
  the beer gets or which route is quicker.
  """

  use Phoenix.Component

  alias Beerocracy.Places
  alias Beerocracy.Places.Opening
  alias Beerocracy.Places.Reach
  alias Beerocracy.Week

  @doc """
  The catalogue's filename, linked to the file on GitHub.

  Falls back to plain text when no repository is configured, rather than
  offering a link that goes nowhere.

  ## Examples

      <.catalogue_link>priv/places.yml</.catalogue_link>
  """
  slot :inner_block, required: true

  def catalogue_link(assigns) do
    assigns = assign(assigns, url: Places.source_url())

    ~H"""
    <%!-- The underline sits on the code, not the anchor, so reflowing the markup
          can never leave a stray underlined space beside the filename. --%>
    <a :if={@url} href={@url} target="_blank" rel="noopener noreferrer">
      <code class="data font-bold underline underline-offset-2 hover:text-oxide">
        {render_slot(@inner_block)}
      </code>
    </a>
    <code :if={is_nil(@url)} class="data font-bold">{render_slot(@inner_block)}</code>
    """
  end

  @doc """
  A rating line: label, five pips, and the note explaining the score.

  ## Examples

      <.rating label="Beer" rating={5} note="Twenty rotating taps." />
  """
  attr :label, :string, required: true
  attr :rating, :integer, required: true
  attr :note, :string, required: true

  def rating(assigns) do
    ~H"""
    <div class="flex gap-x-3">
      <dt class="eyebrow w-12 shrink-0 pt-1 text-ink-soft">{@label}</dt>
      <dd class="min-w-0 flex-1">
        <%!-- Five empty boxes would read as "rated badly"; there simply isn't any. --%>
        <span :if={@rating == 0} class="data font-bold text-oxide">None</span>
        <span :if={@rating > 0} class="meter" role="img" aria-label={"#{@rating} out of 5"}>
          <span :for={pip <- 1..5} class="meter-pip" data-filled={pip <= @rating || nil}></span>
        </span>
        <%!-- The note always starts its own line. Letting it flow beside the pips
              put short notes inline and long ones below, so no two cards agreed. --%>
        <span class="note mt-1 block text-[0.8125rem]">{@note}</span>
      </dd>
    </div>
    """
  end

  @doc """
  How long it takes to get somewhere, leading with the quicker route.

  ## Examples

      <.journey label="Station" reach={place.station} />
  """
  attr :label, :string, required: true
  attr :reach, Reach, required: true

  def journey(assigns) do
    {mode, minutes} = Reach.best(assigns.reach)

    assigns =
      assign(assigns, mode: mode, minutes: minutes, other: Reach.alternative(assigns.reach))

    ~H"""
    <div>
      <span class="eyebrow block text-ink-soft">{@label}</span>
      <span :if={@minutes == 0} class="mt-0.5 block font-mono text-lg font-bold">
        0<span class="text-sm font-normal text-ink-soft"> min</span>
      </span>
      <span :if={@minutes > 0} class="mt-0.5 block font-mono text-lg font-bold">
        {@minutes}<span class="text-sm font-normal text-ink-soft">
          min {Reach.label(@mode)}</span>
      </span>
      <span :if={@other && @minutes > 0} class="data block text-ink-soft opacity-80">
        or {elem(@other, 1)} min {Reach.label(elem(@other, 0))}
      </span>
    </div>
    """
  end

  @doc """
  When a place is open, and what that rules out.

  Renders nothing for a place with no restrictions — most pubs — so the note
  only appears where it changes a decision.

  ## Examples

      <.opening place={place} week={week} />
  """
  attr :place, :any, required: true
  attr :week, :any, required: true

  def opening(assigns) do
    assigns =
      assign(assigns,
        description: Opening.describe(assigns.place.opening),
        days_left: Opening.days_left(assigns.place.opening, Week.today()),
        restrictive?: Opening.restrictive?(assigns.place.opening)
      )

    ~H"""
    <%!-- Ordinary pub hours are information; shutting on Mondays is a
          constraint. They should not look alike. --%>
    <p
      :if={@description}
      class={[
        "data mt-2 flex flex-wrap items-baseline gap-x-2",
        (@restrictive? && "text-oxide") || "text-ink-soft"
      ]}
    >
      <span aria-hidden="true">🕒</span>
      <span>{@description}</span>
      <%!-- A pop-up with a fortnight left is worth knowing about now, not in
            September when somebody wonders where it went. --%>
      <span :if={@days_left && @days_left <= 21} class="font-bold">
        · {ending(@days_left)}
      </span>
    </p>
    """
  end

  defp ending(0), do: "last day"
  defp ending(1), do: "1 day left"
  defp ending(days), do: "#{days} days left"

  @doc """
  How long ago we were last here, when we have been.

  Renders nothing for a place that has never won — an absence of history is not
  worth a line of type.

  ## Examples

      <.last_visit weeks_ago={2} />
  """
  attr :weeks_ago, :integer, default: nil

  def last_visit(assigns) do
    ~H"""
    <span :if={@weeks_ago} class="chip" data-recent={(@weeks_ago <= 1 && "true") || nil}>
      {visited(@weeks_ago)}
    </span>
    """
  end

  defp visited(0), do: "here this week"
  defp visited(1), do: "here last week"
  defp visited(weeks), do: "here #{weeks} weeks ago"

  @doc """
  The tag chips for a place. Renders nothing when there are none.

  ## Examples

      <.tags tags={place.tags} />
  """
  attr :tags, :list, required: true
  attr :class, :string, default: nil

  def tags(assigns) do
    ~H"""
    <div :if={@tags != []} class={["flex flex-wrap gap-1.5", @class]}>
      <span :for={tag <- @tags} class="chip">{tag}</span>
    </div>
    """
  end
end
