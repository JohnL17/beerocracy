defmodule BeerocracyWeb.Layouts do
  @moduledoc """
  Layouts used across the app.
  """

  use BeerocracyWeb, :html

  embed_templates "layouts/*"

  @doc """
  Wraps a page and keeps the flash notices on top of it.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope}>
        <h1>Content</h1>
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, Beerocracy.Accounts.Scope,
    default: nil,
    doc: "who is reading the page; the only thing it changes is the admin link"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div :if={@current_scope && @current_scope.admin?} class="mx-auto max-w-5xl px-5 pt-3 sm:px-6">
      <.link
        navigate="/admin/dashboard"
        class="eyebrow text-ink-soft hover:text-ink float-right inline-flex items-center gap-1"
      >
        <.icon name="hero-wrench-screwdriver" class="size-3" /> Dashboard
      </.link>
    </div>

    <main>
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group, plus the connection notices LiveView drives from CSS.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="Offline"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        The sheet is out of date. Reconnecting
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="The clerk fell over"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Your votes are safe. Reconnecting
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
