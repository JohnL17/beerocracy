defmodule BeerocracyWeb.PlacesLive do
  @moduledoc """
  The register of premises: every place in the catalogue, and nothing to decide.

  Deliberately has no voting controls at all. Sometimes you just want to read
  what is on offer without a card demanding a verdict, or settle an argument
  about which pub is actually nearer.
  """

  use BeerocracyWeb, :live_view

  alias Beerocracy.Places
  alias Beerocracy.Places.Place
  alias Beerocracy.Places.Reach

  import BeerocracyWeb.PlaceComponents

  @orders [
    {"listed", "As listed"},
    {"beer", "Beer"},
    {"food", "Food"},
    {"nearest", "Nearest"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    week = Beerocracy.Week.current()

    {:ok,
     assign(socket,
       page_title: "The candidates",
       orders: @orders,
       week: week,
       visits: Beerocracy.Ballot.last_visits(week)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    order = normalise_order(params["by"])

    {:noreply,
     socket
     |> assign(order: order)
     |> assign(places: sort(Places.all(), order))}
  end

  defp normalise_order(value) do
    if Enum.any?(@orders, fn {key, _label} -> key == value end), do: value, else: "listed"
  end

  # Ties fall back to the catalogue order rather than jumping about, so the list
  # stays put when you switch between sorts.
  defp sort(places, "beer"), do: Enum.sort_by(places, &{-&1.beer_rating, &1.name})
  defp sort(places, "food"), do: Enum.sort_by(places, &{-&1.food_rating, &1.name})

  defp sort(places, "nearest") do
    Enum.sort_by(places, &{Reach.minutes(&1.office), Reach.minutes(&1.station), &1.name})
  end

  defp sort(places, _listed), do: places

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="px-0 py-0 sm:px-6 sm:py-10">
        <div class="sheet animate-sheet">
          <div class="sheet-perforation"></div>
          <div class="h-2 bg-gold"></div>

          <header class="px-5 pt-6 pb-5 sm:px-10 sm:pt-8">
            <p class="article-no">Appendix to Article III</p>
            <h1 class="wordmark mt-1">The candidates</h1>
            <p class="note mt-3">
              Every place on the ballot, at rest. Nothing here votes, nothing here counts —
              read it, argue about it, close the tab.
            </p>

            <div class="mt-5 flex flex-wrap items-center gap-x-4 gap-y-2">
              <.link navigate={~p"/"} class="btn">Back to the ballot</.link>
              <.link navigate={~p"/rules"} class="data font-bold underline underline-offset-2">
                How this all works →
              </.link>
              <span class="data text-ink-soft">{length(@places)} on the list</span>
            </div>
          </header>

          <section class="sheet-section">
            <div class="flex flex-wrap items-baseline gap-x-4 gap-y-2">
              <span class="eyebrow text-ink-soft">Sort by</span>
              <nav class="flex flex-wrap gap-2">
                <.link
                  :for={{key, label} <- @orders}
                  patch={~p"/places?#{[by: key]}"}
                  class="sort-link"
                  aria-current={(@order == key && "true") || nil}
                >
                  {label}
                </.link>
              </nav>
            </div>

            <ol class="mt-6 space-y-5">
              <li :for={{place, index} <- Enum.with_index(@places, 1)}>
                <.entry place={place} index={index} week={@week} last_visit={@visits[place.slug]} />
              </li>
            </ol>
          </section>

          <footer class="border-t-2 border-ink bg-paper-edge/40 px-5 py-6 sm:px-10">
            <p class="note text-[0.8125rem]">
              Something missing, or a rating you disagree with? The list lives in
              <.catalogue_link>priv/places.yml</.catalogue_link>
              — open a pull request and it appears here on the next deploy.
            </p>
            <p :if={Places.edit_url()} class="mt-3">
              <a
                href={Places.edit_url()}
                target="_blank"
                rel="noopener noreferrer"
                class="data font-bold underline underline-offset-2"
              >
                Add a place on GitHub ↗
              </a>
            </p>
          </footer>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :place, Place, required: true
  attr :index, :integer, required: true
  attr :week, :any, required: true
  attr :last_visit, :integer, default: nil

  defp entry(assigns) do
    ~H"""
    <article
      id={"place-#{@place.slug}"}
      class="entry"
      style={"--band: var(--color-accent-#{@place.accent})"}
    >
      <div class="card-band"></div>

      <div class="p-4 sm:p-5">
        <div class="flex items-start gap-3">
          <span class="text-3xl leading-none" aria-hidden="true">{@place.emoji}</span>
          <div class="min-w-0 flex-1">
            <h2 class="text-xl font-extrabold uppercase [font-stretch:82%] leading-none sm:text-2xl">
              {@place.name}
            </h2>
            <p class="note mt-1.5">{@place.tagline}</p>
            <.opening place={@place} week={@week} />
          </div>
          <span class="data shrink-0 text-ink-soft">{pad(@index)}</span>
        </div>

        <div class="mt-4 grid gap-4 border-t border-rule pt-4 sm:grid-cols-2">
          <dl class="space-y-3">
            <.rating label="Beer" rating={@place.beer_rating} note={@place.beer_note} />
            <.rating label="Food" rating={@place.food_rating} note={@place.food_note} />
          </dl>

          <div class="grid grid-cols-2 gap-3 border-t border-rule pt-4 sm:border-t-0 sm:border-l sm:pt-0 sm:pl-5">
            <.journey label="Office" reach={@place.office} />
            <.journey label="Station" reach={@place.station} />
          </div>
        </div>

        <div class="mt-4 flex flex-wrap items-center justify-between gap-3">
          <div class="flex flex-wrap items-center gap-1.5">
            <.last_visit weeks_ago={@last_visit} />
            <span :if={@place.outdoor?} class="chip">outdoors</span>
            <span :for={tag <- @place.tags} class="chip">{tag}</span>
          </div>
          <a
            :if={@place.url}
            href={@place.url}
            target="_blank"
            rel="noopener noreferrer"
            class="data font-bold underline underline-offset-2 hover:text-oxide"
          >
            Website ↗
          </a>
        </div>
      </div>
    </article>
    """
  end

  defp pad(number), do: number |> to_string() |> String.pad_leading(2, "0")
end
