defmodule BeerocracyWeb.BallotLive do
  @moduledoc """
  The whole application: one ballot sheet for the current ISO week.

  Everyone lands on the same sheet, works down it — register, day, place —
  and watches the tally at the bottom fill in as their friends vote.
  """

  use BeerocracyWeb, :live_view

  alias Beerocracy.Ballot
  alias Beerocracy.Places
  alias Beerocracy.Places.Opening
  alias Beerocracy.Places.Place
  alias Beerocracy.Weather
  alias Beerocracy.Weather.Forecast
  alias Beerocracy.Week

  import BeerocracyWeb.PlaceComponents

  # How many cards of the deck are rendered as a visible stack.
  @stack_depth 3

  @impl true
  def mount(_params, _session, socket) do
    week = Week.current()

    if connected?(socket) do
      Ballot.subscribe(week)
      # Catches the Sunday-to-Monday rollover without anyone having to reload.
      :timer.send_interval(:timer.minutes(1), self(), :tick)
    end

    {:ok,
     socket
     |> assign(
       page_title: "Week #{week.week}",
       week: week,
       voter_name: nil,
       voter_key: nil,
       day_stances: %{},
       decided: %{},
       undone: nil
     )
     |> assign_tally()}
  end

  @impl true
  def handle_event("restore_voter", %{"name" => name}, socket) do
    {:noreply, register(socket, name)}
  end

  def handle_event("register", %{"name" => name}, socket) do
    case String.trim(name) do
      "" ->
        {:noreply,
         put_flash(socket, :error, "Enter a name first — that is how the tally knows you.")}

      name ->
        {:noreply,
         socket
         |> register(name)
         |> push_event("beerocracy:remember", %{name: name})}
    end
  end

  def handle_event("sign_out", _params, socket) do
    {:noreply,
     socket
     |> assign(voter_name: nil, voter_key: nil, day_stances: %{}, decided: %{})
     |> push_event("beerocracy:forget", %{})}
  end

  def handle_event("cycle_day", %{"weekday" => weekday}, %{assigns: assigns} = socket) do
    with {:ok, socket} <- require_voter(socket),
         {:ok, weekday} <- parse_weekday(weekday) do
      days = Ballot.cycle_day(assigns.week, assigns.voter_name, assigns.voter_key, weekday)
      {:noreply, socket |> assign(day_stances: days) |> assign_tally()}
    else
      {:error, socket} -> {:noreply, socket}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("swipe", %{"slug" => slug, "liked" => liked}, %{assigns: assigns} = socket) do
    with {:ok, socket} <- require_voter(socket),
         {:ok, place} <- Places.fetch(slug) do
      Ballot.swipe(assigns.week, assigns.voter_name, assigns.voter_key, place.slug, !!liked)

      {:noreply,
       socket
       |> assign(decided: Map.put(assigns.decided, place.slug, !!liked), undone: nil)
       |> assign_tally()}
    else
      {:error, socket} -> {:noreply, socket}
      :error -> {:noreply, put_flash(socket, :error, "That place is no longer in the catalogue.")}
    end
  end

  def handle_event("reset_vote", _params, %{assigns: assigns} = socket) do
    case require_voter(socket) do
      {:ok, socket} ->
        cleared = Ballot.reset_voter(assigns.week, assigns.voter_key)

        {:noreply,
         socket
         |> assign(day_stances: %{}, decided: %{}, undone: nil)
         |> assign_tally()
         |> put_flash(:info, reset_message(cleared))}

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("undo", _params, %{assigns: assigns} = socket) do
    with {:ok, socket} <- require_voter(socket),
         {:ok, slug} <- Ballot.undo_last_swipe(assigns.week, assigns.voter_key) do
      {:noreply,
       socket
       |> assign(decided: Map.delete(assigns.decided, slug), undone: slug)
       |> assign_tally()}
    else
      {:error, socket} -> {:noreply, socket}
      :error -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:ballot_updated, _week_key}, socket) do
    {:noreply, assign_tally(socket)}
  end

  def handle_info(:tick, %{assigns: assigns} = socket) do
    week = Week.current()

    if week.key == assigns.week.key do
      # Same week; only the countdown in the header moved.
      {:noreply, assign(socket, week: week)}
    else
      # A new week: the old sheet is spent, everybody starts clean.
      Ballot.subscribe(week)

      {:noreply,
       socket
       |> assign(
         week: week,
         page_title: "Week #{week.week}",
         day_stances: %{},
         decided: %{}
       )
       |> restore_voter_state()
       |> assign_tally()}
    end
  end

  defp register(socket, name) do
    name = name |> String.trim() |> String.replace(~r/\s+/u, " ")

    socket
    |> assign(voter_name: name, voter_key: Ballot.voter_key(name))
    |> restore_voter_state()
    |> assign_tally()
  end

  defp restore_voter_state(%{assigns: %{voter_key: nil}} = socket), do: socket

  defp restore_voter_state(%{assigns: assigns} = socket) do
    state = Ballot.voter_state(assigns.week, assigns.voter_key)
    assign(socket, day_stances: state.days, decided: state.places)
  end

  defp require_voter(%{assigns: %{voter_key: nil}} = socket) do
    {:error, put_flash(socket, :error, "Sign the register first, then vote.")}
  end

  defp require_voter(socket), do: {:ok, socket}

  # Never `String.to_atom/1` on user input; only the five days on the ballot map
  # to an atom at all.
  defp parse_weekday(value) do
    case Enum.find(Week.weekdays(), &(Atom.to_string(&1) == value)) do
      nil -> :error
      weekday -> {:ok, weekday}
    end
  end

  defp assign_tally(%{assigns: assigns} = socket) do
    tally = Ballot.tally(assigns.week)
    outcome = Ballot.outcome(tally)
    forecasts = Weather.for_week(assigns.week)
    history = Ballot.history(assigns.week, 4)

    pending =
      assigns.week
      |> Ballot.pending_places(assigns.decided, {assigns.week.key, assigns.voter_key})
      |> pin_undone(assigns.undone)

    assign(socket,
      tally: tally,
      weather: forecasts,
      window: Weather.window(),
      pending: pending,
      deck: Enum.take(pending, @stack_depth),
      total_places: length(Places.available(assigns.week)),
      leading_day: Ballot.winning_day(tally),
      outcome: outcome,
      soaking: Ballot.soaking_risk(outcome, forecasts),
      history: history,
      visits: Ballot.last_visits(assigns.week)
    )
  end

  # A card you just took back goes straight to the top of the deck. You undid the
  # swipe because you want to judge it again now, not in six cards' time.
  defp pin_undone(places, nil), do: places

  defp pin_undone(places, slug) do
    case Enum.split_with(places, &(&1.slug == slug)) do
      {[place], rest} -> [place | rest]
      _ -> places
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div
        id="ballot"
        class="px-0 py-0 sm:px-6 sm:py-10"
        phx-hook=".Register"
        data-registered={to_string(!is_nil(@voter_key))}
      >
        <div class="sheet animate-sheet">
          <div class="sheet-perforation"></div>
          <div class="h-2 bg-bottle"></div>

          <.masthead week={@week} voters={@tally.voters} />

          <.register_section voter_name={@voter_name} week={@week.week} />

          <.day_section
            locked={is_nil(@voter_key)}
            days={@tally.days}
            stances={@day_stances}
            leading={@leading_day}
            weather={@weather}
            window={@window}
          />

          <.place_section
            locked={is_nil(@voter_key)}
            deck={@deck}
            pending={@pending}
            decided={@decided}
            total={@total_places}
            undone={@undone}
            week={@week}
            visits={@visits}
            waiting?={@decided != %{} and not Ballot.counts?(@tally, @day_stances)}
            busy_on={busy_on(@tally, @day_stances)}
          />

          <.tally_section
            tally={@tally}
            outcome={@outcome}
            soaking={@soaking}
            history={@history}
          />

          <.colophon />
        </div>
      </div>
    </Layouts.app>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Register">
      // The name is the whole identity system, so we keep it on the device and
      // hand it back to the server on the next visit.
      const KEY = "beerocracy:name"

      export default {
        mounted() {
          this.handleEvent("beerocracy:remember", ({name}) => localStorage.setItem(KEY, name))
          this.handleEvent("beerocracy:forget", () => localStorage.removeItem(KEY))

          const stored = localStorage.getItem(KEY)
          if (stored && this.el.dataset.registered !== "true") {
            this.pushEvent("restore_voter", {name: stored})
          }
        }
      }
    </script>
    """
  end

  # ── Masthead ───────────────────────────────────────────────────────────────

  attr :week, Week, required: true
  attr :voters, :list, required: true

  defp masthead(assigns) do
    ~H"""
    <header class="flex flex-wrap items-start justify-between gap-4 px-5 pt-6 pb-5 sm:px-10 sm:pt-8">
      <div>
        <h1 class="wordmark">Beerocracy</h1>
        <p class="eyebrow mt-2 text-ink-soft">One beer · one week · one vote each</p>
        <p :if={@voters != []} class="data mt-3 text-ink-soft">
          On the sheet: {Enum.join(@voters, ", ")}
        </p>
      </div>

      <div class="flex flex-col items-end gap-2">
        <div class="stamp stamp-week animate-stamp">
          <span class="text-[0.5rem] tracking-[0.3em]">Calendar week</span>
          <span class="text-3xl leading-none tracking-tight">{@week.week}</span>
          <span class="text-[0.5rem]">{date_range(@week)}</span>
        </div>
        <p class="data text-ink-soft">Resets in {reset_countdown(@week)}</p>
      </div>
    </header>
    """
  end

  # ── Article I — the register ───────────────────────────────────────────────

  attr :voter_name, :string, default: nil
  attr :week, :integer, required: true

  defp register_section(assigns) do
    ~H"""
    <section class="sheet-section">
      <.article_header no="I" title="The register">
        Your name is the whole login system. Use the same one every week and the sheet
        will remember what you already voted for.
      </.article_header>

      <div :if={is_nil(@voter_name)} class="mt-5">
        <form phx-submit="register" class="flex flex-wrap items-end gap-3">
          <label class="min-w-48 flex-1">
            <span class="eyebrow text-ink-soft">Your name</span>
            <input
              type="text"
              name="name"
              class="field mt-1"
              placeholder="e.g. Hanni"
              autocomplete="nickname"
              maxlength="40"
              required
            />
          </label>
          <button type="submit" class="btn">Sign in</button>
        </form>
      </div>

      <div :if={@voter_name} class="mt-5 flex flex-wrap items-center gap-3">
        <p class="mr-auto text-xl font-extrabold uppercase [font-stretch:82%]">
          Signed: {@voter_name}
        </p>
        <button
          type="button"
          phx-click="reset_vote"
          data-confirm={"Clear your days and swipes for week #{@week}? Everyone else's marks stay."}
          class="btn btn-quiet"
        >
          Reset my vote
        </button>
        <button type="button" phx-click="sign_out" class="btn btn-quiet">
          Not you?
        </button>
      </div>
    </section>
    """
  end

  # ── Article II — the day ───────────────────────────────────────────────────

  attr :locked, :boolean, required: true
  attr :days, :list, required: true
  attr :stances, :map, required: true
  attr :leading, :any, default: nil
  attr :weather, :map, required: true
  attr :window, :any, required: true

  defp day_section(assigns) do
    ~H"""
    <section class="sheet-section" data-locked={@locked || nil}>
      <.article_header no="II" title="Which day">
        Tap a day for yes, tap again for maybe, once more to clear it. Mark as many as
        you like — a maybe counts towards the day just like a yes, so say maybe if you
        could be talked into it.
      </.article_header>

      <div :if={@weather != %{}} class="mt-5 flex items-baseline gap-2">
        <span class="eyebrow text-ink-soft">Outlook {Forecast.window(@window)}</span>
        <span class="h-px flex-1 bg-rule"></span>
      </div>

      <div class="mt-3 grid grid-cols-5 gap-1.5 sm:gap-3">
        <button
          :for={day <- @days}
          type="button"
          phx-click="cycle_day"
          phx-value-weekday={day.weekday}
          disabled={@locked}
          data-stance={@stances[day.weekday]}
          data-leader={(@leading && @leading.weekday == day.weekday) || nil}
          class="day-tile"
          title={day_title(day)}
          aria-label={"#{Week.label(day.weekday)}: #{stance_label(@stances[day.weekday])}"}
        >
          <.outlook forecast={@weather[day.date]} />
          <span class="day-tile-label">{Week.short_label(day.weekday)}</span>
          <span class="day-tile-date">{Calendar.strftime(day.date, "%-d.%-m.")}</span>
          <span class="day-tile-stance">{stance_label(@stances[day.weekday])}</span>
          <span class="day-tile-count">{tally_marks(day.count)}</span>
        </button>
      </div>

      <p class="data mt-4 text-ink-soft">
        Your answer is the word on the tile. The strokes underneath are everyone's,
        maybes included.
      </p>
    </section>
    """
  end

  attr :forecast, Forecast, default: nil

  defp outlook(assigns) do
    ~H"""
    <%!-- Rendered even when the forecast is missing, so a day the API has no
          answer for does not make its tile shorter than the other four. --%>
    <span class="day-tile-weather" title={@forecast && Forecast.describe(@forecast)}>
      <span :if={@forecast} class="day-tile-sky" aria-hidden="true">
        {Forecast.symbol(@forecast)}
      </span>
      <span :if={@forecast} class="day-tile-temp">
        {Forecast.temperature(@forecast)}<span class="sr-only">
          C, {Forecast.describe(@forecast)}</span>
      </span>
      <%!-- The verdict, not a percentage: an evening can read 98% and expect
            0.0mm, which is a high chance of nothing in particular. --%>
      <span
        :if={@forecast && Forecast.verdict(@forecast)}
        class="day-tile-rain"
        data-level={Forecast.verdict(@forecast).level}
      >
        {Forecast.verdict(@forecast).phrase}
      </span>
      <span :if={is_nil(@forecast)} class="day-tile-sky" aria-hidden="true">·</span>
    </span>
    """
  end

  # ── Article III — the place ────────────────────────────────────────────────

  attr :locked, :boolean, required: true
  attr :deck, :list, required: true
  attr :pending, :list, required: true
  attr :decided, :map, required: true
  attr :total, :integer, required: true
  attr :undone, :string, default: nil
  attr :week, Week, required: true
  attr :visits, :map, required: true
  attr :waiting?, :boolean, default: false
  attr :busy_on, :any, default: nil

  defp place_section(assigns) do
    assigns = assign(assigns, decided_count: map_size(assigns.decided))

    ~H"""
    <section class="sheet-section" data-locked={@locked || nil}>
      <.article_header no="III" title="Which place">
        Swipe right to approve, left to reject. The keyboard arrows work too, and so do
        the buttons — nobody is watching.
      </.article_header>

      <%!-- Their swipes are recorded but parked. Say so where they are swiping,
            not only in the tally where they might never look. --%>
      <div :if={@waiting?} class="mt-4 border-2 border-oxide bg-oxide/10 p-3">
        <p class="note text-ink">
          <span class="font-bold">Your swipes are not counting yet.</span>
          <%!-- Two ways to end up here: no day marked at all, or marked days
                that the winning one is not among. Say which. --%>
          <span :if={is_nil(@busy_on)}>
            Pick a day in Article II first — if you are not coming, you do not get to
            choose where.
          </span>
          <span :if={@busy_on}>
            {Week.label(@busy_on)} is winning and you have not marked it, so you would not
            be there — mark it, even as a maybe, and your swipes join in.
          </span>
          Nothing is lost; they start counting the moment you do.
        </p>
        <%!-- The other honest answer to "no day picked" is that they genuinely
              cannot make it, in which case leaving swipes parked forever helps
              nobody. Offer the way out rather than only the way forward. --%>
        <p class="mt-3 flex flex-wrap items-center gap-x-3 gap-y-2">
          <span class="data text-ink-soft">Cannot make it this week?</span>
          <button
            type="button"
            phx-click="reset_vote"
            data-confirm={"Clear your swipes for week #{@week.week}? Everyone else's marks stay."}
            class="btn btn-quiet !px-3 text-xs"
          >
            Clear my swipes
          </button>
        </p>
      </div>

      <div class="mt-3 flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <span class="data text-ink-soft">
          {@decided_count} of {@total} judged
        </span>
        <span :if={@undone} class="data text-oxide">Back on the deck</span>
        <.link navigate={~p"/places"} class="data font-bold underline underline-offset-2">
          Just browsing? See all {@total} →
        </.link>
      </div>

      <div :if={@pending != []} class="mt-4">
        <div
          id="deck"
          class="deck"
          phx-hook=".SwipeDeck"
          tabindex="0"
          role="group"
          aria-label="Places to judge"
        >
          <.swipe_card
            :for={{place, depth} <- Enum.with_index(@deck)}
            place={place}
            depth={depth}
            position={@decided_count + depth + 1}
            total={@total}
            week={@week}
            last_visit={@visits[place.slug]}
          />
        </div>

        <div class="mt-5 flex items-center justify-center gap-3 sm:gap-5">
          <button
            type="button"
            class="btn btn-reject"
            disabled={@locked}
            phx-click={JS.dispatch("beerocracy:vote", to: "#deck", detail: %{liked: false})}
            aria-label="Reject this place"
          >
            Reject
          </button>

          <button
            type="button"
            class="btn btn-quiet !px-3 text-xs"
            disabled={@locked or @decided_count == 0}
            phx-click="undo"
          >
            Undo
          </button>

          <button
            type="button"
            class="btn btn-approve"
            disabled={@locked}
            phx-click={JS.dispatch("beerocracy:vote", to: "#deck", detail: %{liked: true})}
            aria-label="Approve this place"
          >
            Approve
          </button>
        </div>
      </div>

      <div :if={@pending == [] and @decided_count > 0} class="mt-6 flex flex-col items-start gap-4">
        <div class="stamp stamp-week animate-stamp text-lg">Ballot complete</div>
        <p class="note">
          Every place in the catalogue has your verdict. You approved {approved_names(@decided)}.
        </p>
        <button type="button" class="btn btn-quiet" phx-click="undo">Take back the last one</button>
      </div>

      <p :if={@pending == [] and @decided_count == 0} class="note mt-6">
        The catalogue is empty. Add a place to <code class="data">priv/places.yml</code>
        and it appears here.
      </p>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SwipeDeck">
        // Tinder-style deck. The gesture, the tilt and the rubber stamps all live
        // here; the server only ever hears the final verdict.
        const THROW = 110          // px of travel that counts as a decision
        const FLY_MS = 320         // must match .swipe-card[data-flying] in app.css

        export default {
          mounted() {
            this.pointerId = null
            this.settling = false

            this.onDown = (e) => this.start(e)
            this.onMove = (e) => this.move(e)
            this.onUp = (e) => this.end(e)
            this.onKey = (e) => {
              if (e.key === "ArrowRight") { e.preventDefault(); this.decide(true) }
              if (e.key === "ArrowLeft") { e.preventDefault(); this.decide(false) }
            }
            this.onVote = (e) => this.decide(!!e.detail.liked)

            this.el.addEventListener("pointerdown", this.onDown)
            this.el.addEventListener("pointermove", this.onMove)
            this.el.addEventListener("pointerup", this.onUp)
            this.el.addEventListener("pointercancel", this.onUp)
            this.el.addEventListener("keydown", this.onKey)
            this.el.addEventListener("beerocracy:vote", this.onVote)
          },

          destroyed() {
            this.el.removeEventListener("pointerdown", this.onDown)
            this.el.removeEventListener("pointermove", this.onMove)
            this.el.removeEventListener("pointerup", this.onUp)
            this.el.removeEventListener("pointercancel", this.onUp)
            this.el.removeEventListener("keydown", this.onKey)
            this.el.removeEventListener("beerocracy:vote", this.onVote)
          },

          top() {
            return this.el.querySelector('.swipe-card[data-depth="0"]:not([data-flying])')
          },

          start(e) {
            const card = this.top()
            if (!card || !card.contains(e.target) || this.pointerId !== null) return
            this.pointerId = e.pointerId
            this.originX = e.clientX
            this.originY = e.clientY
            this.dx = 0
            this.card = card
            card.setAttribute("data-dragging", "")
            card.removeAttribute("data-settling")
            card.setPointerCapture(e.pointerId)
          },

          move(e) {
            if (e.pointerId !== this.pointerId || !this.card) return
            this.dx = e.clientX - this.originX
            const dy = e.clientY - this.originY
            // Beyond a wrist-flick the card should feel thrown, not dragged.
            this.paint(this.dx, dy, this.dx / (this.el.clientWidth || 320))
          },

          end(e) {
            if (e.pointerId !== this.pointerId || !this.card) return
            const card = this.card
            card.releasePointerCapture?.(e.pointerId)
            card.removeAttribute("data-dragging")
            this.pointerId = null

            if (Math.abs(this.dx) >= THROW) {
              this.throw(card, this.dx > 0)
            } else {
              card.setAttribute("data-settling", "")
              this.paint(0, 0, 0)
              setTimeout(() => card.removeAttribute("data-settling"), 300)
            }
            this.card = null
          },

          decide(liked) {
            const card = this.top()
            if (card) this.throw(card, liked)
          },

          // Off it goes. The event is pushed once the card has left the sheet, so
          // the re-render never interrupts the throw.
          throw(card, liked) {
            if (card.hasAttribute("data-flying")) return
            const slug = card.dataset.slug
            const width = this.el.clientWidth || 320
            card.removeAttribute("data-settling")
            card.setAttribute("data-flying", "")
            this.paintCard(card, liked ? width * 1.6 : -width * 1.6, -40, liked ? 1 : -1)
            setTimeout(() => this.pushEvent("swipe", {slug, liked}), FLY_MS - 60)
          },

          paint(dx, dy, progress) {
            if (this.card) this.paintCard(this.card, dx, dy * 0.35, progress)
          },

          paintCard(card, dx, dy, progress) {
            card.style.transform = `translate3d(${dx}px, ${dy}px, 0) rotate(${dx * 0.045}deg)`
            const approve = card.querySelector(".stamp-approve")
            const reject = card.querySelector(".stamp-reject")
            if (approve) approve.style.opacity = Math.min(Math.max(progress, 0) * 2.2, 0.9)
            if (reject) reject.style.opacity = Math.min(Math.max(-progress, 0) * 2.2, 0.9)
          }
        }
      </script>
    </section>
    """
  end

  attr :place, Place, required: true
  attr :depth, :integer, required: true
  attr :position, :integer, required: true
  attr :total, :integer, required: true
  attr :week, Week, required: true
  attr :last_visit, :integer, default: nil

  defp swipe_card(assigns) do
    ~H"""
    <article
      id={"card-#{@place.slug}"}
      class="swipe-card"
      data-depth={@depth}
      data-slug={@place.slug}
      style={"--band: var(--color-accent-#{@place.accent})"}
      aria-hidden={@depth > 0}
    >
      <div class="card-band"></div>

      <div class="p-4 sm:p-6">
        <div class="flex items-start justify-between gap-3">
          <span class="text-4xl leading-none" aria-hidden="true">{@place.emoji}</span>
          <span class="data text-ink-soft">
            {pad(@position)} / {pad(@total)}
          </span>
        </div>

        <h3 class="mt-3 text-2xl font-extrabold uppercase [font-stretch:80%] leading-none sm:text-3xl">
          {@place.name}
        </h3>
        <p class="note mt-2">{@place.tagline}</p>
        <.opening place={@place} week={@week} />

        <dl class="mt-4 space-y-3 border-t border-rule pt-4">
          <.rating label="Beer" rating={@place.beer_rating} note={@place.beer_note} />
          <.rating label="Food" rating={@place.food_rating} note={@place.food_note} />
        </dl>

        <div class="mt-4 grid grid-cols-2 gap-3 border-t border-rule pt-4">
          <.journey label="Office" reach={@place.office} />
          <.journey label="Station" reach={@place.station} />
        </div>

        <div class="mt-4 flex flex-wrap items-center gap-1.5">
          <.last_visit weeks_ago={@last_visit} />
          <span :if={@place.outdoor?} class="chip">outdoors</span>
          <span :for={tag <- @place.tags} class="chip">{tag}</span>
        </div>
      </div>

      <div class="stamp stamp-verdict stamp-approve" aria-hidden="true">Approved</div>
      <div class="stamp stamp-verdict stamp-reject" aria-hidden="true">Rejected</div>
    </article>
    """
  end

  # ── Article IV — the tally ─────────────────────────────────────────────────

  attr :tally, :any, required: true
  attr :outcome, :any, default: nil
  attr :soaking, :any, default: nil
  attr :history, :list, default: []

  defp tally_section(assigns) do
    ~H"""
    <section class="sheet-section">
      <.article_header no="IV" title="The tally">
        Live, and wiped clean every Monday at 00:00. {@tally.day_votes_cast} day {pluralize_votes(
          @tally.day_votes_cast
        )} and {@tally.place_votes_cast} swipes recorded.
      </.article_header>

      <div
        :if={Ballot.decided?(@outcome)}
        class="mt-6 border-2 border-bottle bg-bottle p-5 text-paper"
      >
        <p class="eyebrow opacity-80">As it stands</p>
        <p class="mt-2 text-2xl font-extrabold uppercase [font-stretch:80%] leading-tight sm:text-3xl">
          {Week.label(@outcome.day.weekday)} at {place_names(@outcome.places)}
        </p>
        <p class="data mt-2 opacity-80">
          {Calendar.strftime(@outcome.day.date, "%d.%m.%Y")} · {@outcome.day.count} for the day{maybe_suffix(
            @outcome.day
          )} · {hd(@outcome.places).likes} for the place{tied_suffix(@outcome.places)}
        </p>

        <%!-- The most-liked place cannot host the winning day, so say so rather
              than quietly promoting the runner-up. --%>
        <p :if={@outcome.blocked} class="mt-3 border-t border-paper/30 pt-3 text-sm leading-snug">
          <span class="font-bold">{@outcome.blocked.place.name}</span>
          has more approvals but is shut on {Week.label(@outcome.day.weekday)}<span :if={
            Opening.describe(@outcome.blocked.place.opening)
          }>
            — {Opening.describe(@outcome.blocked.place.opening)}</span>.
        </p>

        <p :if={@soaking} class="mt-3 border-t border-paper/30 pt-3 text-sm leading-snug">
          <span aria-hidden="true">{Forecast.symbol(@soaking)}</span>
          Outdoors, and {Week.label(@outcome.day.weekday)} looks wet —
          <span class="font-bold">
            {@soaking |> Forecast.verdict() |> Map.fetch!(:phrase) |> String.downcase()}
          </span>
          between {Forecast.window(@soaking)}, up to {Forecast.rain_peak(@soaking)}% chance.
        </p>
      </div>

      <p :if={not Ballot.decided?(@outcome)} class="note mt-6">
        <span :if={is_nil(@outcome)}>No day has a tick yet.</span>
        <span :if={@outcome}>
          {Week.label(@outcome.day.weekday)} is leading, but nothing approved is open then.<span :if={
            @outcome.blocked
          }>
            <span class="font-bold text-ink">{@outcome.blocked.place.name}</span>
            is shut on {Week.label(@outcome.day.weekday)}<span :if={
              Opening.describe(@outcome.blocked.place.opening)
            }> — {Opening.describe(@outcome.blocked.place.opening)}</span>.</span>
        </span>
        The floor is open.
      </p>

      <p :if={@tally.waiting != []} class="note mt-4 text-oxide">
        <span class="font-bold">Not counting yet:</span>
        {Enum.join(@tally.waiting, ", ")} {pluralise_have(@tally.waiting)} swiped but {pluralise_are(
          @tally.waiting
        )} not down for {leading_label(@outcome)}, so those swipes are
        parked — shown as <span class="font-bold">+n?</span>
        below — until that changes.
      </p>

      <h3 class="eyebrow mt-8 text-ink-soft">Days</h3>
      <p class="data mt-1 text-ink-soft">Solid is a yes, hatched is a maybe. Both count.</p>
      <div class="mt-3 space-y-2">
        <div :for={day <- @tally.days} class="flex items-center gap-3">
          <span class="data w-8 shrink-0 font-bold">{Week.short_label(day.weekday)}</span>
          <div class="tally-bar flex-1">
            <div
              class="tally-fill"
              style={"width: #{share(day.yes_count, max_day_count(@tally))}%"}
            >
            </div>
            <div
              class="tally-fill"
              data-tentative
              style={"width: #{share(day.maybe_count, max_day_count(@tally))}%"}
            >
            </div>
          </div>
          <span
            class="data w-28 shrink-0 truncate text-right text-ink-soft"
            title={day_title(day)}
          >
            {day_summary(day)}
          </span>
        </div>
      </div>

      <div :if={@history != []}>
        <h3 class="eyebrow mt-8 text-ink-soft">Where we went</h3>
        <p class="data mt-1 text-ink-soft">So nobody proposes the same pub four weeks running.</p>
        <ol class="mt-3 space-y-1.5">
          <li :for={visit <- @history} class="flex items-baseline gap-3">
            <span class="data w-16 shrink-0 font-bold">W{visit.week.week}</span>
            <span class="data w-8 shrink-0 text-ink-soft">{Week.short_label(visit.weekday)}</span>
            <span class="min-w-0 flex-1 truncate">
              <span aria-hidden="true">{visit.place.emoji}</span> {visit.place.name}
            </span>
            <span class="data shrink-0 text-ink-soft">+{visit.likes}</span>
          </li>
        </ol>
      </div>

      <h3 class="eyebrow mt-8 text-ink-soft">Places</h3>
      <div class="mt-1">
        <div :for={{position, result} <- Ballot.ranked(@tally.places)} class="rank-row">
          <%!-- Blank for a drawn place: a league table prints the position once
                and leaves the rows below it empty. --%>
          <span class="rank-no">{position && pad(position)}</span>
          <div class="min-w-0">
            <p class="truncate font-bold uppercase [font-stretch:86%]">
              <span aria-hidden="true">{result.place.emoji}</span> {result.place.name}
            </p>
            <div class="tally-bar mt-1.5 max-w-64">
              <div
                class="tally-fill"
                style={"width: #{share(result.likes, max_place_likes(@tally))}%"}
              >
              </div>
            </div>
          </div>
          <span class="data whitespace-nowrap text-ink-soft" title={fans_title(result)}>
            <span class="font-bold text-ink">+{result.likes}</span>
            / −{result.dislikes}<span
              :if={result.waiting_likes + result.waiting_dislikes > 0}
              class="text-oxide"
              title={"Waiting on a day: #{Enum.join(result.waiting, ", ")}"}
            >
              · +{result.waiting_likes}?</span>
          </span>
        </div>
      </div>
    </section>
    """
  end

  # ── Shared bits ────────────────────────────────────────────────────────────

  attr :no, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp article_header(assigns) do
    ~H"""
    <div>
      <p class="article-no">Article {@no}</p>
      <h2 class="section-heading mt-1">{@title}</h2>
      <p class="note mt-2">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  defp colophon(assigns) do
    ~H"""
    <footer class="border-t-2 border-ink bg-paper-edge/40 px-5 py-6 sm:px-10">
      <p class="note text-[0.8125rem]">
        The list of places lives in <.catalogue_link>priv/places.yml</.catalogue_link>. Adding your local is a pull
        request, not a deployment — copy an entry, fill it in, open the PR. It shows up
        on the next deploy.
      </p>
      <p class="mt-3 flex flex-wrap gap-x-5 gap-y-2">
        <a
          :if={Places.edit_url()}
          href={Places.edit_url()}
          target="_blank"
          rel="noopener noreferrer"
          class="data font-bold underline underline-offset-2"
        >
          Add a place on GitHub ↗
        </a>
        <.link navigate={~p"/places"} class="data font-bold underline underline-offset-2">
          Read the whole list without voting →
        </.link>
        <.link navigate={~p"/rules"} class="data font-bold underline underline-offset-2">
          How this all works →
        </.link>
      </p>
    </footer>
    """
  end

  defp date_range(%Week{monday: monday, sunday: sunday}) do
    "#{Calendar.strftime(monday, "%-d")} - #{Calendar.strftime(sunday, "%-d %b")}"
  end

  defp reset_countdown(week) do
    seconds = Week.seconds_until_reset(week)
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3600)

    cond do
      days > 0 -> "#{days}d #{hours}h"
      hours > 0 -> "#{hours}h #{div(rem(seconds, 3600), 60)}m"
      true -> "#{div(seconds, 60)}m"
    end
  end

  # Counts on a paper ballot are kept in fives, gate by gate.
  defp tally_marks(0), do: "·"

  defp tally_marks(count) do
    String.duplicate("卌 ", div(count, 5)) <> String.duplicate("|", rem(count, 5))
  end

  defp reset_message(%{days: 0, places: 0}), do: "Nothing to clear — you had not voted yet."

  defp reset_message(%{days: days, places: places}) do
    "Cleared #{days} #{pluralize(days, "day")} and #{places} #{pluralize(places, "swipe")}. Start again whenever."
  end

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"

  # The word printed on the tile, which is also what a screen reader announces.
  defp stance_label(:yes), do: "Yes"
  defp stance_label(:maybe), do: "Maybe"
  defp stance_label(nil), do: "—"

  defp day_title(%{count: 0}), do: "Nobody yet"

  defp day_title(day) do
    [
      if(day.certain != [], do: "Yes: #{Enum.join(day.certain, ", ")}"),
      if(day.tentative != [], do: "Maybe: #{Enum.join(day.tentative, ", ")}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp place_names(places), do: places |> Enum.map(& &1.place.name) |> to_sentence()

  # The winning weekday, when the voter has marked days but not that one.
  defp busy_on(_tally, day_stances) when map_size(day_stances) == 0, do: nil

  defp busy_on(tally, day_stances) do
    case Ballot.winning_day(tally) do
      nil -> nil
      day -> if Map.has_key?(day_stances, day.weekday), do: nil, else: day.weekday
    end
  end

  defp tied_suffix([_only]), do: ""
  defp tied_suffix(places), do: ", #{length(places)} ways"

  defp to_sentence([one]), do: one
  defp to_sentence([a, b]), do: "#{a} or #{b}"

  defp to_sentence(names) do
    {rest, [last]} = Enum.split(names, -1)
    "#{Enum.join(rest, ", ")} or #{last}"
  end

  defp maybe_suffix(%{maybe_count: 0}), do: ""
  defp maybe_suffix(%{maybe_count: maybe}), do: " (#{maybe} maybe)"

  defp day_summary(%{count: 0}), do: "—"
  defp day_summary(%{count: count, maybe_count: 0}), do: "#{count}"
  defp day_summary(%{count: count, maybe_count: maybe}), do: "#{count} · #{maybe} maybe"

  defp fans_title(%{fans: [], critics: []}), do: "No verdicts yet"

  defp fans_title(%{fans: fans, critics: critics}) do
    [
      if(fans != [], do: "For: #{Enum.join(fans, ", ")}"),
      if(critics != [], do: "Against: #{Enum.join(critics, ", ")}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp approved_names(decided) do
    case decided |> Enum.filter(&elem(&1, 1)) |> Enum.map(&elem(&1, 0)) |> Places.filter() do
      [] -> "nothing at all, which is a position"
      places -> places |> Enum.map(& &1.name) |> Enum.join(", ")
    end
  end

  defp max_day_count(tally), do: tally.days |> Enum.map(& &1.count) |> Enum.max(fn -> 0 end)

  defp max_place_likes(tally),
    do: tally.places |> Enum.map(& &1.likes) |> Enum.max(fn -> 0 end)

  defp share(_value, 0), do: 0
  defp share(value, max), do: round(value / max * 100)

  defp pad(number), do: number |> to_string() |> String.pad_leading(2, "0")

  defp pluralise_have([_only]), do: "has"
  defp pluralise_have(_many), do: "have"

  defp pluralise_are([_only]), do: "is"
  defp pluralise_are(_many), do: "are"

  defp leading_label(nil), do: "any day"
  defp leading_label(%{day: day}), do: Week.label(day.weekday)

  defp pluralize_votes(1), do: "vote"
  defp pluralize_votes(_), do: "votes"
end
