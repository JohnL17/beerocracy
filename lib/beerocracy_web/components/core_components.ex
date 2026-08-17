defmodule BeerocracyWeb.CoreComponents do
  @moduledoc """
  The handful of shared UI pieces this app needs.

  Beerocracy is one screen, so nearly all of its markup lives in
  `BeerocracyWeb.BallotLive` next to the state it renders. What is left here is
  what the layout needs: flash notices and icons.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders a flash notice, styled as a slip clipped to the ballot.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} title="Rejected">Try again</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "fixed inset-x-3 bottom-3 z-50 mx-auto flex max-w-md items-start gap-3 border-2 p-3 shadow-lg sm:inset-x-auto sm:right-6 sm:bottom-6",
        @kind == :info && "border-bottle bg-bottle text-paper",
        @kind == :error && "border-oxide bg-oxide text-paper"
      ]}
      {@rest}
    >
      <p class="flex-1 text-sm leading-snug">
        <span :if={@title} class="eyebrow block">{@title}</span>
        {msg}
      </p>
      <button type="button" class="shrink-0 opacity-70 hover:opacity-100" aria-label="Dismiss">
        <.icon name="hero-x-mark-mini" class="size-4" />
      </button>
    </div>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark-mini" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  @doc "Hides an element with a short fade."
  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition: {"transition-all ease-in duration-200", "opacity-100", "opacity-0"}
    )
  end

  @doc "Shows an element with a short fade."
  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 200,
      transition: {"transition-all ease-out duration-200", "opacity-0", "opacity-100"}
    )
  end
end
